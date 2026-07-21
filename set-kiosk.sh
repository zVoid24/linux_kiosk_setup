#!/bin/bash
###############################################################################
# setup-kiosk.sh  —  One-shot Arch Linux Flutter kiosk builder
#
# Turns a FRESH Arch install into a locked-down kiosk in one run.
#
# PREREQUISITES (must already be true before running):
#   - Arch is installed and booted
#   - Internet works (ping archlinux.org)
#   - Your Flutter app is available as a git repo (default) or local folder
#     (configured via APP_REPO / APP_SRC below)
#
# The admin (sudo) user is created automatically if it doesn't exist yet —
# you'll be prompted to set its password once.
#
# RUN IT LIKE THIS (as root on a fresh install, or via sudo):
#   chmod +x setup-kiosk.sh
#   ./setup-kiosk.sh          # if logged in as root
#   sudo ./setup-kiosk.sh     # if logged in as an existing sudo user
#
# Everything is idempotent-ish: safe to re-run if something fails midway.
###############################################################################

set -euo pipefail

##############################  CONFIG — EDIT ME  #############################
ADMIN_USER="admin"          # your existing sudo user
KIOSK_USER="kiosk"          # the locked-down user (created by this script)

# Kiosk user's password. The kiosk auto-logs in so it's never typed at login,
# BUT some dialogs (polkit auth, screen prompts, su - kiosk) can ask for it,
# so a KNOWN password is more practical than a random one.
#   - Leave "" to be PROMPTED for it during setup (recommended).
#   - Or hardcode one here for fully non-interactive installs, e.g. "kiosk1234".
KIOSK_PASSWORD=""

# ---- Where your Flutter app comes from -------------------------------------
# Option 1 (default): clone the app bundle from a git repo.
APP_REPO="https://github.com/zVoid24/modbus_linux_bundle.git"

# Option 2: use a local folder already on disk instead of git.
#   Leave APP_REPO="" and set APP_SRC to the bundle folder path.
#   If BOTH are empty, the script assumes you already put the app in APP_DIR.
APP_SRC=""

# Name of your Flutter executable inside the bundle (the binary, not a .sh):
APP_BINARY="modbus"

# Install location (do not usually need to change):
APP_DIR="/opt/hybridController"
##############################################################################

