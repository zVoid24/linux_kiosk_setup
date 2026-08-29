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
#     (configured via APP_REPO / APP_BRANCH / APP_SRC below)
#
# The admin (sudo) user is created automatically if it doesn't exist yet —
# you'll be prompted to set its password once.
#
# RUN IT LIKE THIS (as root on a fresh install, or via sudo):
#   chmod +x setup-kiosk.sh
#   ./setup-kiosk.sh                          # if logged in as root
#   sudo ./setup-kiosk.sh                     # if logged in as an existing sudo user
#
#   # deploy a specific branch/tag without editing this file:
#   sudo APP_BRANCH=release-2.1 ./setup-kiosk.sh
#
# Everything is idempotent-ish: safe to re-run if something fails midway.
#
# ---------------------------------------------------------------------------
# HARDWARE ACCESS GRANTED TO THE KIOSK USER:
#   RS485 / serial ... group 'uucp'  -> /dev/ttyS*, /dev/ttyUSB*, /dev/ttyACM*
#   Digital IO ....... group 'gpio'  -> /dev/gpiochip* (ITE IT8786 Super-I/O)
#   Neither needs sudo at runtime, which matters because the kiosk user has none.
#
# ---------------------------------------------------------------------------
# CONTROLS AFTER SETUP:
#   F12 ............. Kiosk menu:  Restart App | Reboot System   (that's all)
#   Ctrl+Alt+C ...... Open Chrome
#   Ctrl+Alt+R ...... Open RustDesk
#   Ctrl+Alt+T ...... Open Terminal -> pick Kiosk/Admin -> asks for that
#                     user's PASSWORD before you get a shell.
#   Alt+F4 .......... Closes admin windows (Chrome/RustDesk/Terminal) only.
#                     The Modbus app is PROTECTED and can never be closed.
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

# App launch keybinds (openbox syntax: C = Ctrl, A = Alt, W = Super/Windows).
# Change these if you want different / more obscure combos.
CHROME_KEYBIND="C-A-c"      # Ctrl+Alt+C -> Chrome
RUSTDESK_KEYBIND="C-A-r"    # Ctrl+Alt+R -> RustDesk
TERMINAL_KEYBIND="C-A-t"    # Ctrl+Alt+T -> Terminal (password-gated)

# ---- Where your Flutter app comes from -------------------------------------
# Option 1 (default): clone the app bundle from a git repo.
APP_REPO="https://github.com/zVoid24/modbus_linux_bundle.git"

# Branch (or TAG) to deploy. This changes per release, so it can also be
# overridden at runtime without editing this file:
#     sudo APP_BRANCH=release-2.1 ./setup-kiosk.sh
# Leave it "" to just use whatever the repo's default branch is.
# NOTE: a bare commit SHA will NOT work here (shallow clone limitation) —
# use APP_COMMIT below for that instead.
APP_BRANCH="${APP_BRANCH:-main}"

# Optional: pin an exact commit SHA. If set, the clone is done full-depth on
# APP_BRANCH and then checked out at this commit. Leave "" to ignore.
APP_COMMIT="${APP_COMMIT:-}"

# Option 2: use a local folder already on disk instead of git.
#   Leave APP_REPO="" and set APP_SRC to the bundle folder path.
#   If BOTH are empty, the script assumes you already put the app in APP_DIR.
APP_SRC=""

# Name of your Flutter executable inside the bundle (the binary, not a .sh):
APP_BINARY="modbus"

# Install location (do not usually need to change):
APP_DIR="/opt/hybridController"

# ---- GPIO (digital IO) ------------------------------------------------------
# Kernel module for this board's Super-I/O GPIO controller. The Norqin panel
# PC uses an ITE IT8786, driven by gpio-it87. Set to "" to skip module setup
# entirely (e.g. if the chip is already built into your kernel).
GPIO_MODULE="gpio-it87"

# Group that owns /dev/gpiochip*. Arch does not ship a 'gpio' group, so this
# script creates it.
GPIO_GROUP="gpio"
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
say "STEP 0/14  Ensuring admin user '$ADMIN_USER' exists with sudo"

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
    echo "  (you'll use this for the Admin terminal and all sudo/remote admin):"

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
say "STEP 1/14  Installing official packages"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
    xorg-server xorg-xinit xorg-xset xorg-xhost \
    openbox rofi chromium pcmanfm \
    xterm xdotool ttf-dejavu git base-devel libgpiod
