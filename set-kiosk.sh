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
#
# ---------------------------------------------------------------------------
# BOOT BRANDING (STEP 15):
#   The boot logo is taken from the app bundle ($APP_DIR/$SPLASH_LOGO), so a
#   new app release re-brands the boot screen with no change to this script.
#   Re-brand an already-provisioned device with:  sudo set-splash
#
# ---------------------------------------------------------------------------
# devctl (remote support/admin CLI — GPIO config, device/formula/SLD edits,
# power control): installed automatically from DEVCTL_AUTHORIZED_KEYS below,
# root-only + SSH-key-verified. Use it via:
#   ssh -A admin@<device>   then   sudo -E devctl health
# (this is a comment, so "admin" here is literal — substitute ADMIN_USER's
# actual value below if you changed it.) See devctl/README.md for the full
# setup story and troubleshooting.
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

# ---- Boot splash (custom boot logo) ----------------------------------------
# The logo is read from the app bundle, NOT from this script, so a new app
# release can re-brand the boot screen without touching setup-kiosk.sh.
# Put the file in the repo root as logo.png and it is picked up automatically.
#   Set SPLASH_LOGO="" to skip the boot splash entirely.
SPLASH_LOGO="logo.png"      # filename inside $APP_DIR
SPLASH_THEME="mylogo"       # plymouth theme name (derived from 'spinner')
SPLASH_WIDTH="400"          # rendered logo width in px; keep <= half the panel

# Loading indicator shown under the logo while booting:
#   "cubes" — plymouth's spinner cube animation (stock)
#   "bar"   — thin progress bar; no image files, cleanest on a panel PC
#   "dots"  — three pulsing dots, generated in SPLASH_ACCENT below
#   "none"  — logo on black, no indicator at all
SPLASH_STYLE="bar"

# Accent colour for the "bar" and "dots" styles. Hex, no alpha.
SPLASH_ACCENT="#00a3e0"

# ---- devctl (SCUBE internal support/admin CLI) ------------------------------
# devctl is a separate Go binary for on-site diagnostics/support (GPIO
# config, device/formula CRUD, SLD editing, power control, etc. — see
# devctl/README.md). It ships INSIDE the same git bundle as the Flutter app
# (APP_REPO above), so STEP 5's existing clone already delivers it — no
# separate fetch step needed. Path is relative to the bundle root.
DEVCTL_BINARY_REL="devctl-linux-amd64"

# One SSH public key per line (ed25519 recommended) — every developer/admin
# who should be able to run devctl on THIS device, baked in at provision
# time. Leave empty to install the binary but skip auth setup entirely (you
# can still wire it up by hand later per devctl/README.md). Add more keys
# later without re-running this script: append a line to
# $KIOSK_HOME/.local/share/com.scube.hybridcontroller/devctl_authorized_keys
DEVCTL_AUTHORIZED_KEYS=""
#   e.g.:
# DEVCTL_AUTHORIZED_KEYS="ssh-ed25519 AAAA... dev1@scube.com.bd
# ssh-ed25519 AAAA... dev2@scube.com.bd"
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
say "STEP 0/15  Ensuring admin user '$ADMIN_USER' exists with sudo"

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
say "STEP 1/15  Installing official packages"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
    xorg-server xorg-xinit xorg-xset xorg-xhost \
    openbox rofi chromium pcmanfm \
    xterm xdotool ttf-dejavu git base-devel libgpiod udisks2 ntfs-3g \
    plymouth imagemagick
# NOTE: xdotool powers the "protect the Modbus window from Alt+F4" guard in
# STEP 11. libgpiod is NOT used by the app (it talks to the chardev ioctl ABI
# directly) — it is installed for gpiodetect/gpioinfo, which are the fastest
# way to debug a dead GPIO on-site. udisks2 provides `udisksctl`, which
# usb_drive_service.dart shells out to for mounting removable drives — this
# kiosk has no desktop shell (gvfs/udiskie/Nautilus) to auto-mount USB sticks
# on insertion, so without udisks2 the app sees the block device (lsblk still
# works, it just reads sysfs) but never gets a mount point and reports no USB.
# ntfs-3g is needed alongside it — see the mount_options.conf provisioning
# below for why the in-kernel ntfs3 driver alone isn't enough.
# plymouth + imagemagick drive the custom boot splash in STEP 15; imagemagick
# is also what set-splash uses later to re-brand without a reinstall.

