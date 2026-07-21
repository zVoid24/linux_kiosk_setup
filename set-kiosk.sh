#!/bin/bash
###############################################################################
# setup-kiosk.sh  —  One-shot Arch Linux Flutter kiosk builder
#
# Turns a FRESH Arch install into a locked-down kiosk in one run.
#
# PREREQUISITES (must already be true before running):
#   - Arch is installed and booted
#   - A sudo user 'admin' exists (or set ADMIN_USER below)
#   - Internet works (ping archlinux.org)
#   - Your Flutter app's release bundle is available somewhere (set APP_SRC)
#
# RUN IT LIKE THIS (as the admin user):
#   chmod +x setup-kiosk.sh
#   sudo ./setup-kiosk.sh
#
# Everything is idempotent-ish: safe to re-run if something fails midway.
###############################################################################

set -euo pipefail

##############################  CONFIG — EDIT ME  #############################
ADMIN_USER="admin"          # your existing sudo user
KIOSK_USER="kiosk"          # the locked-down user (created by this script)

# Where your built Flutter Linux app lives RIGHT NOW (the release bundle folder).
# Leave empty ("") if you have ALREADY put your app in /opt/myapp yourself.
APP_SRC="/home/${ADMIN_USER}/myapp-bundle"

# Name of your Flutter executable inside the bundle (the binary, not a .sh):
APP_BINARY="myapp"

# Install location (do not usually need to change):
APP_DIR="/opt/myapp"
##############################################################################

# ---- helpers ---------------------------------------------------------------
say()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m!!  $*\033[0m"; }
die()  { echo -e "\033[1;31mERROR: $*\033[0m"; exit 1; }

# ---- sanity checks ---------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo ./setup-kiosk.sh"
[[ -n "${SUDO_USER:-}" ]] || die "Run via sudo from your admin account, not as raw root."
id "$ADMIN_USER" &>/dev/null || die "Admin user '$ADMIN_USER' does not exist. Create it first."
ping -c1 -W3 archlinux.org &>/dev/null || die "No internet. Connect first (nmcli / systemctl start NetworkManager)."

KIOSK_HOME="/home/${KIOSK_USER}"

# ============================================================================
say "STEP 1/13  Installing official packages"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
    xorg-server xorg-xinit xorg-xset xorg-xhost \
    openbox rofi chromium pcmanfm \
    xterm ttf-dejavu git base-devel

# ============================================================================
say "STEP 2/13  Ensuring yay (AUR helper) is installed"
if ! command -v yay &>/dev/null; then
    warn "yay not found — building it as $SUDO_USER"
    sudo -u "$SUDO_USER" bash -c '
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
    sudo -u "$SUDO_USER" yay -S --noconfirm rustdesk-bin
else
    echo "rustdesk already present."
fi

# ============================================================================
say "STEP 4/13  Creating locked-down kiosk user"
if ! id "$KIOSK_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$KIOSK_USER"
    # random locked password; autologin bypasses it anyway
    echo "${KIOSK_USER}:$(openssl rand -base64 12)" | chpasswd
    echo "Created user '$KIOSK_USER' (NOT in wheel group -> no sudo)."
else
    echo "User '$KIOSK_USER' already exists."
fi
# make absolutely sure kiosk has no sudo
gpasswd -d "$KIOSK_USER" wheel 2>/dev/null || true

# ============================================================================
say "STEP 5/13  Deploying the Flutter app to $APP_DIR"
mkdir -p "$APP_DIR"
if [[ -n "$APP_SRC" ]]; then
    [[ -d "$APP_SRC" ]] || die "APP_SRC '$APP_SRC' not found. Fix the path at the top of this script."
    cp -r "${APP_SRC}/." "$APP_DIR/"
    echo "Copied app from $APP_SRC"
else
    warn "APP_SRC empty — assuming you already placed the app in $APP_DIR."
fi
chown -R root:root "$APP_DIR"
chmod -R 755 "$APP_DIR"
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
CFG_DIRS=(chromium pcmanfm libfm gtk-3.0 dconf)
CACHE_DIRS=(chromium)

# create as the kiosk user so ownership is correct from the start
for d in "${CFG_DIRS[@]}"; do
    sudo -u "$KIOSK_USER" mkdir -p "${KIOSK_HOME}/.config/${d}"
done
for d in "${CACHE_DIRS[@]}"; do
    sudo -u "$KIOSK_USER" mkdir -p "${KIOSK_HOME}/.cache/${d}"
done

# belt-and-suspenders: force correct ownership/perms regardless of prior state
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.cache"
for d in "${CFG_DIRS[@]}"; do
    chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config/${d}"
    chmod -R 755 "${KIOSK_HOME}/.config/${d}"
done
chmod 755 "${KIOSK_HOME}/.cache"

# verify chromium can actually write its dirs (fail loudly if not)
if ! sudo -u "$KIOSK_USER" test -w "${KIOSK_HOME}/.config/chromium" \
   || ! sudo -u "$KIOSK_USER" test -w "${KIOSK_HOME}/.cache/chromium"; then
    warn "Chromium dirs are not writable by ${KIOSK_USER} — Chrome may fail. Check ${KIOSK_HOME}/.config/chromium and ${KIOSK_HOME}/.cache/chromium ownership."
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