# NOTE: xdotool powers the "protect the Modbus window from Alt+F4" guard in
# STEP 11. libgpiod is NOT used by the app (it talks to the chardev ioctl ABI
# directly) — it is installed for gpiodetect/gpioinfo, which are the fastest
# way to debug a dead GPIO on-site.

# ============================================================================
say "STEP 2/14  Ensuring yay (AUR helper) is installed"

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
say "STEP 3/14  Installing RustDesk (from AUR)"
if ! command -v rustdesk &>/dev/null; then
    sudo -u "$ADMIN_USER" yay -S --noconfirm rustdesk-bin
else
    echo "rustdesk already present."
fi

# revoke the temporary passwordless sudo now that AUR builds are done
cleanup_tmp_sudo
trap - EXIT

# ============================================================================
say "STEP 4/14  Creating locked-down kiosk user"
if ! id "$KIOSK_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$KIOSK_USER"
    echo "Created user '$KIOSK_USER' (NOT in wheel group -> no sudo)."
fi
# make absolutely sure kiosk has no sudo
gpasswd -d "$KIOSK_USER" wheel 2>/dev/null || true

# ---- RS485 / serial hardware access ----------------------------------------
# Arch assigns real serial ports (and most USB-to-serial adapters) to group
# 'uucp' (Debian/Ubuntu use 'dialout' instead; 'uucp' is correct here).
# Without this, reading any Modbus RTU meter over a serial port fails with
# "no permission to access it".
usermod -aG uucp "$KIOSK_USER"
echo "Added '$KIOSK_USER' to group 'uucp' (serial / RS485 access)."

# ---- GPIO / digital IO access ----------------------------------------------
# The app opens /dev/gpiochip0 directly through the Linux GPIO character
# device ioctl ABI. Arch ships no 'gpio' group, so create it here; the udev
# rule in STEP 12 hands the chip node to it. Without this, open() returns
# EACCES and every digital IO silently fails — and the kiosk user has no sudo
# to work around it at runtime.
groupadd -f "$GPIO_GROUP"
usermod -aG "$GPIO_GROUP" "$KIOSK_USER"
echo "Added '$KIOSK_USER' to group '$GPIO_GROUP' (/dev/gpiochip* access)."

# NOTE ON GROUP TIMING: a systemd --user manager inherits its supplementary
# groups from the PAM session that spawned it and can never change them
# afterwards. Both usermod calls above happen BEFORE enable-linger (STEP 9)
# and before the final reboot, so the app picks them up. If you ever add a
# group to this user later, a re-login is NOT enough — run
# 'loginctl terminate-user kiosk' or reboot.

# set the kiosk password: use KIOSK_PASSWORD if provided, else prompt.
# A KNOWN password matters because polkit / su / screen dialogs may ask for it,
# AND because the Terminal in the Apps menu now REQUIRES it (see STEP 11).
if [[ -n "$KIOSK_PASSWORD" ]]; then
    echo "${KIOSK_USER}:${KIOSK_PASSWORD}" | chpasswd
    echo "Kiosk password set from config."
elif [[ -t 0 ]]; then
    echo ""
    echo "  Set a password for the kiosk user (needed for the Terminal / polkit / su prompts):"
    passwd "$KIOSK_USER" || warn "Kiosk password not set — set later with: sudo passwd $KIOSK_USER"
else
    # non-interactive (e.g. curl | bash) and no KIOSK_PASSWORD given -> sane default
    echo "${KIOSK_USER}:kiosk" | chpasswd
    warn "No KIOSK_PASSWORD set and running non-interactively — defaulted kiosk password to 'kiosk'. CHANGE IT with: sudo passwd $KIOSK_USER"
fi