# udisks2 is D-Bus-activatable, but enabling it outright avoids relying on
# activation timing for something the app depends on every time.
systemctl enable --now udisks2

# A USB stick that gets yanked mid-export (no eject button on this kiosk)
# leaves NTFS's dirty bit set. udisks2 picks the in-kernel `ntfs3` driver by
# default when it's available, and ntfs3 refuses to mount a dirty volume at
# all unless given `force` — but `force` isn't a recognized option for the
# ntfs3 entry in udisks2's mount-option table, so it's rejected with
# OptionNotPermitted *no matter what* mount_options.conf allows; there is no
# way to pass it through udisksctl. ntfs-3g (FUSE), by contrast,
# auto-recovers a dirty volume by default with no extra options needed.
# Reordering `ntfs_drivers` below to prefer the already-installed ntfs-3g
# over ntfs3 fixes this outright — verified by hand: an NTFS stick left
# dirty by an unclean removal mounted and accepted writes immediately, no
# reformat needed.
install -d -m 755 /etc/udisks2
cat > /etc/udisks2/mount_options.conf <<'EOF'
[defaults]
allow=exec,noexec,nodev,nosuid,atime,noatime,nodiratime,relatime,strictatime,lazytime,ro,rw,sync,dirsync,noload,acl,nosymfollow

ntfs:ntfs_defaults=uid=$UID,gid=$GID,windows_names
ntfs:ntfs_allow=uid=$UID,gid=$GID,umask,dmask,fmask,locale,norecover,ignore_case,windows_names,compression,nocompression,big_writes,recover,remove_hiberfile

ntfs:ntfs3_defaults=uid=$UID,gid=$GID
ntfs:ntfs3_allow=uid=$UID,gid=$GID,umask,dmask,fmask,iocharset,discard,nodiscard,sparse,nosparse,hidden,nohidden,sys_immutable,nosys_immutable,showmeta,noshowmeta,prealloc,noprealloc,hide_dot_files,nohide_dot_files,windows_names,nocase,case

ntfs_drivers=ntfs,ntfs3
EOF
# udisks2 only reads this file at daemon start, not on file change.
systemctl restart udisks2

# ============================================================================
say "STEP 2/15  Ensuring yay (AUR helper) is installed"

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
say "STEP 3/15  Installing RustDesk (from AUR)"
if ! command -v rustdesk &>/dev/null; then
    sudo -u "$ADMIN_USER" yay -S --noconfirm rustdesk-bin
else
    echo "rustdesk already present."
fi

# revoke the temporary passwordless sudo now that AUR builds are done
cleanup_tmp_sudo
trap - EXIT

# ============================================================================
say "STEP 4/15  Creating locked-down kiosk user"
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
say "STEP 5/15  Deploying the Flutter app to $APP_DIR"
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
say "STEP 6/15  Configuring autologin on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF

# ============================================================================
say "STEP 7/15  Writing .bash_profile (auto-start X, cursor VISIBLE)"
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
say "STEP 8/15  Writing .xinitrc (starts app service + gives root display access for RustDesk)"
cat > "${KIOSK_HOME}/.xinitrc" <<'EOF'
#!/bin/bash
# Tell apps this is an X11 session. Because we start X with startx (no display
# manager), XDG_SESSION_TYPE is otherwise empty and RustDesk reports
# "Unsupported display server tty, x11 expected". These exports fix that.
export XDG_SESSION_TYPE=x11
export XDG_SESSION_DESKTOP=openbox
export XDG_CURRENT_DESKTOP=openbox

# Make sure the boot splash is gone before X takes the framebuffer. Normally
# plymouth has already quit by multi-user.target, so this is a no-op — but if
# it were somehow still holding DRM master, X would fail to start and this
# kiosk would boot to nothing.
command -v plymouth >/dev/null && plymouth quit 2>/dev/null || true

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
say "STEP 9/15  Creating the app systemd USER service (UN-KILLABLE, auto-restart)"
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
say "STEP 10/15  Openbox config (F12 menu + app keybinds + protected Alt+F4)"
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
say "STEP 11/15  Menu scripts (F12 menu, password-gated Terminal, close-guard)"

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
say "STEP 12/15  GPIO: Super-I/O driver + /dev/gpiochip* permissions"

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
say "STEP 13/15  RustDesk background service (unkillable, auto-restart)"
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
say "STEP 14/15  Pre-creating writable app-config dirs, then LOCKING everything down"

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
say "STEP 15/15  Custom boot splash (logo from the app bundle)"