# ---- helpers ---------------------------------------------------------------
say()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m!!  $*\033[0m"; }
die()  { echo -e "\033[1;31mERROR: $*\033[0m"; exit 1; }

# ---- sanity checks ---------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo ./setup-kiosk.sh   (or as root)"
ping -c1 -W3 archlinux.org &>/dev/null || die "No internet. Connect first (nmcli / systemctl start NetworkManager)."

KIOSK_HOME="/home/${KIOSK_USER}"

# ---- ensure the admin (sudo) user exists -----------------------------------
# The AUR builds (yay, rustdesk) must run as a NON-root user with sudo, because
# makepkg refuses to run as root. So we guarantee $ADMIN_USER exists and has sudo.
say "STEP 0/13  Ensuring admin user '$ADMIN_USER' exists with sudo"

# make sure sudo + the wheel sudoers rule are in place
pacman -S --needed --noconfirm sudo
# enable sudo for the wheel group (idempotent)
if ! grep -q '^%wheel ALL=(ALL:ALL) ALL' /etc/sudoers 2>/dev/null; then
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers.d/10-wheel >/dev/null || die "wheel sudoers rule invalid"
fi

if ! id "$ADMIN_USER" &>/dev/null; then
    warn "Admin user '$ADMIN_USER' does not exist — creating it now."
    useradd -m -G wheel -s /bin/bash "$ADMIN_USER"
    echo ""
    echo "  Set a password for the new admin user '$ADMIN_USER'"
    echo "  (you'll use this for F12 -> Admin Login and all sudo/remote admin):"

    # try up to 3 times, then bail out with clear instructions instead of
    # looping forever (an unwritable/half-created state can make passwd always fail)
    pw_ok=0
    for _try in 1 2 3; do
        if passwd "$ADMIN_USER"; then pw_ok=1; break; fi
        warn "passwd failed (attempt $_try/3)."
    done
    if [[ $pw_ok -ne 1 ]]; then
        echo ""
        warn "Could not set the admin password automatically."
        warn "Open ANOTHER terminal / TTY, run:   passwd $ADMIN_USER"
        warn "set the password there, then re-run this script (it will skip creation)."
        die "Stopping so you can set the password manually."
    fi
else
    echo "Admin user '$ADMIN_USER' already exists."
    # make sure it's actually in wheel (so it has sudo)
    usermod -aG wheel "$ADMIN_USER"
    # if it somehow has no password set, prompt once (but don't loop forever)
    if ! passwd -S "$ADMIN_USER" 2>/dev/null | grep -qE ' (P|PS) '; then
        warn "Admin '$ADMIN_USER' has no password set. Set one now:"
        passwd "$ADMIN_USER" || warn "Password still not set — set it manually with: passwd $ADMIN_USER"
    fi
fi

# ============================================================================
say "STEP 1/13  Installing official packages"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
    xorg-server xorg-xinit xorg-xset xorg-xhost \
    openbox rofi chromium pcmanfm \
    xterm ttf-dejavu git base-devel

# ============================================================================
say "STEP 2/13  Ensuring yay (AUR helper) is installed"

# makepkg runs 'sudo pacman' internally to install built packages. Since this
# script runs unattended, grant admin TEMPORARY passwordless sudo for the build,
# then revoke it at the end of STEP 3.
TMP_SUDO="/etc/sudoers.d/00-kiosk-build-temp"
echo "${ADMIN_USER} ALL=(ALL) NOPASSWD: ALL" > "$TMP_SUDO"
chmod 440 "$TMP_SUDO"
cleanup_tmp_sudo() { rm -f "$TMP_SUDO"; }
trap cleanup_tmp_sudo EXIT

if ! command -v yay &>/dev/null; then
    warn "yay not found — building it as $ADMIN_USER"
    sudo -u "$ADMIN_USER" bash -c '
        set -e
        cd /tmp
        rm -rf yay-bin
        git clone https://aur.archlinux.org/yay-bin.git
        cd yay-bin
        makepkg -si --noconfirm
    '
else
    echo "yay already present."
fi

# ============================================================================
say "STEP 3/13  Installing RustDesk (from AUR)"
if ! command -v rustdesk &>/dev/null; then
    sudo -u "$ADMIN_USER" yay -S --noconfirm rustdesk-bin
else
    echo "rustdesk already present."
fi

# revoke the temporary passwordless sudo now that AUR builds are done
cleanup_tmp_sudo
trap - EXIT

# ============================================================================
say "STEP 4/13  Creating locked-down kiosk user"
if ! id "$KIOSK_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$KIOSK_USER"
    echo "Created user '$KIOSK_USER' (NOT in wheel group -> no sudo)."
fi
# make absolutely sure kiosk has no sudo
gpasswd -d "$KIOSK_USER" wheel 2>/dev/null || true

# set the kiosk password: use KIOSK_PASSWORD if provided, else prompt.
# A KNOWN password matters because polkit / su / screen dialogs may ask for it.
if [[ -n "$KIOSK_PASSWORD" ]]; then
    echo "${KIOSK_USER}:${KIOSK_PASSWORD}" | chpasswd
    echo "Kiosk password set from config."
elif [[ -t 0 ]]; then
    echo ""
    echo "  Set a password for the kiosk user (you may need it for polkit / su prompts):"
    passwd "$KIOSK_USER" || warn "Kiosk password not set — set later with: sudo passwd $KIOSK_USER"
else
    # non-interactive (e.g. curl | bash) and no KIOSK_PASSWORD given -> sane default
    echo "${KIOSK_USER}:kiosk" | chpasswd
    warn "No KIOSK_PASSWORD set and running non-interactively — defaulted kiosk password to 'kiosk'. CHANGE IT with: sudo passwd $KIOSK_USER"
fi

# ============================================================================
say "STEP 5/13  Deploying the Flutter app to $APP_DIR"
mkdir -p "$APP_DIR"
if [[ -n "$APP_REPO" ]]; then
    # clone the bundle from git into a temp dir, then copy its contents in
    TMP_CLONE="$(mktemp -d)"
    echo "Cloning app from $APP_REPO ..."
    git clone --depth 1 "$APP_REPO" "$TMP_CLONE" || die "git clone failed: $APP_REPO"
    # copy everything except the .git folder
    (shopt -s dotglob; cp -r "$TMP_CLONE"/* "$APP_DIR"/ 2>/dev/null || true)
    rm -rf "$APP_DIR/.git" "$TMP_CLONE"
    echo "Deployed app from repo."
elif [[ -n "$APP_SRC" ]]; then
    [[ -d "$APP_SRC" ]] || die "APP_SRC '$APP_SRC' not found. Fix the path at the top of this script."
    cp -r "${APP_SRC}/." "$APP_DIR/"
    echo "Copied app from $APP_SRC"
else
    warn "APP_REPO and APP_SRC both empty — assuming you already placed the app in $APP_DIR."
fi
chown -R root:root "$APP_DIR"
chmod -R 755 "$APP_DIR"
chmod +x "${APP_DIR}/${APP_BINARY}" 2>/dev/null || true
[[ -x "${APP_DIR}/${APP_BINARY}" ]] || warn "Binary ${APP_DIR}/${APP_BINARY} not found/executable — check APP_BINARY."

# ============================================================================
say "STEP 6/13  Configuring autologin on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF

# ============================================================================
say "STEP 7/13  Writing .bash_profile (auto-start X, cursor VISIBLE)"
cat > "${KIOSK_HOME}/.bash_profile" <<'EOF'
[[ -f ~/.bashrc ]] && . ~/.bashrc

if [[ -z $DISPLAY ]] && [[ $(tty) == /dev/tty1 ]]; then
  while true; do
    startx -- vt1
    sleep 2
  done
fi
EOF

# ---- .xinitrc (cursor visible: no -nocursor, no unclutter) ----
say "STEP 8/13  Writing .xinitrc (starts app service + gives root display access for RustDesk)"
cat > "${KIOSK_HOME}/.xinitrc" <<'EOF'
#!/bin/bash
# Tell apps this is an X11 session. Because we start X with startx (no display
# manager), XDG_SESSION_TYPE is otherwise empty and RustDesk reports
# "Unsupported display server tty, x11 expected". These exports fix that.
export XDG_SESSION_TYPE=x11
export XDG_SESSION_DESKTOP=openbox
export XDG_CURRENT_DESKTOP=openbox

# Disable screen blanking / power saving
xset s off
xset -dpms
xset s noblank

# Let the RustDesk root service access this X session
xhost +si:localuser:root

# Hand systemd user services the display + session info, then start the app
systemctl --user import-environment DISPLAY XAUTHORITY XDG_SESSION_TYPE XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP
systemctl --user start kiosk-app.service

# Openbox is the session (must be last)
exec openbox-session
EOF

# ============================================================================
say "STEP 9/13  Creating the app systemd USER service (auto-restart)"
mkdir -p "${KIOSK_HOME}/.config/systemd/user"
cat > "${KIOSK_HOME}/.config/systemd/user/kiosk-app.service" <<EOF
[Unit]
Description=Flutter Kiosk App

[Service]
ExecStart=${APP_DIR}/${APP_BINARY}
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

# ============================================================================
say "STEP 10/13  Openbox config (F12 menu + Alt+F4 to close, no decorations)"
mkdir -p "${KIOSK_HOME}/.config/openbox"
cat > "${KIOSK_HOME}/.config/openbox/rc.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <focus><focusNew>yes</focusNew></focus>
  <keyboard>
    <keybind key="F12">
      <action name="Execute"><command>/usr/local/bin/kiosk-menu</command></action>
    </keybind>
    <keybind key="A-F4">
      <action name="Close"/>
    </keybind>
  </keyboard>
  <applications>
    <application class="*">
      <decor>no</decor>
    </application>
    <application title="*">
      <maximized>yes</maximized>
    </application>
  </applications>
</openbox_config>
EOF

# ============================================================================
say "STEP 11/13  The F12 menu script + reboot sudoers rule"
cat > /usr/local/bin/kiosk-menu <<'EOF'
#!/bin/bash
choice=$(printf "Restart App\nRustDesk\nChrome\nFile Manager\nTerminal\nAdmin Login\nReboot System" \
  | rofi -dmenu -i -p "Kiosk Menu" -lines 7)

case "$choice" in
  "Restart App")   systemctl --user restart kiosk-app.service ;;
  "RustDesk")      rustdesk & ;;
  "Chrome")        chromium & ;;
  "File Manager")  pcmanfm & ;;
  "Terminal")      xterm & ;;
  "Admin Login")   xterm -e "su - ADMIN_PLACEHOLDER" & ;;
  "Reboot System") sudo /usr/bin/systemctl reboot ;;
esac
EOF
sed -i "s/ADMIN_PLACEHOLDER/${ADMIN_USER}/" /usr/local/bin/kiosk-menu
chmod 755 /usr/local/bin/kiosk-menu
chown root:root /usr/local/bin/kiosk-menu

# allow kiosk to run ONLY reboot with sudo
echo "${KIOSK_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reboot" > /etc/sudoers.d/kiosk-reboot
chmod 440 /etc/sudoers.d/kiosk-reboot
visudo -cf /etc/sudoers.d/kiosk-reboot >/dev/null || die "sudoers rule invalid"

# ============================================================================
say "STEP 12/13  RustDesk background service (unkillable, auto-restart)"
# enable whatever the service is actually called
RD_UNIT=$(systemctl list-unit-files | awk '/rustdesk/{print $1; exit}')
if [[ -n "${RD_UNIT:-}" ]]; then
    systemctl enable "$RD_UNIT"
    mkdir -p "/etc/systemd/system/${RD_UNIT}.d"
    cat > "/etc/systemd/system/${RD_UNIT}.d/override.conf" <<'EOF'
[Service]
Restart=always
RestartSec=3
EOF
    systemctl daemon-reload
    systemctl restart "$RD_UNIT" || true
    echo "RustDesk service '$RD_UNIT' enabled with Restart=always."
else
    warn "No rustdesk systemd unit found. After reboot run RustDesk once, then re-check."
fi

# ============================================================================
say "STEP 13/13  Pre-creating writable app-config dirs, then LOCKING everything down"

# Writable sandboxes so chromium / pcmanfm don't crash on first launch.
# IMPORTANT: chromium needs BOTH ~/.config/chromium (profile) AND
# ~/.cache/chromium (crashpad database) — a missing ~/.cache/chromium is the
# "chrome_crashpad_handler: --database is required" error.
#
# NOTE: earlier steps created ~/.config (via systemd/openbox) as ROOT, so the
# kiosk user CANNOT mkdir inside it. We therefore create every dir as ROOT here,
# then hand ownership of the app dirs back to kiosk.
CFG_DIRS=(chromium pcmanfm libfm gtk-3.0 dconf)
CACHE_DIRS=(chromium)

# make sure the home + base dirs exist and belong to kiosk
mkdir -p "${KIOSK_HOME}/.config" "${KIOSK_HOME}/.cache"

# create all writable subdirs AS ROOT (always works), then chown to kiosk
for d in "${CFG_DIRS[@]}"; do
    mkdir -p "${KIOSK_HOME}/.config/${d}"
    chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config/${d}"
    chmod -R 755 "${KIOSK_HOME}/.config/${d}"
done
for d in "${CACHE_DIRS[@]}"; do
    mkdir -p "${KIOSK_HOME}/.cache/${d}"
done
# the whole ~/.cache belongs to kiosk (chromium writes lots of subdirs there)
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.cache"
chmod 755 "${KIOSK_HOME}/.cache"

# verify chromium can actually write its dirs (fail loudly if not)
if ! sudo -u "$KIOSK_USER" test -w "${KIOSK_HOME}/.config/chromium" \
   || ! sudo -u "$KIOSK_USER" test -w "${KIOSK_HOME}/.cache/chromium"; then
    warn "Chromium dirs are NOT writable by ${KIOSK_USER} — Chrome will fail!"
    warn "Check ownership of ${KIOSK_HOME}/.config/chromium and ${KIOSK_HOME}/.cache/chromium"
else
    echo "Chromium profile + cache dirs writable by ${KIOSK_USER}. Good."
fi

# lock the kiosk-owned config that must NOT be editable/deletable
chown root:root "${KIOSK_HOME}/.bash_profile" "${KIOSK_HOME}/.xinitrc"
chmod 644       "${KIOSK_HOME}/.bash_profile" "${KIOSK_HOME}/.xinitrc"

chown -R root:root "${KIOSK_HOME}/.config/openbox" "${KIOSK_HOME}/.config/systemd"
chmod -R 755       "${KIOSK_HOME}/.config/openbox" "${KIOSK_HOME}/.config/systemd"
find "${KIOSK_HOME}/.config/openbox" "${KIOSK_HOME}/.config/systemd" -type f -exec chmod 644 {} \;

# the .config dir itself root-owned so kiosk can't delete the locked subfolders,
# but it stays traversable so the writable app dirs above still work
chown root:root "${KIOSK_HOME}/.config"
chmod 755       "${KIOSK_HOME}/.config"

# ============================================================================
say "Installing the per-device first-setup helper (for cloned machines)"
cat > /usr/local/bin/first-setup <<'EOF'
#!/bin/bash
# Give a freshly cloned kiosk a unique identity.
# Usage: sudo first-setup kiosk-01
[[ $EUID -eq 0 ]]  || { echo "Run with sudo: sudo first-setup kiosk-01"; exit 1; }
[[ -n "$1" ]]      || { echo "Usage: sudo first-setup <name>"; exit 1; }
NEWNAME="$1"
echo "==> hostname -> $NEWNAME"; hostnamectl set-hostname "$NEWNAME"
echo "==> regenerating machine-id"; rm -f /etc/machine-id; systemd-machine-id-setup
echo "==> resetting RustDesk ID"
RD=$(systemctl list-unit-files | awk '/rustdesk/{print $1; exit}')
[[ -n "$RD" ]] && systemctl stop "$RD"
rm -f /root/.config/rustdesk/RustDesk*.toml
[[ -n "$RD" ]] && systemctl start "$RD"; sleep 3
echo "=========================================="
echo " Device: $NEWNAME"
echo " Open RustDesk (F12) and set the permanent password!"
echo "=========================================="
read -p "Reboot now? [y/N] " a; [[ "$a" == y || "$a" == Y ]] && reboot
EOF
chmod 755 /usr/local/bin/first-setup
chown root:root /usr/local/bin/first-setup

# ============================================================================
say "DONE. Summary:"
cat <<EOF

  Kiosk user .......... ${KIOSK_USER}  (no sudo, autologin on tty1)
  Admin user .......... ${ADMIN_USER}  (full sudo)
  App ................. ${APP_DIR}/${APP_BINARY}  (systemd user service, auto-restart)
  F12 menu ............ Restart App / RustDesk / Chrome / File Manager / Terminal / Admin Login / Reboot
  Alt+F4 .............. closes windows (app just auto-restarts)
  Cursor .............. visible
  RustDesk ............ background service, Restart=always, starts at boot
  Configs ............. root-owned, kiosk cannot edit or delete
  first-setup ......... /usr/local/bin/first-setup  (run once per cloned device)

  NEXT:
    1) reboot
    2) after boot: F12 -> RustDesk -> set a PERMANENT unattended password
    3) test: F12 -> Restart App, Alt+F4 on app, F12 -> Admin Login
    4) (optional hardening, do LAST) block TTY switching:
         create /etc/X11/xorg.conf.d/10-kiosk.conf with DontVTSwitch/DontZap

  Reboot now?
EOF
read -p "  [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] && reboot || echo "Reboot later with: sudo reboot"