# ============================================================================
say "STEP 5/14  Deploying the Flutter app to $APP_DIR"
mkdir -p "$APP_DIR"
if [[ -n "$APP_REPO" ]]; then
    # clone the bundle from git into a temp dir, then copy its contents in
    TMP_CLONE="$(mktemp -d)"
    echo "Repo ...... $APP_REPO"
    echo "Branch .... ${APP_BRANCH:-<repo default>}"
    [[ -n "$APP_COMMIT" ]] && echo "Commit .... $APP_COMMIT"

    if [[ -n "$APP_COMMIT" ]]; then
        # full clone needed so an arbitrary SHA is reachable
        if [[ -n "$APP_BRANCH" ]]; then
            git clone --branch "$APP_BRANCH" "$APP_REPO" "$TMP_CLONE" \
                || die "git clone failed: $APP_REPO (branch '$APP_BRANCH' — does it exist?)"
        else
            git clone "$APP_REPO" "$TMP_CLONE" || die "git clone failed: $APP_REPO"
        fi
        git -C "$TMP_CLONE" checkout --detach "$APP_COMMIT" \
            || die "git checkout failed: commit '$APP_COMMIT' not found in $APP_REPO"
    elif [[ -n "$APP_BRANCH" ]]; then
        # shallow, single-branch clone — fastest for a normal branch/tag deploy
        git clone --depth 1 --single-branch --branch "$APP_BRANCH" "$APP_REPO" "$TMP_CLONE" \
            || die "git clone failed: $APP_REPO (branch/tag '$APP_BRANCH' — does it exist?)"
    else
        git clone --depth 1 "$APP_REPO" "$TMP_CLONE" || die "git clone failed: $APP_REPO"
    fi

    # record what was actually deployed (handy when debugging a device later)
    DEPLOYED_REF="$(git -C "$TMP_CLONE" rev-parse --short HEAD 2>/dev/null || echo unknown)"

    # copy everything except the .git folder
    (shopt -s dotglob; cp -r "$TMP_CLONE"/* "$APP_DIR"/ 2>/dev/null || true)
    rm -rf "$APP_DIR/.git" "$TMP_CLONE"

    # leave a breadcrumb on disk
    {
        echo "repo=$APP_REPO"
        echo "branch=${APP_BRANCH:-<default>}"
        echo "commit=$DEPLOYED_REF"
        echo "deployed=$(date -Is)"
    } > "${APP_DIR}/.deployed-version"
    chmod 644 "${APP_DIR}/.deployed-version"

    echo "Deployed app from repo (branch '${APP_BRANCH:-<default>}' @ $DEPLOYED_REF)."
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
say "STEP 6/14  Configuring autologin on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF

# ============================================================================
say "STEP 7/14  Writing .bash_profile (auto-start X, cursor VISIBLE)"
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
say "STEP 8/14  Writing .xinitrc (starts app service + gives root display access for RustDesk)"
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
say "STEP 9/14  Creating the app systemd USER service (UN-KILLABLE, auto-restart)"
mkdir -p "${KIOSK_HOME}/.config/systemd/user"
# StartLimitIntervalSec=0 disables systemd's default "give up after 5 restarts
# in 10s" rate limit, so the Modbus app is relaunched forever no matter what.
cat > "${KIOSK_HOME}/.config/systemd/user/kiosk-app.service" <<EOF
[Unit]
Description=Flutter Kiosk App
StartLimitIntervalSec=0

[Service]
ExecStart=${APP_DIR}/${APP_BINARY}
Restart=always
RestartSec=1
# Raises the default 1024 soft fd limit to match this system's hard ceiling.
# A slow fd leak (fixed in the app itself, but this is cheap extra headroom
# against any future one) previously exhausted the default 1024 within
# ~8 hours of 24/7 runtime, after which Process.start() failed for
# everything and the backend could never respawn until the app restarted.
LimitNOFILE=524288
# Backstop only — there is no known leak, but this box has no memory ceiling
# of any kind and an unbounded one would otherwise let the kernel OOM killer
# pick an arbitrary victim (X, the daemon, or this app). A restart here costs
# ~1s and is always preferable to an OOM cascade on a kiosk. Raise this if the
# app legitimately needs more; steady state is a few hundred MB.
MemoryMax=2G

[Install]
WantedBy=default.target
EOF

# Keep the kiosk user's systemd --user manager alive independent of login
# sessions, so logind can't sweep the app when a session ends. This is the
# operational fix for the SIGKILL session-teardown case (which no in-app
# signal handler can catch).
loginctl enable-linger "${KIOSK_USER}"

# ============================================================================
say "STEP 10/14  Openbox config (F12 menu + app keybinds + protected Alt+F4)"
mkdir -p "${KIOSK_HOME}/.config/openbox"
cat > "${KIOSK_HOME}/.config/openbox/rc.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <focus><focusNew>yes</focusNew></focus>
  <keyboard>
    <!-- F12: kiosk menu (Restart App / Reboot only) -->
    <keybind key="F12">
      <action name="Execute"><command>/usr/local/bin/kiosk-menu</command></action>
    </keybind>
    <!-- Ctrl+Alt+C -> Chrome -->
    <keybind key="${CHROME_KEYBIND}">
      <action name="Execute"><command>chromium</command></action>
    </keybind>
    <!-- Ctrl+Alt+R -> RustDesk -->
    <keybind key="${RUSTDESK_KEYBIND}">
      <action name="Execute"><command>rustdesk</command></action>
    </keybind>
    <!-- Ctrl+Alt+T -> Terminal (asks which user + that user's password) -->
    <keybind key="${TERMINAL_KEYBIND}">
      <action name="Execute"><command>/usr/local/bin/kiosk-terminal</command></action>
    </keybind>
    <!-- Alt+F4: close focused window UNLESS it is the protected Modbus app -->
    <keybind key="A-F4">
      <action name="Execute"><command>/usr/local/bin/kiosk-close</command></action>
    </keybind>
    <!-- Alt+Tab -> cycle windows forward -->
    <keybind key="A-Tab">
      <action name="NextWindow">
        <finalactions>
          <action name="Focus"/>
          <action name="Raise"/>
          <action name="Unshade"/>
        </finalactions>
      </action>
    </keybind>
    <!-- Alt+Shift+Tab -> cycle windows backward -->
    <keybind key="A-S-Tab">
      <action name="PreviousWindow">
        <finalactions>
          <action name="Focus"/>
          <action name="Raise"/>
          <action name="Unshade"/>
        </finalactions>
      </action>
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
say "STEP 11/14  Menu scripts (F12 menu, password-gated Terminal, close-guard)"

# ---- F12 menu: ONLY Restart App + Reboot ----------------------------------
cat > /usr/local/bin/kiosk-menu <<'EOF'
#!/bin/bash
choice=$(printf "Restart App\nReboot System" \
  | rofi -dmenu -i -p "Kiosk Menu" -lines 2)

case "$choice" in
  "Restart App")   systemctl --user restart kiosk-app.service ;;
  "Reboot System") sudo /usr/bin/systemctl reboot ;;
esac
EOF
chmod 755 /usr/local/bin/kiosk-menu
chown root:root /usr/local/bin/kiosk-menu

# ---- Terminal: pick which user, then su asks for THAT user's password -----
# Opening the terminal via 'su - <user>' means a shell is NEVER handed out
# without the correct password — even for the kiosk user. So merely reaching
# the terminal does not expose the filesystem.
# xterm font: -fa/-fs use a scalable TrueType face (DejaVu Sans Mono, installed
# via ttf-dejavu) at 14pt so the terminal text isn't tiny.
cat > /usr/local/bin/kiosk-terminal <<'EOF'
#!/bin/bash
# Ensure DISPLAY/XAUTHORITY are set so GUI apps launched by typing in the
# terminal (chromium, pcmanfm, rustdesk) can reach the running X server.
# startx stores its auth cookie in ~/.serverauth.* (not always ~/.Xauthority).
export DISPLAY="${DISPLAY:-:0}"
if [[ -z "${XAUTHORITY:-}" ]]; then
    XAUTHORITY=$(ls -1t "$HOME"/.serverauth.* "$HOME"/.Xauthority 2>/dev/null | head -1)
    export XAUTHORITY
fi

who=$(printf "Kiosk User\nAdmin User" \
  | rofi -dmenu -i -p "Terminal as? (password required)" -lines 2)

case "$who" in
  "Kiosk User")
      # 'su' WITHOUT '-' keeps DISPLAY + XAUTHORITY, so GUI apps work here.
      # Using 'su -' (login shell) would wipe them -> "cannot open display".
      # Password is still required, so the filesystem stays gated.
      xterm -fa 'DejaVu Sans Mono' -fs 14 -T "Kiosk Terminal — login required" -e "su KIOSK_PLACEHOLDER" & ;;
  "Admin User")
      # Admin gets a clean login shell for sudo / system work. Admin cannot
      # read the kiosk X cookie, so admin GUI apps won't display unless you add
      #   xhost +si:localuser:ADMIN_PLACEHOLDER   to ~/.xinitrc.
      xterm -fa 'DejaVu Sans Mono' -fs 14 -T "Admin Terminal — login required" -e "su - ADMIN_PLACEHOLDER" & ;;
esac
EOF
sed -i "s/KIOSK_PLACEHOLDER/${KIOSK_USER}/" /usr/local/bin/kiosk-terminal
sed -i "s/ADMIN_PLACEHOLDER/${ADMIN_USER}/" /usr/local/bin/kiosk-terminal
chmod 755 /usr/local/bin/kiosk-terminal
chown root:root /usr/local/bin/kiosk-terminal

# ---- Alt+F4 guard: close anything EXCEPT the Modbus app -------------------
# Identifies the protected window by the exact binary behind it (via its PID),
# so the Modbus app can never be closed, while admin windows still close.
cat > /usr/local/bin/kiosk-close <<'EOF'
#!/bin/bash
win=$(xdotool getactivewindow 2>/dev/null) || exit 0
[[ -n "$win" ]] || exit 0
pid=$(xdotool getwindowpid "$win" 2>/dev/null || true)
if [[ -n "$pid" ]]; then
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    if [[ "$exe" == "APP_EXE_PLACEHOLDER" ]]; then
        exit 0   # protected app — refuse to close
    fi
fi
xdotool windowclose "$win"
EOF
sed -i "s#APP_EXE_PLACEHOLDER#${APP_DIR}/${APP_BINARY}#" /usr/local/bin/kiosk-close
chmod 755 /usr/local/bin/kiosk-close
chown root:root /usr/local/bin/kiosk-close

# allow kiosk to run ONLY reboot with sudo (used by the F12 menu)
echo "${KIOSK_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl reboot" > /etc/sudoers.d/kiosk-reboot
chmod 440 /etc/sudoers.d/kiosk-reboot
visudo -cf /etc/sudoers.d/kiosk-reboot >/dev/null || die "sudoers rule invalid"

# ============================================================================
say "STEP 12/14  GPIO: Super-I/O driver + /dev/gpiochip* permissions"

# ---- kernel module ---------------------------------------------------------
# The IT8786 GPIO controller is not probed automatically — it needs gpio-it87.
if [[ -n "$GPIO_MODULE" ]]; then
    echo "$GPIO_MODULE" > "/etc/modules-load.d/${GPIO_MODULE}.conf"
    chmod 644 "/etc/modules-load.d/${GPIO_MODULE}.conf"
    if modprobe "$GPIO_MODULE" 2>/dev/null; then
        echo "Loaded kernel module '$GPIO_MODULE' (and set it to load at boot)."
    else
        warn "modprobe $GPIO_MODULE failed."
        warn "Most common cause: ACPI has already claimed the Super-I/O ports."
        warn "Check with:  dmesg | grep -iE 'it87|resource'"
        warn "Fix: add  acpi_enforce_resources=lax  to the kernel cmdline, reboot."
        warn "If the chip ID is not recognised, try:  modprobe $GPIO_MODULE force_id=0x8786"
    fi
fi

# ---- udev rule -------------------------------------------------------------
# Only the character device matters. The app (norqin_gpio.dart / ngpio) opens
# /dev/gpiochip0 and drives it through the GPIO chardev ioctl ABI — it never
# touches the legacy /sys/class/gpio export interface, so no sysfs rules here.
cat > /etc/udev/rules.d/99-gpio.rules <<EOF
# Hand the GPIO character device to group '${GPIO_GROUP}' so the kiosk user can
# open it without sudo. Terminals 1-8 on this board are gpiochip0 lines 48-55.
SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="${GPIO_GROUP}", MODE="0660"
EOF
chmod 644 /etc/udev/rules.d/99-gpio.rules
udevadm control --reload
udevadm trigger --subsystem-match=gpio || true

# ---- verify ----------------------------------------------------------------
if compgen -G "/dev/gpiochip*" >/dev/null; then
    echo "GPIO character devices present:"
    ls -l /dev/gpiochip*
    gpiodetect 2>/dev/null || true
    # the only check that really counts: can the kiosk user open the chip?
    if sudo -u "$KIOSK_USER" test -r /dev/gpiochip0 && sudo -u "$KIOSK_USER" test -w /dev/gpiochip0; then
        echo "'$KIOSK_USER' can read+write /dev/gpiochip0. Good."
    else
        warn "'$KIOSK_USER' still cannot access /dev/gpiochip0."
        warn "This is usually just group caching — it will be correct after the reboot."
        warn "Verify after boot with:  sudo -u $KIOSK_USER ngpio show"
    fi
else
    warn "No /dev/gpiochip* on this board — digital IO (terminals 1-8) will NOT work."
    warn "The udev rule is installed and will apply as soon as a chip appears."
    warn "Debug with:  dmesg | grep -i it87   /   modinfo $GPIO_MODULE   /   gpiodetect"
fi

# ============================================================================
say "STEP 13/14  RustDesk background service (unkillable, auto-restart)"
# enable whatever the service is actually called
RD_UNIT=$(systemctl list-unit-files 2>/dev/null | awk '/rustdesk/{print $1}' | head -n1 || true)
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
say "STEP 14/14  Pre-creating writable app-config dirs, then LOCKING everything down"

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

# ---------------------------------------------------------------------------
# FINAL Chromium fix — run LAST so nothing above can undo it.
# These are the exact commands confirmed to make Chrome work on a real kiosk:
#   the profile (~/.config/chromium) and crashpad DB (~/.cache/chromium) must
#   exist and be kiosk-owned. Hardcoded here so a fresh install never needs a
#   manual fixup.
mkdir -p "${KIOSK_HOME}/.config/chromium" "${KIOSK_HOME}/.cache/chromium"
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config/chromium" "${KIOSK_HOME}/.cache"
chmod -R 755 "${KIOSK_HOME}/.config/chromium" "${KIOSK_HOME}/.cache"
echo "Chromium profile + cache dirs created and owned by ${KIOSK_USER}."

# ============================================================================
say "Installing the app updater helper (re-deploy a different branch later)"
cat > /usr/local/bin/kiosk-update-app <<'EOF'
#!/bin/bash
# Re-deploy the Flutter bundle from git without re-running the whole setup.
# Usage: sudo kiosk-update-app [branch-or-tag] [commit-sha]
#        sudo kiosk-update-app release-2.1
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo kiosk-update-app <branch>"; exit 1; }

APP_REPO="REPO_PLACEHOLDER"
APP_DIR="APPDIR_PLACEHOLDER"
APP_BINARY="BINARY_PLACEHOLDER"
KIOSK_USER="KIOSKUSER_PLACEHOLDER"
BRANCH="${1:-BRANCH_PLACEHOLDER}"
COMMIT="${2:-}"

[[ -n "$APP_REPO" ]] || { echo "This kiosk was not deployed from git — nothing to update."; exit 1; }

TMP="$(mktemp -d)"
echo "==> cloning $APP_REPO (branch: $BRANCH)"
git clone --depth 1 --single-branch --branch "$BRANCH" "$APP_REPO" "$TMP"
if [[ -n "$COMMIT" ]]; then
    echo "==> fetching + checking out $COMMIT"
    git -C "$TMP" fetch --unshallow || true
    git -C "$TMP" checkout --detach "$COMMIT"
fi
REF="$(git -C "$TMP" rev-parse --short HEAD)"

echo "==> stopping app"
su - "$KIOSK_USER" -c 'systemctl --user stop kiosk-app.service' 2>/dev/null \
  || systemctl --user -M "${KIOSK_USER}@" stop kiosk-app.service 2>/dev/null || true

echo "==> replacing $APP_DIR"
rm -rf "${APP_DIR}.old"
[[ -d "$APP_DIR" ]] && mv "$APP_DIR" "${APP_DIR}.old"
mkdir -p "$APP_DIR"
(shopt -s dotglob; cp -r "$TMP"/* "$APP_DIR"/)
rm -rf "$APP_DIR/.git" "$TMP"
{ echo "repo=$APP_REPO"; echo "branch=$BRANCH"; echo "commit=$REF"; echo "deployed=$(date -Is)"; } \
  > "${APP_DIR}/.deployed-version"
chown -R root:root "$APP_DIR"; chmod -R 755 "$APP_DIR"
chmod +x "${APP_DIR}/${APP_BINARY}" 2>/dev/null || true

echo "==> starting app"
su - "$KIOSK_USER" -c 'systemctl --user start kiosk-app.service' 2>/dev/null \
  || systemctl --user -M "${KIOSK_USER}@" start kiosk-app.service 2>/dev/null || true

echo "Updated to $BRANCH @ $REF.  Previous version kept at ${APP_DIR}.old"
EOF
sed -i "s#REPO_PLACEHOLDER#${APP_REPO}#"        /usr/local/bin/kiosk-update-app
sed -i "s#APPDIR_PLACEHOLDER#${APP_DIR}#"       /usr/local/bin/kiosk-update-app
sed -i "s#BINARY_PLACEHOLDER#${APP_BINARY}#"    /usr/local/bin/kiosk-update-app
sed -i "s#KIOSKUSER_PLACEHOLDER#${KIOSK_USER}#" /usr/local/bin/kiosk-update-app
sed -i "s#BRANCH_PLACEHOLDER#${APP_BRANCH:-main}#" /usr/local/bin/kiosk-update-app
chmod 755 /usr/local/bin/kiosk-update-app
chown root:root /usr/local/bin/kiosk-update-app

# ============================================================================
say "Installing the GPIO diagnostic helper"
# One command an on-site technician can run to find out why digital IO is dead.
cat > /usr/local/bin/kiosk-gpio-check <<'EOF'
#!/bin/bash
# Diagnose GPIO access on this kiosk.  Usage: sudo kiosk-gpio-check
KIOSK_USER="KIOSKUSER_PLACEHOLDER"
GPIO_GROUP="GPIOGROUP_PLACEHOLDER"
GPIO_MODULE="GPIOMODULE_PLACEHOLDER"

echo "== kernel module =="
lsmod | grep -q "${GPIO_MODULE//-/_}" \
  && echo "  $GPIO_MODULE loaded" \
  || echo "  $GPIO_MODULE NOT loaded  ->  dmesg | grep -i it87"

echo "== chip nodes =="
ls -l /dev/gpiochip* 2>/dev/null || echo "  none — the driver did not bind"
command -v gpiodetect >/dev/null && gpiodetect 2>/dev/null

echo "== group membership (passwd database) =="
id "$KIOSK_USER"

echo "== group membership of the RUNNING app (this is what matters) =="
pid=$(systemctl --user -M "${KIOSK_USER}@" show kiosk-app.service -p MainPID --value 2>/dev/null)
if [[ -n "$pid" && "$pid" != "0" ]]; then
    gid=$(getent group "$GPIO_GROUP" | cut -d: -f3)
    groups_line=$(grep '^Groups:' "/proc/$pid/status" 2>/dev/null)
    echo "  pid $pid  $groups_line"
    echo "  $GPIO_GROUP gid = $gid"
    if [[ " $(echo "$groups_line" | cut -d: -f2) " == *" $gid "* ]]; then
        echo "  OK — the app has the $GPIO_GROUP group"
    else
        echo "  MISSING — run: loginctl terminate-user $KIOSK_USER   (or reboot)"
    fi
else
    echo "  app not running"
fi

echo "== can the kiosk user actually open the chip? =="
if sudo -u "$KIOSK_USER" test -r /dev/gpiochip0 && sudo -u "$KIOSK_USER" test -w /dev/gpiochip0; then
    echo "  yes"
else
    echo "  NO — check /etc/udev/rules.d/99-gpio.rules and group membership above"
fi

echo "== who is holding the lines? =="
# A stray 'ngpio watch' left running over SSH makes the app's open() return
# EBUSY. gpioinfo shows the consumer label of every claimed line.
command -v gpioinfo >/dev/null && gpioinfo 2>/dev/null | grep -E 'ngpio|used' | head -20
EOF
sed -i "s#KIOSKUSER_PLACEHOLDER#${KIOSK_USER}#"   /usr/local/bin/kiosk-gpio-check
sed -i "s#GPIOGROUP_PLACEHOLDER#${GPIO_GROUP}#"   /usr/local/bin/kiosk-gpio-check
sed -i "s#GPIOMODULE_PLACEHOLDER#${GPIO_MODULE}#" /usr/local/bin/kiosk-gpio-check
chmod 755 /usr/local/bin/kiosk-gpio-check
chown root:root /usr/local/bin/kiosk-gpio-check

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
RD=$(systemctl list-unit-files 2>/dev/null | awk '/rustdesk/{print $1}' | head -n1 || true)
[[ -n "$RD" ]] && systemctl stop "$RD"
rm -f /root/.config/rustdesk/RustDesk*.toml
[[ -n "$RD" ]] && systemctl start "$RD"; sleep 3
echo "=========================================="
echo " Device: $NEWNAME"
echo " Open RustDesk (Ctrl+Alt+R) and set the permanent password!"
echo "=========================================="
read -p "Reboot now? [y/N] " a; [[ "$a" == y || "$a" == Y ]] && reboot
EOF
chmod 755 /usr/local/bin/first-setup
chown root:root /usr/local/bin/first-setup

# ============================================================================
say "DONE. Summary:"
cat <<EOF

  Kiosk user .......... ${KIOSK_USER}  (no sudo, autologin on tty1)
                        group 'uucp'         -> RS485 / serial port access
                        group '${GPIO_GROUP}'         -> /dev/gpiochip* digital IO
  Admin user .......... ${ADMIN_USER}  (full sudo)
  App ................. ${APP_DIR}/${APP_BINARY}  (systemd user service)
                        Restart=always + no start-limit -> UN-KILLABLE
  Source .............. ${APP_REPO:-${APP_SRC:-<pre-placed in APP_DIR>}}
  Branch .............. ${APP_BRANCH:-<repo default>}${APP_COMMIT:+  (pinned @ ${APP_COMMIT})}
                        recorded in ${APP_DIR}/.deployed-version
  GPIO ................ module '${GPIO_MODULE}' (loads at boot)
                        udev: /dev/gpiochip* -> root:${GPIO_GROUP} 0660
                        terminals 1-8 = gpiochip0 lines 48-55
  F12 menu ............ Restart App | Reboot System   (nothing else)
  Ctrl+Alt+C .......... Chrome
  Ctrl+Alt+R .......... RustDesk
  Ctrl+Alt+T .......... Terminal — asks which user (Kiosk/Admin), then that user's
                        PASSWORD via 'su -' before any shell is given
  Alt+F4 .............. closes admin windows only; the Modbus app is
                        PROTECTED and will NOT close
  Cursor .............. visible
  RustDesk ............ background service, Restart=always, starts at boot
  Configs ............. root-owned, kiosk cannot edit or delete
  first-setup ......... /usr/local/bin/first-setup       (run once per cloned device)
  kiosk-update-app .... /usr/local/bin/kiosk-update-app  (re-deploy another branch)
  kiosk-gpio-check .... /usr/local/bin/kiosk-gpio-check  (diagnose dead digital IO)

  NEXT:
    1) reboot
    2) after boot: Ctrl+Alt+R (RustDesk) -> set a PERMANENT unattended password
    3) test: F12 -> Restart App;  Alt+F4 on the app (should NOT close);
             Ctrl+Alt+T -> Admin User (should ask for password)
    4) RS485: Settings -> RS485 -> enter port/baud/parity for this device
    5) GPIO:  sudo kiosk-gpio-check     (every line should say OK)
              sudo -u ${KIOSK_USER} ngpio show    (must work WITHOUT sudo)
    6) to STOP the app for maintenance: open a Terminal (password required),
       then:  systemctl --user stop kiosk-app.service
    7) to deploy a new branch later:  sudo kiosk-update-app <branch>
    8) (optional hardening, do LAST) block TTY switching:
         create /etc/X11/xorg.conf.d/10-kiosk.conf with DontVTSwitch/DontZap

EOF
warn "The kiosk user's group memberships (uucp, ${GPIO_GROUP}) only reach the running"
warn "app after a full reboot — a systemd --user manager cannot change its own"
warn "supplementary groups. Reboot before testing serial or GPIO."
echo ""
read -p "  Reboot now? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] && reboot || echo "Reboot later with: sudo reboot"