# The logo ships INSIDE the app bundle (cloned in STEP 5), so a new app release
# can re-brand the boot screen with no change to this script. If the file is
# missing, the splash is skipped — a missing logo must never fail the install.
SPLASH_SRC="${APP_DIR}/${SPLASH_LOGO}"

if [[ -z "$SPLASH_LOGO" ]]; then
    echo "SPLASH_LOGO is empty — boot splash deliberately disabled."
elif [[ ! -f "$SPLASH_SRC" ]]; then
    warn "No '${SPLASH_LOGO}' found in ${APP_DIR} — skipping the boot splash."
    warn "Add ${SPLASH_LOGO} to the app repo root, or set one later with:"
    warn "    sudo set-splash /path/to/logo.png"
elif [[ ! -d /usr/share/plymouth/themes/spinner ]]; then
    warn "plymouth's 'spinner' theme is missing — cannot build '${SPLASH_THEME}'."
    warn "Check that the plymouth package installed correctly in STEP 1."
else
    # ---- panel resolution -------------------------------------------------
    # Read the real framebuffer instead of assuming. systemd-stub CENTRES the
    # splash rather than scaling it, so a wrong size shows up small/off-centre.
    if [[ -r /sys/class/graphics/fb0/virtual_size ]]; then
        IFS=, read -r FB_W FB_H < /sys/class/graphics/fb0/virtual_size
    else
        FB_W=1024 FB_H=768
        warn "Could not read /sys/class/graphics/fb0/virtual_size — assuming ${FB_W}x${FB_H}"
    fi
    echo "Panel resolution .... ${FB_W}x${FB_H}"
    echo "Logo source ......... ${SPLASH_SRC}"

    # ---- theme ------------------------------------------------------------
    # Derived from 'spinner' so its keymap/lock/entry assets come along; only
    # the watermark is swapped. Rebuilt from scratch each run so a re-run can't
    # leave a half-edited theme behind.
    THEME_DIR="/usr/share/plymouth/themes/${SPLASH_THEME}"
    rm -rf "$THEME_DIR"
    cp -r /usr/share/plymouth/themes/spinner "$THEME_DIR"
    mv "${THEME_DIR}/spinner.plymouth" "${THEME_DIR}/${SPLASH_THEME}.plymouth"
    THEME_FILE="${THEME_DIR}/${SPLASH_THEME}.plymouth"
    sed -i "s/^Name=.*/Name=${SPLASH_THEME}/; s|spinner|${SPLASH_THEME}|g" "$THEME_FILE"

    # spinner pins the watermark to the bottom edge (.96) because it treats it
    # as a small distro badge. Centre it, and push the throbber down to .85 so
    # the two don't overlap.
    sed -i "s/^WatermarkVerticalAlignment=.*/WatermarkVerticalAlignment=.5/"   "$THEME_FILE"
    sed -i "s/^WatermarkHorizontalAlignment=.*/WatermarkHorizontalAlignment=.5/" "$THEME_FILE"
    sed -i "s/^VerticalAlignment=.7$/VerticalAlignment=.85/"                   "$THEME_FILE"

    # ---- images -----------------------------------------------------------
    # Alpha is flattened onto black EXPLICITLY: '-alpha remove' without a
    # stated -background picks white, which is what makes a transparent logo
    # come out wrong.
    magick "$SPLASH_SRC" -resize "${SPLASH_WIDTH}x" \
        -background black -alpha remove -alpha off -strip \
        "${THEME_DIR}/watermark.png" \
        || warn "watermark conversion failed — is ${SPLASH_LOGO} a valid image?"

    # systemd-stub's splash must be 24-bit BMP3. A 32-bit BMP or a PNG is
    # rejected, and it fails silently (no splash, no error message).
    magick -size "${FB_W}x${FB_H}" xc:black \
        \( "$SPLASH_SRC" -resize "${SPLASH_WIDTH}x" -background black -alpha remove -alpha off \) \
        -gravity center -composite \
        -alpha off -type TrueColor -define bmp:format=bmp3 \
        /boot/splash.bmp \
        || warn "stub splash conversion failed"

    # ---- loading indicator ------------------------------------------------
    # two-step can draw either a frame sequence (throbber-*.png, looped at
    # ~30fps) or a progress bar, or nothing at all.
    case "$SPLASH_STYLE" in
      cubes)
        echo "Indicator ........... spinner cubes (stock frames)"
        ;;

      bar)
        # No image files needed — two-step draws the bar itself. Geometry and
        # colour live in [two-step], but UseProgressBar is read PER BOOT MODE,
        # so it has to go under [boot-up] or it is silently ignored.
        rm -f "${THEME_DIR}"/animation-*.png "${THEME_DIR}"/throbber-*.png
        BAR_W=$(( FB_W / 3 ))
        BAR_FG="0x${SPLASH_ACCENT#\#}"
        sed -i "s/^ProgressBarForegroundColor=.*/ProgressBarForegroundColor=${BAR_FG}/" "$THEME_FILE"
        sed -i "s/^ProgressBarBackgroundColor=.*/ProgressBarBackgroundColor=0x303030/"  "$THEME_FILE"
        grep -q '^ProgressBarWidth=' "$THEME_FILE" || \
          sed -i "/^\[two-step\]/a ProgressBarWidth=${BAR_W}\nProgressBarHeight=4\nProgressBarHorizontalAlignment=.5\nProgressBarVerticalAlignment=.62" "$THEME_FILE"
        grep -q '^UseProgressBar=true' "$THEME_FILE" || \
          sed -i "/^\[boot-up\]/a UseProgressBar=true" "$THEME_FILE"
        echo "Indicator ........... progress bar (${BAR_W}x4, ${SPLASH_ACCENT})"
        ;;

      dots)
        # Three dots with the lit one cycling. 10 held frames per state gives a
        # ~1s loop at plymouth's ~30fps, which reads as a pulse rather than a
        # flicker. Fewer frames looks frantic.
        rm -f "${THEME_DIR}"/animation-*.png "${THEME_DIR}"/throbber-*.png
        DOTS=3; HOLD=10; FW=140; FH=28; SPACING=40; RADIUS=6
        frame=1
        for (( active=0; active<DOTS; active++ )); do
            # build one image, then copy it HOLD times — far cheaper than
            # invoking magick 30 separate times
            TMP_FRAME="$(mktemp --suffix=.png)"
            DRAW=()
            for (( d=0; d<DOTS; d++ )); do
                cx=$(( (FW - (DOTS-1)*SPACING)/2 + d*SPACING ))
                if (( d == active )); then
                    DRAW+=( -fill "$SPLASH_ACCENT" -draw "circle ${cx},$((FH/2)) $((cx+RADIUS)),$((FH/2))" )
                else
                    DRAW+=( -fill "#404040" -draw "circle ${cx},$((FH/2)) $((cx+RADIUS-2)),$((FH/2))" )
                fi
            done
            magick -size "${FW}x${FH}" xc:black "${DRAW[@]}" -alpha off "$TMP_FRAME" \
                || warn "dot frame generation failed"
            for (( h=0; h<HOLD; h++ )); do
                cp "$TMP_FRAME" "$(printf '%s/throbber-%04d.png' "$THEME_DIR" "$frame")"
                frame=$(( frame + 1 ))
            done
            rm -f "$TMP_FRAME"
        done
        echo "Indicator ........... $((frame-1)) generated dot frames (${SPLASH_ACCENT})"
        ;;

      none)
        rm -f "${THEME_DIR}"/animation-*.png "${THEME_DIR}"/throbber-*.png
        echo "Indicator ........... none (logo on black)"
        ;;

      *)
        warn "Unknown SPLASH_STYLE '${SPLASH_STYLE}' — keeping the stock cubes."
        ;;
    esac

    # ---- mkinitcpio hook --------------------------------------------------
    # Must sit immediately after udev (or after systemd, as sd-plymouth).
    # Guarded so a re-run can't insert it twice.
    if ! grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf; then
        if grep -q '^HOOKS=(base systemd ' /etc/mkinitcpio.conf; then
            sed -i 's/^HOOKS=(base systemd /HOOKS=(base systemd sd-plymouth /' /etc/mkinitcpio.conf
        else
            sed -i 's/^HOOKS=(base udev /HOOKS=(base udev plymouth /' /etc/mkinitcpio.conf
        fi
    fi
    grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf \
        || warn "Could not add the plymouth hook — fix HOOKS= in /etc/mkinitcpio.conf by hand"

    # ---- kernel cmdline ---------------------------------------------------
    # plymouthd exits immediately unless 'splash' is on the cmdline, and
    # 'quiet' is what stops kernel messages painting over the logo. WHERE this
    # belongs depends on how the box boots, so detect rather than guess.
    SPLASH_ARGS="quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 logo.nologo"

    if grep -qs '^default_uki=' /etc/mkinitcpio.d/linux.preset; then
        echo "Boot type ........... unified kernel image (cmdline baked in)"
        # seed from the running cmdline if the file doesn't exist yet
        [[ -f /etc/kernel/cmdline ]] || tr -d '\n' < /proc/cmdline > /etc/kernel/cmdline
        CMDLINE="$(tr -d '\n' < /etc/kernel/cmdline)"
        for arg in $SPLASH_ARGS; do
            grep -qw -- "${arg%%=*}" <<< "$CMDLINE" || CMDLINE="${CMDLINE} ${arg}"
        done
        printf '%s\n' "$CMDLINE" > /etc/kernel/cmdline
        chmod 644 /etc/kernel/cmdline

        # Point the UKI build at our splash. The preset ships a default_options
        # with --splash aimed at Arch's stock logo, so REPLACE it — a second
        # default_options line would just be overridden, since the preset is
        # sourced as a shell script and the last assignment wins.
        if grep -q '^default_options=' /etc/mkinitcpio.d/linux.preset; then
            sed -i 's|^default_options=.*|default_options="--splash /boot/splash.bmp"|' \
                /etc/mkinitcpio.d/linux.preset
        else
            echo 'default_options="--splash /boot/splash.bmp"' >> /etc/mkinitcpio.d/linux.preset
        fi
        echo "cmdline ............. $CMDLINE"

    elif [[ -f /etc/default/grub ]]; then
        echo "Boot type ........... GRUB + separate initramfs"
        for arg in $SPLASH_ARGS; do
            grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=.*${arg%%=*}" /etc/default/grub \
                || sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1 ${arg}\"|" \
                   /etc/default/grub
        done
        # hand the same framebuffer to the kernel so the image survives
        grep -q '^GRUB_GFXPAYLOAD_LINUX=' /etc/default/grub \
            || echo 'GRUB_GFXPAYLOAD_LINUX=keep' >> /etc/default/grub
        grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig failed"

    else
        warn "Found neither a UKI preset nor /etc/default/grub."
        warn "Add this to your bootloader's kernel line by hand:"
        warn "    ${SPLASH_ARGS}"
    fi

    # ---- activate ---------------------------------------------------------
    # -R rebuilds the initramfs/UKI, which is what actually ships the theme.
    # Editing /usr/share alone changes nothing at boot.
    plymouth-set-default-theme -R "$SPLASH_THEME" \
        || warn "plymouth-set-default-theme failed — the splash will not show"

    echo "Boot splash installed (theme '${SPLASH_THEME}', logo ${SPLASH_WIDTH}px wide)."
fi

# ============================================================================
say "Installing devctl (SCUBE internal support CLI)"
# devctl runs as root (admin's sudo), but everything it targets — the app's
# SQLite files, its IPC socket, its log directory — lives under $KIOSK_USER,
# a DIFFERENT account. None of that is auto-discoverable across the account
# boundary, so this wires up exactly what devctl/README.md's "app runs under
# its own account" section describes doing by hand, automatically, on every
# device provisioned from this script.
DEVCTL_SRC_BIN="${APP_DIR}/${DEVCTL_BINARY_REL}"
if [[ ! -x "$DEVCTL_SRC_BIN" ]]; then
    warn "devctl binary not found at $DEVCTL_SRC_BIN (check DEVCTL_BINARY_REL, and"
    warn "that modbus_linux_bundle actually includes it) — skipping devctl setup."
else
    install -m 0755 "$DEVCTL_SRC_BIN" /usr/local/bin/devctl
    echo "Installed /usr/local/bin/devctl."

    if [[ -z "$DEVCTL_AUTHORIZED_KEYS" ]]; then
        warn "DEVCTL_AUTHORIZED_KEYS is empty — devctl is installed but no SSH key can"
        warn "use it yet. Set it up by hand later per devctl/README.md, or add keys to"
        warn "this script and re-run (it only touches the auth file below, safe to redo)."
    else
        if ! grep -q '^ssh-' <<< "$DEVCTL_AUTHORIZED_KEYS"; then
            warn "DEVCTL_AUTHORIZED_KEYS doesn't look like it contains real 'ssh-...' public"
            warn "key lines — double-check it before relying on devctl access from this device."
        fi

        DEVCTL_SUPPORT_DIR="${KIOSK_HOME}/.local/share/com.scube.hybridcontroller"
        install -d -m 755 "$DEVCTL_SUPPORT_DIR"
        printf '%s\n' "$DEVCTL_AUTHORIZED_KEYS" > "${DEVCTL_SUPPORT_DIR}/devctl_authorized_keys"
        chmod 600 "${DEVCTL_SUPPORT_DIR}/devctl_authorized_keys"
        chown -R "${KIOSK_USER}:${KIOSK_USER}" "$DEVCTL_SUPPORT_DIR"

        # /etc/environment is read by PAM for essentially any login path,
        # sudo/sudo -i included — the same mechanism devctl/README.md uses.
        # XDG_RUNTIME_DIR=/run/user/<uid> is guaranteed to exist here (not
        # just on active login) because loginctl enable-linger already ran
        # for $KIOSK_USER in STEP 9. If a future systemd/distro change ever
        # makes this not match, `find /run/user -name solscada_ipc.sock`
        # finds the real path — see devctl/README.md's troubleshooting table.
        KIOSK_UID="$(id -u "$KIOSK_USER")"
        for line in \
            "SOLSCADA_SUPPORT_DIR=${DEVCTL_SUPPORT_DIR}" \
            "SOLSCADA_IPC_SOCK=/run/user/${KIOSK_UID}/solscada_ipc.sock" \
            "SOLSCADA_LOGS_DIR=${KIOSK_HOME}/Documents/ModbusLogs"
        do
            key="${line%%=*}"
            if grep -q "^${key}=" /etc/environment 2>/dev/null; then
                sed -i "s#^${key}=.*#${line}#" /etc/environment
            else
                echo "$line" >> /etc/environment
            fi
        done

        # Let admin's `sudo -E devctl ...` actually carry the forwarded SSH
        # agent + the 3 vars above through, permanently — same env_keep
        # pattern as the AUR build's TEMPORARY sudoers drop-in earlier in
        # this script, but this one stays.
        echo 'Defaults env_keep += "SSH_AUTH_SOCK SOLSCADA_SUPPORT_DIR SOLSCADA_IPC_SOCK SOLSCADA_LOGS_DIR"' \
            > /etc/sudoers.d/devctl-env
        chmod 440 /etc/sudoers.d/devctl-env
        visudo -cf /etc/sudoers.d/devctl-env >/dev/null || die "devctl sudoers rule invalid"

        KEY_COUNT=$(grep -c '^ssh-' <<< "$DEVCTL_AUTHORIZED_KEYS" || true)
        echo "devctl authorized for ${KEY_COUNT} key(s). Use it via: ssh -A ${ADMIN_USER}@<this-device>, then sudo -E devctl health"
    fi
fi

# ============================================================================
say "Installing the splash re-branding helper"
# Swap the boot logo later without re-running this whole script.
cat > /usr/local/bin/set-splash <<'EOF'
#!/usr/bin/env bash
# Swap this kiosk's boot logo (plymouth watermark + systemd-stub splash).
#   sudo set-splash [/path/to/logo.png] [width]
# With no arguments it re-reads the logo currently in the app bundle, which is
# what kiosk-update-app calls after a deploy. Rebuilds the initramfs/UKI, so it
# takes ~20s. Previous images are kept in /var/backups/splash.
set -euo pipefail

THEME="THEME_PLACEHOLDER"
DEFAULT_WIDTH="WIDTH_PLACEHOLDER"
APP_DIR="APPDIR_PLACEHOLDER"
SPLASH_LOGO="LOGO_PLACEHOLDER"

THEME_DIR="/usr/share/plymouth/themes/${THEME}"
BACKUP_DIR="/var/backups/splash"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "run as root: sudo set-splash [image] [width]"

SRC="${1:-${APP_DIR}/${SPLASH_LOGO}}"
WIDTH="${2:-$DEFAULT_WIDTH}"

[[ -f "$SRC" ]]            || die "no such file: $SRC"
[[ -d "$THEME_DIR" ]]      || die "theme dir missing: $THEME_DIR"
[[ "$WIDTH" =~ ^[0-9]+$ ]] || die "width must be a number, got: $WIDTH"
command -v magick >/dev/null || die "imagemagick not installed"
magick identify "$SRC" >/dev/null 2>&1 || die "not a readable image: $SRC"

if [[ -r /sys/class/graphics/fb0/virtual_size ]]; then
    IFS=, read -r FB_W FB_H < /sys/class/graphics/fb0/virtual_size
else
    FB_W=1024 FB_H=768
fi
info "screen ${FB_W}x${FB_H}, logo ${WIDTH}px wide, source $SRC"

mkdir -p "$BACKUP_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
[[ -f "$THEME_DIR/watermark.png" ]] && cp "$THEME_DIR/watermark.png" "$BACKUP_DIR/watermark-${STAMP}.png"
[[ -f /boot/splash.bmp ]]           && cp /boot/splash.bmp           "$BACKUP_DIR/splash-${STAMP}.bmp"
info "previous images backed up to $BACKUP_DIR"

magick "$SRC" -resize "${WIDTH}x" \
    -background black -alpha remove -alpha off -strip \
    "$THEME_DIR/watermark.png"

magick -size "${FB_W}x${FB_H}" xc:black \
    \( "$SRC" -resize "${WIDTH}x" -background black -alpha remove -alpha off \) \
    -gravity center -composite \
    -alpha off -type TrueColor -define bmp:format=bmp3 \
    /boot/splash.bmp

magick identify "$THEME_DIR/watermark.png" /boot/splash.bmp

info "rebuilding initramfs + UKI"
plymouth-set-default-theme -R "$THEME"
info "done — reboot to see it"
EOF
sed -i "s#THEME_PLACEHOLDER#${SPLASH_THEME}#"  /usr/local/bin/set-splash
sed -i "s#WIDTH_PLACEHOLDER#${SPLASH_WIDTH}#"  /usr/local/bin/set-splash
sed -i "s#APPDIR_PLACEHOLDER#${APP_DIR}#"      /usr/local/bin/set-splash
sed -i "s#LOGO_PLACEHOLDER#${SPLASH_LOGO}#"    /usr/local/bin/set-splash
chmod 755 /usr/local/bin/set-splash
chown root:root /usr/local/bin/set-splash

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
DEVCTL_BINARY_REL="DEVCTLBIN_PLACEHOLDER"
SPLASH_LOGO="LOGO_PLACEHOLDER"
BRANCH="${1:-BRANCH_PLACEHOLDER}"
COMMIT="${2:-}"

[[ -n "$APP_REPO" ]] || { echo "This kiosk was not deployed from git — nothing to update."; exit 1; }

# remember the old logo so the splash is only rebuilt when the new release
# actually changed it (the rebuild costs ~20s, so skip it when pointless)
OLD_LOGO_SUM=""
[[ -n "$SPLASH_LOGO" && -f "${APP_DIR}/${SPLASH_LOGO}" ]] \
  && OLD_LOGO_SUM=$(sha256sum "${APP_DIR}/${SPLASH_LOGO}" | cut -d' ' -f1)

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

# devctl ships in the same bundle, so a deploy can bring a new one. Refresh the
# installed copy; auth (keys, /etc/environment, sudoers) is untouched.
if [[ -n "$DEVCTL_BINARY_REL" && -x "${APP_DIR}/${DEVCTL_BINARY_REL}" ]]; then
    install -m 0755 "${APP_DIR}/${DEVCTL_BINARY_REL}" /usr/local/bin/devctl
    echo "==> refreshed /usr/local/bin/devctl from this release"
fi

echo "==> starting app"
su - "$KIOSK_USER" -c 'systemctl --user start kiosk-app.service' 2>/dev/null \
  || systemctl --user -M "${KIOSK_USER}@" start kiosk-app.service 2>/dev/null || true

# refresh the boot splash only if this release shipped a different logo
if [[ -n "$SPLASH_LOGO" && -f "${APP_DIR}/${SPLASH_LOGO}" ]] && command -v set-splash >/dev/null; then
    NEW_LOGO_SUM=$(sha256sum "${APP_DIR}/${SPLASH_LOGO}" | cut -d' ' -f1)
    if [[ "$NEW_LOGO_SUM" != "$OLD_LOGO_SUM" ]]; then
        echo "==> ${SPLASH_LOGO} changed in this release — refreshing the boot splash"
        set-splash "${APP_DIR}/${SPLASH_LOGO}" || echo "!!  splash refresh failed (the app itself is fine)"
    else
        echo "==> boot logo unchanged — splash left alone"
    fi
fi

echo "Updated to $BRANCH @ $REF.  Previous version kept at ${APP_DIR}.old"
EOF
sed -i "s#REPO_PLACEHOLDER#${APP_REPO}#"           /usr/local/bin/kiosk-update-app
sed -i "s#APPDIR_PLACEHOLDER#${APP_DIR}#"          /usr/local/bin/kiosk-update-app
sed -i "s#BINARY_PLACEHOLDER#${APP_BINARY}#"       /usr/local/bin/kiosk-update-app
sed -i "s#KIOSKUSER_PLACEHOLDER#${KIOSK_USER}#"    /usr/local/bin/kiosk-update-app
sed -i "s#DEVCTLBIN_PLACEHOLDER#${DEVCTL_BINARY_REL}#" /usr/local/bin/kiosk-update-app
sed -i "s#LOGO_PLACEHOLDER#${SPLASH_LOGO}#"        /usr/local/bin/kiosk-update-app
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
if [[ ! -x /usr/local/bin/devctl ]]; then
    DEVCTL_STATUS="not installed (binary missing from the bundle — see the devctl step's warning above)"
elif [[ -z "$DEVCTL_AUTHORIZED_KEYS" ]]; then
    DEVCTL_STATUS="installed, but NO key authorized yet — see devctl/README.md"
else
    DEVCTL_STATUS="installed, $(grep -c '^ssh-' <<< "$DEVCTL_AUTHORIZED_KEYS" || true) key(s) authorized"
fi
if [[ -z "$SPLASH_LOGO" ]]; then
    SPLASH_STATUS="disabled (SPLASH_LOGO empty)"
elif [[ -f "/usr/share/plymouth/themes/${SPLASH_THEME}/watermark.png" ]]; then
    SPLASH_STATUS="theme '${SPLASH_THEME}', ${SPLASH_WIDTH}px logo, '${SPLASH_STYLE}' indicator"
else
    SPLASH_STATUS="NOT installed — see the STEP 15 warning above"
fi
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
  Boot splash ......... ${SPLASH_STATUS}
                        logo read from ${APP_DIR}/${SPLASH_LOGO}
                        stub splash /boot/splash.bmp (systemd-stub draws it)
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
  set-splash .......... /usr/local/bin/set-splash        (change the boot logo)
  devctl .............. ${DEVCTL_STATUS}
                        use via: ssh -A ${ADMIN_USER}@<this-device>, then sudo -E devctl health

  NEXT:
    1) reboot
    2) after boot: Ctrl+Alt+R (RustDesk) -> set a PERMANENT unattended password
    3) test: F12 -> Restart App;  Alt+F4 on the app (should NOT close);
             Ctrl+Alt+T -> Admin User (should ask for password)
    4) RS485: Settings -> RS485 -> enter port/baud/parity for this device
    5) GPIO:  sudo kiosk-gpio-check     (every line should say OK)
              sudo -u ${KIOSK_USER} ngpio show    (must work WITHOUT sudo)
    6) splash: watch the boot — the logo should be centred on black. If it is
              missing:  journalctl -b -u plymouth-start.service
              With the 'bar' style the first boot has no timing baseline, so
              the bar only paces correctly from the SECOND boot onward.
    7) to STOP the app for maintenance: open a Terminal (password required),
       then:  systemctl --user stop kiosk-app.service
    8) to deploy a new branch later:  sudo kiosk-update-app <branch>
    9) devctl: ssh -A ${ADMIN_USER}@<device>, then sudo -E devctl health — should
       print "devctl: authenticated as ..." then real output. See
       devctl/README.md if it doesn't (SSH_AUTH_SOCK / no authorized key /
       daemon unreachable are all covered in its troubleshooting table).
   10) (optional hardening, do LAST) block TTY switching:
         create /etc/X11/xorg.conf.d/10-kiosk.conf with DontVTSwitch/DontZap

EOF
warn "The kiosk user's group memberships (uucp, ${GPIO_GROUP}) only reach the running"
warn "app after a full reboot — a systemd --user manager cannot change its own"
warn "supplementary groups. Reboot before testing serial or GPIO."
echo ""
read -p "  Reboot now? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] && reboot || echo "Reboot later with: sudo reboot"
