#!/bin/bash
###############################################################################
# setup-kiosk-cage.sh  —  Arch Linux + cage (Wayland) single-app kiosk
#
# Turns a FRESH Arch install into a locked-down kiosk running ONE Flutter app
# fullscreen, with no window manager, no menus and no keybinds.
#
# ---------------------------------------------------------------------------
# HOW THIS DIFFERS FROM THE X11 VERSION (setup-kiosk.sh)
#
# GONE, deliberately:
#   X.org, openbox, rofi, xterm, chromium, pcmanfm, unclutter, xdotool
#   F12 kiosk menu, Ctrl+Alt+C, Ctrl+Alt+T, the Alt+F4 close-guard
#   RustDesk
#
# WHY EACH IS UNNECESSARY UNDER CAGE:
#   - cage IS the session. It runs exactly one client fullscreen with no
#     decorations, no switching and no way out, so a window manager and a
#     close-guard have nothing to do. The app cannot be closed by the user.
#   - No pointer is drawn for touch input. wlroots moves the cursor only for
#     real pointer devices, so the whole CURSOR_MODE / -nocursor / unclutter
#     problem from the X11 version simply does not exist here.
#   - The menus existed to launch Chrome/RustDesk/a terminal. None ship now.
#
# WHAT YOU GIVE UP — READ THIS BEFORE DEPLOYING:
#   - There is NO on-panel escape hatch. No terminal, no menu, no keybind.
#     If SSH is down and the app is wedged, the only recovery is a power cycle
#     or physically attaching a keyboard and using a TTY (see TTY_SWITCH below).
#   - xdotool and every other X11 automation tool will not work on Wayland,
#     by design. If you later need on-screen automation, that is a hard stop.
#   - MemoryMax is no longer enforced. Under X11 the app ran as a systemd
#     --user service which could set it; here cage owns the app as its child.
#     LimitNOFILE is preserved via `ulimit -n` in the launcher. See STEP 5.
#
# THE ONE THING TO TEST FIRST:
#   Flutter's Linux embedder is GTK3, which supports Wayland — but that is a
#   general statement, not a verified fact about YOUR build. Before running
#   this on a provisioned device, log into a spare panel and run:
#
#       pacman -S cage
#       cage -- /opt/hybridController/modbus
#
#   If the app appears and touch works, proceed. If it fails, GTK may be
#   falling back or refusing; try `GDK_BACKEND=wayland cage -- <app>` and read
#   the error. If it will not run under Wayland at all, STOP and stay on the
#   X11 script — no amount of kiosk plumbing fixes an embedder that can't
#   start.
#
# ---------------------------------------------------------------------------
# ROLLBACK
#   This script does not uninstall the X11 stack; it just never installs it.
#   To go back, re-run the X11 setup-kiosk.sh — it rewrites .bash_profile and
#   reinstalls what it needs. Keep a copy of it alongside this one.
#
# ---------------------------------------------------------------------------
# PREREQUISITES
#   - Arch is installed and booted
#   - Internet works (ping archlinux.org)
#   - Your Flutter app is reachable as a git repo or a local folder
#
# RUN IT:
#   chmod +x setup-kiosk-cage.sh
#   sudo ./setup-kiosk-cage.sh
#   sudo APP_BRANCH=release-2.1 ./setup-kiosk-cage.sh    # pick a branch
#
# Idempotent-ish: safe to re-run if something fails midway.
#
# ---------------------------------------------------------------------------
# HARDWARE ACCESS GRANTED TO THE KIOSK USER:
#   RS485 / serial ... group 'uucp'  -> /dev/ttyS*, /dev/ttyUSB*, /dev/ttyACM*
#   Digital IO ....... group 'gpio'  -> /dev/gpiochip* (ITE IT8786 Super-I/O)
#   Seat / DRM / input ... via the logind session that autologin creates.
#     This is why the app still starts from a real tty login rather than a
#     lingering systemd --user service: cage needs a seat to take DRM master,
#     and only an actual session has one.
#
# ---------------------------------------------------------------------------
# devctl (remote support CLI) is installed the same way as in the X11 version.
# With RustDesk gone AND no on-panel terminal, SSH + devctl is now the ONLY
# way to administer a shipped device. Put at least one key in
# DEVCTL_AUTHORIZED_KEYS before this leaves the building.
###############################################################################

set -euo pipefail

##############################  CONFIG — EDIT ME  #############################
ADMIN_USER="admin"          # sudo user, created if missing
KIOSK_USER="kiosk"          # the locked-down user that runs cage

# Kiosk user's password. The kiosk auto-logs in so it is never typed at login,
# but polkit / su prompts can still ask for it.
#   Leave "" to be PROMPTED during setup (recommended).
KIOSK_PASSWORD=""

# ---- Where your Flutter app comes from -------------------------------------
APP_REPO="https://github.com/zVoid24/modbus_linux_bundle.git"
APP_BRANCH="${APP_BRANCH:-main}"
APP_COMMIT="${APP_COMMIT:-}"    # optional exact SHA; forces a full clone
APP_SRC=""                      # local folder instead of git; leave APP_REPO="" to use
APP_BINARY="modbus"
APP_DIR="/opt/hybridController"

# ---- Session ---------------------------------------------------------------
# Extra environment for the app. GDK_BACKEND is left UNSET on purpose so GTK
# autodetects; forcing it hides useful errors during the first bring-up. Set
# it here only if you have a reason.
# Leave this EMPTY unless you have a specific reason. In particular do not add
# GDK_BACKEND=wayland: Flutter's GTK embedder goes through Xwayland (see the
# STEP 1 comment), so forcing the Wayland backend fights the path that actually
# works. Verified on hardware — with xorg-xwayland installed and GDK_BACKEND
# unset, the app starts clean; the variable was a red herring while Xwayland
# was the real missing piece.
#   e.g. APP_ENV=( "FLUTTER_ENGINE_SWITCH=..." )
APP_ENV=()

# Allow Ctrl+Alt+F<n> VT switching out of the kiosk?
#   "no"  — locked down. The panel cannot be escaped without SSH or a reboot.
#   "yes" — a physically attached keyboard can reach tty2..tty6 for recovery.
# Passed to cage as -s. On a device you can physically reach, "yes" is the
# difference between a 30-second fix and a truck roll.
TTY_SWITCH="yes"

# Soft fd limit for the app. Under X11 this was LimitNOFILE in a systemd unit;
# here it is applied with `ulimit -n` in the launcher, which cage inherits.
# A slow fd leak previously exhausted the default 1024 within ~8h of 24/7 use.
APP_NOFILE="524288"

# ---- GPIO (digital IO) ------------------------------------------------------
GPIO_MODULE="gpio-it87"     # ITE IT8786 Super-I/O; "" to skip
GPIO_GROUP="gpio"           # Arch has no 'gpio' group, so this creates it

# ---- Boot splash -----------------------------------------------------------
# Logo is read from the app bundle, so an app release can re-brand the boot
# screen with no change to this script. "" disables the splash.
SPLASH_LOGO="logo.png"
SPLASH_THEME="mylogo"
SPLASH_WIDTH="400"
# spinfinity | cubes | bar | dots | none
SPLASH_STYLE="spinfinity"
SPLASH_INDICATOR_POS=""     # e.g. ".65"; "" uses the style default
SPLASH_ACCENT="#00a3e0"     # only used by bar / dots

# ---- devctl ----------------------------------------------------------------
DEVCTL_BINARY_REL="devctl-linux-amd64"
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
[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo ./setup-kiosk-cage.sh"
ping -c1 -W3 archlinux.org &>/dev/null || die "No internet. Connect first (nmcli / systemctl start NetworkManager)."
case "$TTY_SWITCH" in yes|no) ;; *) die "TTY_SWITCH must be yes or no — got '$TTY_SWITCH'" ;; esac
[[ "$APP_NOFILE" =~ ^[0-9]+$ ]] || die "APP_NOFILE must be a number"

KIOSK_HOME="/home/${KIOSK_USER}"

# ============================================================================
say "STEP 0/8  Ensuring admin user '$ADMIN_USER' exists with sudo"
pacman -S --needed --noconfirm sudo
if ! grep -q '^%wheel ALL=(ALL:ALL) ALL' /etc/sudoers 2>/dev/null; then
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers.d/10-wheel >/dev/null || die "wheel sudoers rule invalid"
fi

if ! id "$ADMIN_USER" &>/dev/null; then
    warn "Admin user '$ADMIN_USER' does not exist — creating it now."
    useradd -m -G wheel -s /bin/bash "$ADMIN_USER"
    echo ""
    echo "  Set a password for '$ADMIN_USER'. With no on-panel terminal, SSH as"
    echo "  this user is your only way into a shipped device — do not skip it."
    pw_ok=0
    for _try in 1 2 3; do
        if passwd "$ADMIN_USER"; then pw_ok=1; break; fi
        warn "passwd failed (attempt $_try/3)."
    done
    if [[ $pw_ok -ne 1 ]]; then
        echo ""
        warn "Could not set the admin password. Open another TTY, run:"
        warn "    passwd $ADMIN_USER"
        warn "then re-run this script (it will skip creation)."
        die "Stopping so you can set the password manually."
    fi
else
    echo "Admin user '$ADMIN_USER' already exists."
    usermod -aG wheel "$ADMIN_USER"
    if ! passwd -S "$ADMIN_USER" 2>/dev/null | grep -qE ' (P|PS) '; then
        warn "Admin '$ADMIN_USER' has no password set. Set one now:"
        passwd "$ADMIN_USER" || warn "Still not set — fix with: passwd $ADMIN_USER"
    fi
fi

# ============================================================================
say "STEP 1/8  Installing packages"
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
    cage xorg-xwayland \
    gtk3 \
    git base-devel \
    libgpiod udisks2 ntfs-3g \
    plymouth imagemagick \
    libinput ttf-dejavu xorg-xcursorgen
# cage pulls wlroots, libseat and the Wayland stack as dependencies. There is
# no X SESSION, no window manager and no AUR helper here — every package is in
# the official repos, so this script never grants NOPASSWD sudo, not even
# temporarily.
#
# gtk3 and xorg-xwayland are BOTH hard requirements, verified the hard way on
# real hardware. Neither is obvious:
#
#   gtk3 — Flutter's Linux embedder links libgtk-3.so.0, libgdk-3.so.0,
#     libatk-1.0.so.0, libgdk_pixbuf-2.0.so.0 and libepoxy.so.0. In the older
#     X11 build these arrived free as dependencies of chromium, rofi and
#     pcmanfm. Dropping those three took gtk3 with them and the app died with
#     "error while loading shared libraries: libgtk-3.so.0". Nothing in the
#     Wayland stack pulls gtk3, so it has to be named explicitly.
#
#   xorg-xwayland — this is NOT the cosmetic "Cannot find Xwayland binary"
#     warning it looks like in cage's log. Flutter's GTK embedder goes through
#     GTK's X11 backend, so with no Xwayland it fails with
#     "Gtk-WARNING: cannot open display:" and exits, leaving a black screen in
#     a 2-second restart loop. Xwayland runs INSIDE cage as a nested X server
#     for that one client — it is not an X session, so the kiosk model is
#     intact. Do not remove it to "clean up" the log.
#
#   Do NOT set GDK_BACKEND=wayland to try to fix the above. GTK is legitimately
#     using the X11 path via Xwayland; forcing the Wayland backend contradicts
#     that. Tested: with Xwayland installed and GDK_BACKEND unset, the app
#     starts clean. See APP_ENV in the config block.
#
# libinput replaces xorg-xinput for touchscreen diagnostics: `libinput
# debug-events` reads evdev directly and so works with no display server at
# all, which matters because there is no `xinput test-xi2` under Wayland.
# libgpiod is for gpiodetect/gpioinfo when debugging dead digital IO — the app
# itself talks to the chardev ioctl ABI directly. udisks2 provides udisksctl,
# which usb_drive_service.dart shells out to for mounting USB sticks; there is
# no desktop shell here to auto-mount them. ntfs-3g must be preferred over the
# in-kernel ntfs3 driver — see mount_options.conf below. ttf-dejavu is kept
# because the Flutter app may fall back to a system font.

systemctl enable --now udisks2

# A USB stick yanked mid-export (no eject button on a kiosk) leaves NTFS's
# dirty bit set. udisks2 prefers the in-kernel ntfs3 driver when available, and
# ntfs3 refuses to mount a dirty volume without `force` — which is not a
# recognised option in udisks2's ntfs3 mount-option table, so it is rejected
# with OptionNotPermitted no matter what mount_options.conf allows. There is no
# way to pass it through udisksctl. ntfs-3g (FUSE) auto-recovers a dirty volume
# with no extra options, so reordering ntfs_drivers to prefer it fixes this
# outright — verified by hand on real hardware.
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
# udisks2 reads this only at daemon start, not on file change.
systemctl restart udisks2

command -v cage >/dev/null || die "cage did not install — cannot continue."
echo "cage ................ $(cage --version 2>&1 | head -1 || echo 'installed')"

# ============================================================================
say "STEP 2/8  Creating locked-down kiosk user"
if ! id "$KIOSK_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$KIOSK_USER"
    echo "Created '$KIOSK_USER' (NOT in wheel -> no sudo)."
fi
gpasswd -d "$KIOSK_USER" wheel 2>/dev/null || true

# Arch puts real serial ports and most USB-serial adapters in group 'uucp'
# (Debian uses 'dialout'; uucp is correct here). Without it, reading any Modbus
# RTU meter fails with "no permission to access it".
usermod -aG uucp "$KIOSK_USER"
echo "Added '$KIOSK_USER' to 'uucp' (serial / RS485)."

# The app opens /dev/gpiochip0 through the GPIO chardev ioctl ABI. Arch ships
# no 'gpio' group, so create it; the udev rule in STEP 6 hands the node to it.
# Without this, open() returns EACCES and every digital IO silently fails —
# and the kiosk user has no sudo to work around it at runtime.
groupadd -f "$GPIO_GROUP"
usermod -aG "$GPIO_GROUP" "$KIOSK_USER"
echo "Added '$KIOSK_USER' to '$GPIO_GROUP' (/dev/gpiochip*)."

# GROUP TIMING: a process inherits its supplementary groups from the PAM
# session that spawned it and can never change them afterwards. Both usermod
# calls happen before the final reboot, so cage and the app pick them up. If
# you add a group later, a re-login is NOT enough — run
# 'loginctl terminate-user kiosk' or reboot.

if [[ -n "$KIOSK_PASSWORD" ]]; then
    echo "${KIOSK_USER}:${KIOSK_PASSWORD}" | chpasswd
    echo "Kiosk password set from config."
elif [[ -t 0 ]]; then
    echo ""
    echo "  Set a password for the kiosk user:"
    passwd "$KIOSK_USER" || warn "Not set — fix with: sudo passwd $KIOSK_USER"
else
    echo "${KIOSK_USER}:kiosk" | chpasswd
    warn "Non-interactive and no KIOSK_PASSWORD — defaulted to 'kiosk'. CHANGE IT."
fi

# ============================================================================
say "STEP 3/8  Deploying the Flutter app to $APP_DIR"
mkdir -p "$APP_DIR"
if [[ -n "$APP_REPO" ]]; then
    TMP_CLONE="$(mktemp -d)"
    echo "Repo ...... $APP_REPO"
    echo "Branch .... ${APP_BRANCH:-<repo default>}"
    [[ -n "$APP_COMMIT" ]] && echo "Commit .... $APP_COMMIT"

    if [[ -n "$APP_COMMIT" ]]; then
        # a full clone is needed for an arbitrary SHA to be reachable
        if [[ -n "$APP_BRANCH" ]]; then
            git clone --branch "$APP_BRANCH" "$APP_REPO" "$TMP_CLONE" \
                || die "git clone failed (branch '$APP_BRANCH' — does it exist?)"
        else
            git clone "$APP_REPO" "$TMP_CLONE" || die "git clone failed: $APP_REPO"
        fi
        git -C "$TMP_CLONE" checkout --detach "$APP_COMMIT" \
            || die "commit '$APP_COMMIT' not found in $APP_REPO"
    elif [[ -n "$APP_BRANCH" ]]; then
        git clone --depth 1 --single-branch --branch "$APP_BRANCH" "$APP_REPO" "$TMP_CLONE" \
            || die "git clone failed (branch/tag '$APP_BRANCH' — does it exist?)"
    else
        git clone --depth 1 "$APP_REPO" "$TMP_CLONE" || die "git clone failed: $APP_REPO"
    fi

    DEPLOYED_REF="$(git -C "$TMP_CLONE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    (shopt -s dotglob; cp -r "$TMP_CLONE"/* "$APP_DIR"/ 2>/dev/null || true)
    rm -rf "$APP_DIR/.git" "$TMP_CLONE"

    {
        echo "repo=$APP_REPO"
        echo "branch=${APP_BRANCH:-<default>}"
        echo "commit=$DEPLOYED_REF"
        echo "deployed=$(date -Is)"
    } > "${APP_DIR}/.deployed-version"
    chmod 644 "${APP_DIR}/.deployed-version"
    echo "Deployed branch '${APP_BRANCH:-<default>}' @ $DEPLOYED_REF."
elif [[ -n "$APP_SRC" ]]; then
    [[ -d "$APP_SRC" ]] || die "APP_SRC '$APP_SRC' not found."
    cp -r "${APP_SRC}/." "$APP_DIR/"
    echo "Copied app from $APP_SRC"
else
    warn "APP_REPO and APP_SRC both empty — assuming the app is already in $APP_DIR."
fi
chown -R root:root "$APP_DIR"
chmod -R 755 "$APP_DIR"
chmod +x "${APP_DIR}/${APP_BINARY}" 2>/dev/null || true
[[ -x "${APP_DIR}/${APP_BINARY}" ]] \
    || die "Binary ${APP_DIR}/${APP_BINARY} missing or not executable — check APP_BINARY. cage has nothing to run without it."

# ============================================================================
say "STEP 4/8  Configuring autologin on tty1"
# cage needs a seat to take DRM master and open input devices, and only a real
# logind session has one. That is why this still goes through agetty rather
# than a lingering systemd --user unit.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
EOF

# ============================================================================
say "STEP 5/8  Building the blank cursor theme, then writing the cage launcher"

# ---- blank cursor theme ---------------------------------------------------
# cage draws the pointer itself, through wlroots' xcursor manager. It has no
# cursor flag (`cage --help`), WLR_XWAYLAND_ARGS is not honoured by this
# wlroots version, and unclutter can only poll on whole-second granularity — so
# every tap flashed the pointer for ~1s. All three were tried on hardware and
# rejected. Giving the compositor a theme whose every cursor is a 1x1
# transparent pixel works at the layer that actually renders, so there is
# nothing to poll and nothing to race.
BLANK_THEME_DIR="/usr/share/icons/blank"
BLANK_TMP="$(mktemp -d)"
# PNG32: is required. Without it ImageMagick optimises a single transparent
# pixel down to 1-bit grayscale, and xcursorgen needs 8-bit ARGB — verified:
# plain `xc:transparent` yields "Gray depth=1", PNG32: yields "sRGB depth=8".
magick -size 1x1 xc:transparent PNG32:"${BLANK_TMP}/blank.png"
printf '24 0 0 %s/blank.png\n' "$BLANK_TMP" > "${BLANK_TMP}/blank.cursor"
if xcursorgen "${BLANK_TMP}/blank.cursor" "${BLANK_TMP}/blank_cursor" 2>/dev/null; then
    install -Dm644 "${BLANK_TMP}/blank_cursor" "${BLANK_THEME_DIR}/cursors/left_ptr"

    # Symlink EVERY cursor name any installed theme knows about — not a
    # hand-picked list. A name that is missing here falls back to Adwaita
    # (pulled in by gtk3) and a visible pointer reappears.
    mapfile -t CURSOR_NAMES < <(
        find /usr/share/icons -path '*/cursors/*' -printf '%f\n' 2>/dev/null | sort -u
    )
    for n in "${CURSOR_NAMES[@]}"; do
        [[ "$n" == "left_ptr" ]] && continue
        ln -sf left_ptr "${BLANK_THEME_DIR}/cursors/${n}"
    done

    cat > "${BLANK_THEME_DIR}/index.theme" <<'EOF'
[Icon Theme]
Name=blank
Comment=Fully transparent cursors for a touch-only kiosk
EOF
    echo "Cursor theme ........ blank ($(ls "${BLANK_THEME_DIR}/cursors" | wc -l) names)"
else
    warn "xcursorgen failed — the pointer will be visible."
    warn "Not fatal; the app still runs. Check that xorg-xcursorgen installed."
fi
rm -rf "$BLANK_TMP"

# NOTE: this hides the pointer that CAGE draws, which covers the touch-only
# case — i.e. every shipped panel. Plugging in a real USB mouse can still make
# the app set its own cursor on its surface, which persists after unplugging.
# That is app-side, not fixable from here: wrap the Flutter root widget in
#     MouseRegion(cursor: SystemMouseCursors.none, child: ...)
# Verified on hardware: with no mouse attached there is no cursor at all.


# -s allows Ctrl+Alt+F<n> VT switching; omitted, cage holds the VT.
# -d suppresses client-side decorations. Without it GTK draws its own header
# bar, because there is no window manager here to strip it the way openbox's
# <decor>no</decor> did in the X11 build.
# -s allows Ctrl+Alt+F<n> VT switching; omitted, cage holds the VT.
CAGE_ARGS="-d"
[[ "$TTY_SWITCH" == "yes" ]] && CAGE_ARGS="-s -d"

# Build the env exports, if any were configured.
ENV_LINES=""
for e in "${APP_ENV[@]+"${APP_ENV[@]}"}"; do
    ENV_LINES+="export ${e}"$'\n'
done

# Unquoted heredoc so the vars above expand; every other $ is escaped as \$.
cat > "${KIOSK_HOME}/.bash_profile" <<EOF
[[ -f ~/.bashrc ]] && . ~/.bashrc

# Only ever start the session on tty1, and only if one isn't already running.
if [[ -z \${WAYLAND_DISPLAY:-} ]] && [[ \$(tty) == /dev/tty1 ]]; then

  # cage refuses to start without this ("XDG_RUNTIME_DIR is not set in the
  # environment"). A normal password login gets it from pam_systemd, but
  # 'agetty --autologin' does not reliably export it into the shell, so set it
  # explicitly. The directory itself is created by logind for the session.
  export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"

  # Point wlroots at the transparent theme built above. These MUST be set
  # before cage starts — setting them inside a wrapper is too late, because
  # cage reads them when it initialises its cursor manager.
  # XCURSOR_PATH is pinned so a missing name cannot fall back to Adwaita.
  export XCURSOR_THEME=blank
  export XCURSOR_PATH=/usr/share/icons

  # Raise the fd ceiling before cage starts; the app inherits it. This replaces
  # the LimitNOFILE= that the X11 version set in a systemd unit.
  ulimit -n ${APP_NOFILE} 2>/dev/null || true

${ENV_LINES}
  # Restart forever. cage exits when its child exits, so this one loop covers
  # both a crashed compositor and a crashed app. sleep 2 stops a hard crash
  # loop from pinning the CPU.
  while true; do
    # The boot splash may still hold DRM master; cage cannot start until it
    # lets go. Harmless no-op once plymouth has already quit.
    command -v plymouth >/dev/null && plymouth quit 2>/dev/null || true

    cage ${CAGE_ARGS} -- ${APP_DIR}/${APP_BINARY} >> ~/.cage.log 2>&1
    sleep 2
  done
fi
EOF
echo "launcher ............ cage ${CAGE_ARGS} -- ${APP_DIR}/${APP_BINARY}"
echo "VT switching ........ ${TTY_SWITCH}"
echo "fd limit ............ ${APP_NOFILE}"
echo "app log ............. ${KIOSK_HOME}/.cage.log"

# Logging to a file matters more here than under X11: with no terminal on the
# panel, ~/.cage.log is the only place a startup failure will show up. Rotate
# it so a crash loop cannot fill the disk.
cat > /etc/logrotate.d/kiosk-cage <<EOF
${KIOSK_HOME}/.cage.log {
    size 10M
    rotate 3
    compress
    missingok
    notifempty
    copytruncate
}
EOF
chmod 644 /etc/logrotate.d/kiosk-cage

# ============================================================================
say "STEP 6/8  GPIO: Super-I/O driver + /dev/gpiochip* permissions"
if [[ -n "$GPIO_MODULE" ]]; then
    echo "$GPIO_MODULE" > "/etc/modules-load.d/${GPIO_MODULE}.conf"
    chmod 644 "/etc/modules-load.d/${GPIO_MODULE}.conf"
    if modprobe "$GPIO_MODULE" 2>/dev/null; then
        echo "Loaded '$GPIO_MODULE' (and set it to load at boot)."
    else
        warn "modprobe $GPIO_MODULE failed."
        warn "Most common cause: ACPI already claimed the Super-I/O ports."
        warn "Check:  dmesg | grep -iE 'it87|resource'"
        warn "Fix: add  acpi_enforce_resources=lax  to the kernel cmdline, reboot."
        warn "Unrecognised chip ID: modprobe $GPIO_MODULE force_id=0x8786"
    fi
fi

cat > /etc/udev/rules.d/99-gpio.rules <<EOF
# Hand the GPIO character device to group '${GPIO_GROUP}' so the kiosk user can
# open it without sudo. Terminals 1-8 on this board are gpiochip0 lines 48-55.
SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="${GPIO_GROUP}", MODE="0660"
EOF
chmod 644 /etc/udev/rules.d/99-gpio.rules
udevadm control --reload
udevadm trigger --subsystem-match=gpio || true

if compgen -G "/dev/gpiochip*" >/dev/null; then
    ls -l /dev/gpiochip*
    gpiodetect 2>/dev/null || true
    if sudo -u "$KIOSK_USER" test -r /dev/gpiochip0 && sudo -u "$KIOSK_USER" test -w /dev/gpiochip0; then
        echo "'$KIOSK_USER' can read+write /dev/gpiochip0. Good."
    else
        warn "'$KIOSK_USER' cannot access /dev/gpiochip0 yet — usually just group"
        warn "caching; it will be correct after the reboot."
    fi
else
    warn "No /dev/gpiochip* on this board — digital IO will NOT work."
    warn "The udev rule is installed and applies as soon as a chip appears."
    warn "Debug: dmesg | grep -i it87  /  modinfo $GPIO_MODULE  /  gpiodetect"
fi

# ============================================================================
say "STEP 7/8  Locking down the kiosk home directory"

# There is no Chromium or pcmanfm here, so the writable-sandbox dance the X11
# version needed is gone. The app's own state dirs are all this needs.
mkdir -p "${KIOSK_HOME}/.config" "${KIOSK_HOME}/.cache" "${KIOSK_HOME}/.local/share"
chown "${KIOSK_USER}:${KIOSK_USER}" \
    "${KIOSK_HOME}/.config" "${KIOSK_HOME}/.cache" "${KIOSK_HOME}/.local" "${KIOSK_HOME}/.local/share"
chmod 755 "${KIOSK_HOME}/.config" "${KIOSK_HOME}/.cache" "${KIOSK_HOME}/.local/share"

# The launcher must not be editable by the user it launches.
chown root:root "${KIOSK_HOME}/.bash_profile"
chmod 644       "${KIOSK_HOME}/.bash_profile"

# ...but the log it writes to has to stay writable by the kiosk user.
touch "${KIOSK_HOME}/.cage.log"
chown "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.cage.log"
chmod 644 "${KIOSK_HOME}/.cage.log"
echo "Launcher root-owned; ~/.cage.log writable by ${KIOSK_USER}."

# ============================================================================
say "STEP 8/8  Custom boot splash (logo from the app bundle)"
SPLASH_SRC="${APP_DIR}/${SPLASH_LOGO}"

if [[ -z "$SPLASH_LOGO" ]]; then
    echo "SPLASH_LOGO empty — boot splash deliberately disabled."
elif [[ ! -f "$SPLASH_SRC" ]]; then
    warn "No '${SPLASH_LOGO}' in ${APP_DIR} — skipping the boot splash."
    warn "Add it to the app repo root, or run:  sudo set-splash /path/to/logo.png"
elif [[ ! -d /usr/share/plymouth/themes/spinner ]]; then
    warn "plymouth's 'spinner' theme is missing — cannot build '${SPLASH_THEME}'."
else
    # Read the real framebuffer. systemd-stub CENTRES its splash rather than
    # scaling it, so a wrong size renders small or off-centre.
    if [[ -r /sys/class/graphics/fb0/virtual_size ]]; then
        IFS=, read -r FB_W FB_H < /sys/class/graphics/fb0/virtual_size
    else
        FB_W=1024 FB_H=768
        warn "Could not read fb0/virtual_size — assuming ${FB_W}x${FB_H}"
    fi
    echo "Panel resolution .... ${FB_W}x${FB_H}"

    # Derived from spinner so its keymap/lock/entry assets come along. Rebuilt
    # from scratch each run, so hand edits under /usr/share do NOT survive.
    THEME_DIR="/usr/share/plymouth/themes/${SPLASH_THEME}"
    rm -rf "$THEME_DIR"
    cp -r /usr/share/plymouth/themes/spinner "$THEME_DIR"
    mv "${THEME_DIR}/spinner.plymouth" "${THEME_DIR}/${SPLASH_THEME}.plymouth"
    THEME_FILE="${THEME_DIR}/${SPLASH_THEME}.plymouth"
    sed -i "s/^Name=.*/Name=${SPLASH_THEME}/; s|spinner|${SPLASH_THEME}|g" "$THEME_FILE"

    # spinner pins the watermark to the bottom edge (.96) as a distro badge.
    # Centre it; each style then sets its own VerticalAlignment below.
    sed -i "s/^WatermarkVerticalAlignment=.*/WatermarkVerticalAlignment=.5/"     "$THEME_FILE"
    sed -i "s/^WatermarkHorizontalAlignment=.*/WatermarkHorizontalAlignment=.5/" "$THEME_FILE"
    sed -i "s/^HorizontalAlignment=.*/HorizontalAlignment=.5/"                   "$THEME_FILE"

    # Alpha is flattened onto black EXPLICITLY: '-alpha remove' with no stated
    # -background picks white, which is what makes a transparent logo look wrong.
    magick "$SPLASH_SRC" -resize "${SPLASH_WIDTH}x" \
        -background black -alpha remove -alpha off -strip \
        "${THEME_DIR}/watermark.png" \
        || warn "watermark conversion failed — is ${SPLASH_LOGO} a valid image?"

    # systemd-stub's splash must be 24-bit BMP3. 32-bit or PNG is rejected, and
    # it fails silently — no splash, no error.
    magick -size "${FB_W}x${FB_H}" xc:black \
        \( "$SPLASH_SRC" -resize "${SPLASH_WIDTH}x" -background black -alpha remove -alpha off \) \
        -gravity center -composite \
        -alpha off -type TrueColor -define bmp:format=bmp3 \
        /boot/splash.bmp \
        || warn "stub splash conversion failed"

    # two-step draws the progress animation (progress-*.png), the throbber
    # (throbber-*.png) and the drawn bar INDEPENDENTLY — more than one present
    # means more than one indicator on screen. Globs are un-hyphenated because
    # spinfinity ships two-digit names (throbber-18.png) while generated frames
    # use four; plymouth sorts lexically, so a leftover set interleaves and the
    # two indicators alternate.
    clear_indicators() {
        rm -f "${THEME_DIR}"/throbber*.png \
              "${THEME_DIR}"/progress*.png \
              "${THEME_DIR}"/animation*.png
    }
    set_indicator_pos() {
        local pos="${SPLASH_INDICATOR_POS:-$1}"
        sed -i "s/^VerticalAlignment=.*/VerticalAlignment=${pos}/" "$THEME_FILE"
        echo "Indicator position .. ${pos}"
    }

    case "$SPLASH_STYLE" in
      spinfinity)
        clear_indicators
        if [[ -d /usr/share/plymouth/themes/spinfinity ]] \
           && compgen -G "/usr/share/plymouth/themes/spinfinity/throbber-*.png" >/dev/null; then
            cp /usr/share/plymouth/themes/spinfinity/throbber-*.png "$THEME_DIR"/
            chmod 644 "${THEME_DIR}"/throbber-*.png
            set_indicator_pos ".6"
            echo "Indicator ........... spinfinity loop ($(ls "${THEME_DIR}"/throbber-*.png | wc -l) frames)"
        else
            warn "spinfinity theme not installed — no indicator will show."
        fi
        ;;
      cubes)
        set_indicator_pos ".7"
        echo "Indicator ........... spinner stock throbber"
        ;;
      bar)
        clear_indicators
        BAR_W=$(( FB_W / 3 ))
        BAR_FG="0x${SPLASH_ACCENT#\#}"
        sed -i "s/^ProgressBarForegroundColor=.*/ProgressBarForegroundColor=${BAR_FG}/" "$THEME_FILE"
        sed -i "s/^ProgressBarBackgroundColor=.*/ProgressBarBackgroundColor=0x303030/"  "$THEME_FILE"
        grep -q '^ProgressBarWidth=' "$THEME_FILE" || \
          sed -i "/^\[two-step\]/a ProgressBarWidth=${BAR_W}\nProgressBarHeight=4\nProgressBarHorizontalAlignment=.5\nProgressBarVerticalAlignment=${SPLASH_INDICATOR_POS:-.62}" "$THEME_FILE"
        # UseProgressBar is read PER BOOT MODE, so it must go under [boot-up].
        grep -q '^UseProgressBar=true' "$THEME_FILE" || \
          sed -i "/^\[boot-up\]/a UseProgressBar=true" "$THEME_FILE"
        echo "Indicator ........... progress bar (${BAR_W}x4, ${SPLASH_ACCENT})"
        ;;
      dots)
        clear_indicators
        DOTS=3; HOLD=10; DFW=140; DFH=28; SPACING=40; RADIUS=6
        frame=1
        for (( active=0; active<DOTS; active++ )); do
            TMP_FRAME="$(mktemp --suffix=.png)"
            DRAW=()
            for (( d=0; d<DOTS; d++ )); do
                cx=$(( (DFW - (DOTS-1)*SPACING)/2 + d*SPACING ))
                if (( d == active )); then
                    DRAW+=( -fill "$SPLASH_ACCENT" -draw "circle ${cx},$((DFH/2)) $((cx+RADIUS)),$((DFH/2))" )
                else
                    DRAW+=( -fill "#404040" -draw "circle ${cx},$((DFH/2)) $((cx+RADIUS-2)),$((DFH/2))" )
                fi
            done
            magick -size "${DFW}x${DFH}" xc:black "${DRAW[@]}" -alpha off "$TMP_FRAME" \
                || warn "dot frame generation failed"
            # 10 held frames per state = ~1s loop at plymouth's ~30fps, which
            # reads as a pulse rather than a flicker.
            for (( h=0; h<HOLD; h++ )); do
                cp "$TMP_FRAME" "$(printf '%s/throbber-%04d.png' "$THEME_DIR" "$frame")"
                frame=$(( frame + 1 ))
            done
            rm -f "$TMP_FRAME"
        done
        chmod 644 "${THEME_DIR}"/throbber-*.png
        set_indicator_pos ".7"
        echo "Indicator ........... $((frame-1)) generated dot frames"
        ;;
      none)
        clear_indicators
        echo "Indicator ........... none (logo on black)"
        ;;
      *)
        warn "Unknown SPLASH_STYLE '${SPLASH_STYLE}' — keeping spinner's throbber."
        warn "Valid: spinfinity cubes bar dots none"
        set_indicator_pos ".7"
        ;;
    esac

    SPLASH_THEME_BUILT=1
fi   # <- end of the splash-image conditional

# ============================================================================
# Bootloader and initramfs config — deliberately OUTSIDE the conditional above.
#
# This USED to be nested inside it, which was a bug: if logo.png was missing
# from the app bundle, STEP 8 bailed out early and the GRUB menu was never
# hidden. Hiding the boot menu has nothing to do with whether a logo exists, so
# it must not be gated behind one. Found the hard way on a provisioned panel
# that kept showing the GRUB menu after a clean reset + re-provision.
say "STEP 8/8 (cont.)  Bootloader and initramfs"

# The plymouth hook is only useful if plymouth will actually draw something,
# but it is harmless otherwise and the boot args below reference it, so add it
# whenever plymouth is installed at all.
if command -v plymouthd >/dev/null; then
    if ! grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf; then
        if grep -q '^HOOKS=(base systemd ' /etc/mkinitcpio.conf; then
            sed -i 's/^HOOKS=(base systemd /HOOKS=(base systemd sd-plymouth /' /etc/mkinitcpio.conf
        else
            sed -i 's/^HOOKS=(base udev /HOOKS=(base udev plymouth /' /etc/mkinitcpio.conf
        fi
    fi
    grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf \
        || warn "Could not add the plymouth hook — fix HOOKS= by hand"
fi

# plymouthd exits immediately without 'splash' on the cmdline; 'quiet'
# stops kernel messages painting over the logo. Where this belongs depends
# on how the box boots, so detect rather than guess.
SPLASH_ARGS="quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 logo.nologo"

if grep -qs '^default_uki=' /etc/mkinitcpio.d/linux.preset; then
    echo "Boot type ........... unified kernel image"
    [[ -f /etc/kernel/cmdline ]] || tr -d '\n' < /proc/cmdline > /etc/kernel/cmdline
    CMDLINE="$(tr -d '\n' < /etc/kernel/cmdline)"
    for arg in $SPLASH_ARGS; do
        grep -qw -- "${arg%%=*}" <<< "$CMDLINE" || CMDLINE="${CMDLINE} ${arg}"
    done
    printf '%s\n' "$CMDLINE" > /etc/kernel/cmdline
    chmod 644 /etc/kernel/cmdline
    # The preset ships default_options with --splash pointing at Arch's own
    # logo, so REPLACE it — the preset is sourced as a shell script and the
    # last assignment wins, so a second line would just be overridden.
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
    grep -q '^GRUB_GFXPAYLOAD_LINUX=' /etc/default/grub \
        || echo 'GRUB_GFXPAYLOAD_LINUX=keep' >> /etc/default/grub

    # A fresh Arch install ships GRUB_TIMEOUT=5 with a visible menu, which
    # is what put a GRUB screen in front of the splash on the first
    # provisioned device. sed-in-place, not append: this file is SOURCED,
    # so the last assignment wins and an appended line gets overridden.
    grep -q '^GRUB_TIMEOUT=' /etc/default/grub \
        && sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub \
        || echo 'GRUB_TIMEOUT=0' >> /etc/default/grub
    grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub \
        && sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub \
        || echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub
    echo "GRUB menu ........... hidden, timeout 0 (hold Shift to force it)"

    grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig failed"
else
    warn "Neither a UKI preset nor /etc/default/grub found."
    warn "Add by hand to your bootloader's kernel line: ${SPLASH_ARGS}"
fi

    # -R rebuilds the initramfs/UKI, which is what actually ships the theme.
    # Only meaningful if the theme was built above; otherwise mkinitcpio still
    # needs running so the HOOKS/cmdline changes land.
if [[ "${SPLASH_THEME_BUILT:-0}" == "1" ]]; then
    plymouth-set-default-theme -R "$SPLASH_THEME" \
        || warn "plymouth-set-default-theme failed — the splash will not show"
    echo "Boot splash installed (theme '${SPLASH_THEME}')."
else
    warn "No custom splash theme was built (see the warning above), but the"
    warn "bootloader config WAS applied. Rebuilding the initramfs anyway so the"
    warn "HOOKS and cmdline changes take effect."
    mkinitcpio -P >/dev/null 2>&1 && echo "initramfs rebuilt" \
        || warn "mkinitcpio -P failed"
fi

# ============================================================================
say "Installing devctl (SCUBE internal support CLI)"
# devctl runs as root but everything it targets — the app's SQLite files, IPC
# socket and logs — lives under $KIOSK_USER. None of that is discoverable
# across the account boundary, so this wires it up automatically.
DEVCTL_SRC_BIN="${APP_DIR}/${DEVCTL_BINARY_REL}"
if [[ ! -x "$DEVCTL_SRC_BIN" ]]; then
    warn "devctl not found at $DEVCTL_SRC_BIN — skipping devctl setup."
    warn "With no on-panel terminal, this leaves plain SSH as your only tool."
else
    install -m 0755 "$DEVCTL_SRC_BIN" /usr/local/bin/devctl
    echo "Installed /usr/local/bin/devctl."

    if [[ -z "$DEVCTL_AUTHORIZED_KEYS" ]]; then
        warn "DEVCTL_AUTHORIZED_KEYS is empty. There is no RustDesk and no"
        warn "on-panel terminal in this build, so devctl is the primary support"
        warn "path — add at least one key and re-run before shipping."
    else
        if ! grep -q '^ssh-' <<< "$DEVCTL_AUTHORIZED_KEYS"; then
            warn "DEVCTL_AUTHORIZED_KEYS doesn't look like real 'ssh-...' key lines."
        fi

        DEVCTL_SUPPORT_DIR="${KIOSK_HOME}/.local/share/com.scube.hybridcontroller"
        install -d -m 755 "$DEVCTL_SUPPORT_DIR"
        printf '%s\n' "$DEVCTL_AUTHORIZED_KEYS" > "${DEVCTL_SUPPORT_DIR}/devctl_authorized_keys"
        chmod 600 "${DEVCTL_SUPPORT_DIR}/devctl_authorized_keys"
        chown -R "${KIOSK_USER}:${KIOSK_USER}" "$DEVCTL_SUPPORT_DIR"

        # /etc/environment is read by PAM on essentially any login path,
        # sudo included. XDG_RUNTIME_DIR=/run/user/<uid> exists because the
        # autologin session creates it. If a future systemd change breaks this
        # assumption, `find /run/user -name solscada_ipc.sock` finds the truth.
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

        # Carry the forwarded SSH agent + those vars through sudo. Verified on
        # real hardware: plain `sudo devctl dashboard` authenticates, so -E is
        # belt-and-braces rather than required.
        echo 'Defaults env_keep += "SSH_AUTH_SOCK SOLSCADA_SUPPORT_DIR SOLSCADA_IPC_SOCK SOLSCADA_LOGS_DIR"' \
            > /etc/sudoers.d/devctl-env
        chmod 440 /etc/sudoers.d/devctl-env
        visudo -cf /etc/sudoers.d/devctl-env >/dev/null || die "devctl sudoers rule invalid"

        KEY_COUNT=$(grep -c '^ssh-' <<< "$DEVCTL_AUTHORIZED_KEYS" || true)
        echo "devctl authorized for ${KEY_COUNT} key(s)."
    fi
fi

# ============================================================================
say "Installing helper commands"

# ---- restart / stop the app without a terminal on the panel ---------------
cat > /usr/local/bin/kiosk-app <<'EOF'
#!/bin/bash
# Control the kiosk session over SSH.  Usage: sudo kiosk-app {restart|stop|start|status|log}
# cage owns the app as its child and .bash_profile restarts cage in a loop, so
# "restart" means "kill cage and let the loop bring it back".
set -euo pipefail
KIOSK_USER="KIOSKUSER_PLACEHOLDER"
[[ $EUID -eq 0 ]] || { echo "run as root: sudo kiosk-app <cmd>"; exit 1; }

case "${1:-status}" in
  restart) pkill -u "$KIOSK_USER" -x cage && echo "cage killed; the loop will restart it in ~2s" ;;
  stop)
      # terminate-user also kills the while-loop, so the app stays down until
      # the next login or reboot. pkill alone would just be restarted.
      loginctl terminate-user "$KIOSK_USER" && echo "session terminated; app stays down until reboot" ;;
  start)  systemctl restart "getty@tty1.service" && echo "tty1 getty restarted; autologin will start cage" ;;
  status)
      if pgrep -u "$KIOSK_USER" -x cage >/dev/null; then
          echo "cage: running (pid $(pgrep -u "$KIOSK_USER" -x cage | tr '\n' ' '))"
      else
          echo "cage: NOT running"
      fi
      pgrep -u "$KIOSK_USER" -a -f 'BINARY_PLACEHOLDER' || echo "app: not found" ;;
  log)    tail -n 50 "/home/${KIOSK_USER}/.cage.log" ;;
  *)      echo "usage: sudo kiosk-app {restart|stop|start|status|log}"; exit 1 ;;
esac
EOF
sed -i "s#KIOSKUSER_PLACEHOLDER#${KIOSK_USER}#" /usr/local/bin/kiosk-app
sed -i "s#BINARY_PLACEHOLDER#${APP_DIR}/${APP_BINARY}#" /usr/local/bin/kiosk-app
chmod 755 /usr/local/bin/kiosk-app
chown root:root /usr/local/bin/kiosk-app

# ---- touchscreen diagnostics ----------------------------------------------
cat > /usr/local/bin/kiosk-touch-check <<'EOF'
#!/bin/bash
# Diagnose the touchscreen.  Usage: sudo kiosk-touch-check
# Reads evdev directly, so it works with no display server — there is no
# `xinput test-xi2` equivalent under Wayland.
[[ $EUID -eq 0 ]] || { echo "run as root: sudo kiosk-touch-check"; exit 1; }

echo "== devices libinput can see =="
libinput list-devices 2>/dev/null | grep -iA3 'Device:.*\(touch\|ILITEK\)' \
  || libinput list-devices 2>/dev/null | head -40

echo
echo "== event stream =="
echo "Touch the screen now. Ctrl-C when done."
echo "  TOUCH_DOWN / TOUCH_MOTION / TOUCH_UP -> real multitouch. Good."
echo "  only POINTER_MOTION / BUTTON         -> driven as a plain mouse."
echo
libinput debug-events 2>/dev/null | grep --line-buffered -iE 'TOUCH|POINTER|BUTTON'
EOF
chmod 755 /usr/local/bin/kiosk-touch-check
chown root:root /usr/local/bin/kiosk-touch-check

# ---- splash re-branding ---------------------------------------------------
cat > /usr/local/bin/set-splash <<'EOF'
#!/usr/bin/env bash
# Swap this kiosk's boot logo (plymouth watermark + systemd-stub splash).
#   sudo set-splash [/path/to/logo.png] [width]
# No arguments re-reads the logo in the app bundle. Only the LOGO changes; the
# loading indicator stays as the setup script configured it. Rebuilds the
# initramfs/UKI (~20s). Old images are kept in /var/backups/splash.
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
sed -i "s#THEME_PLACEHOLDER#${SPLASH_THEME}#" /usr/local/bin/set-splash
sed -i "s#WIDTH_PLACEHOLDER#${SPLASH_WIDTH}#" /usr/local/bin/set-splash
sed -i "s#APPDIR_PLACEHOLDER#${APP_DIR}#"     /usr/local/bin/set-splash
sed -i "s#LOGO_PLACEHOLDER#${SPLASH_LOGO}#"   /usr/local/bin/set-splash
chmod 755 /usr/local/bin/set-splash
chown root:root /usr/local/bin/set-splash

# ---- app updater ----------------------------------------------------------
cat > /usr/local/bin/kiosk-update-app <<'EOF'
#!/bin/bash
# Re-deploy the Flutter bundle from git.
# Usage: sudo kiosk-update-app [branch-or-tag] [commit-sha]
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo kiosk-update-app <branch>"; exit 1; }

APP_REPO="REPO_PLACEHOLDER"
APP_DIR="APPDIR_PLACEHOLDER"
APP_BINARY="BINARY_PLACEHOLDER"
KIOSK_USER="KIOSKUSER_PLACEHOLDER"
DEVCTL_BINARY_REL="DEVCTLBIN_PLACEHOLDER"
SPLASH_LOGO="LOGO_PLACEHOLDER"
BRANCH="${1:-BRANCH_PLACEHOLDER}"
COMMIT="${2:-}"

[[ -n "$APP_REPO" ]] || { echo "not deployed from git — nothing to update."; exit 1; }

# Only rebuild the splash if the logo actually changed (~20s saved per deploy).
OLD_LOGO_SUM=""
[[ -n "$SPLASH_LOGO" && -f "${APP_DIR}/${SPLASH_LOGO}" ]] \
  && OLD_LOGO_SUM=$(sha256sum "${APP_DIR}/${SPLASH_LOGO}" | cut -d' ' -f1)

TMP="$(mktemp -d)"
echo "==> cloning $APP_REPO (branch: $BRANCH)"
git clone --depth 1 --single-branch --branch "$BRANCH" "$APP_REPO" "$TMP"
if [[ -n "$COMMIT" ]]; then
    git -C "$TMP" fetch --unshallow || true
    git -C "$TMP" checkout --detach "$COMMIT"
fi
REF="$(git -C "$TMP" rev-parse --short HEAD)"

echo "==> stopping the session"
# terminate-user kills the restart loop too, so the app stays down while the
# files are swapped. Restarted at the end via the tty1 getty.
loginctl terminate-user "$KIOSK_USER" 2>/dev/null || true
sleep 2

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

if [[ ! -x "${APP_DIR}/${APP_BINARY}" ]]; then
    echo "!!  ${APP_DIR}/${APP_BINARY} is missing from this release — rolling back"
    rm -rf "$APP_DIR"; mv "${APP_DIR}.old" "$APP_DIR"
    systemctl restart getty@tty1.service
    exit 1
fi

# devctl ships in the same bundle, so a deploy can bring a newer one.
if [[ -n "$DEVCTL_BINARY_REL" && -x "${APP_DIR}/${DEVCTL_BINARY_REL}" ]]; then
    install -m 0755 "${APP_DIR}/${DEVCTL_BINARY_REL}" /usr/local/bin/devctl
    echo "==> refreshed /usr/local/bin/devctl"
fi

if [[ -n "$SPLASH_LOGO" && -f "${APP_DIR}/${SPLASH_LOGO}" ]] && command -v set-splash >/dev/null; then
    NEW_LOGO_SUM=$(sha256sum "${APP_DIR}/${SPLASH_LOGO}" | cut -d' ' -f1)
    if [[ "$NEW_LOGO_SUM" != "$OLD_LOGO_SUM" ]]; then
        echo "==> logo changed — refreshing the boot splash"
        set-splash "${APP_DIR}/${SPLASH_LOGO}" || echo "!!  splash refresh failed (app is fine)"
    fi
fi

echo "==> restarting the session"
systemctl restart getty@tty1.service

echo "Updated to $BRANCH @ $REF.  Previous version kept at ${APP_DIR}.old"
echo "Check it came up:  sudo kiosk-app status  /  sudo kiosk-app log"
EOF
sed -i "s#REPO_PLACEHOLDER#${APP_REPO}#"               /usr/local/bin/kiosk-update-app
sed -i "s#APPDIR_PLACEHOLDER#${APP_DIR}#"              /usr/local/bin/kiosk-update-app
sed -i "s#BINARY_PLACEHOLDER#${APP_BINARY}#"           /usr/local/bin/kiosk-update-app
sed -i "s#KIOSKUSER_PLACEHOLDER#${KIOSK_USER}#"        /usr/local/bin/kiosk-update-app
sed -i "s#DEVCTLBIN_PLACEHOLDER#${DEVCTL_BINARY_REL}#" /usr/local/bin/kiosk-update-app
sed -i "s#LOGO_PLACEHOLDER#${SPLASH_LOGO}#"            /usr/local/bin/kiosk-update-app
sed -i "s#BRANCH_PLACEHOLDER#${APP_BRANCH:-main}#"     /usr/local/bin/kiosk-update-app
chmod 755 /usr/local/bin/kiosk-update-app
chown root:root /usr/local/bin/kiosk-update-app

# ---- GPIO diagnostics -----------------------------------------------------
cat > /usr/local/bin/kiosk-gpio-check <<'EOF'
#!/bin/bash
# Diagnose GPIO access.  Usage: sudo kiosk-gpio-check
KIOSK_USER="KIOSKUSER_PLACEHOLDER"
GPIO_GROUP="GPIOGROUP_PLACEHOLDER"
GPIO_MODULE="GPIOMODULE_PLACEHOLDER"
APP_BIN="APPBIN_PLACEHOLDER"

echo "== kernel module =="
lsmod | grep -q "${GPIO_MODULE//-/_}" \
  && echo "  $GPIO_MODULE loaded" \
  || echo "  $GPIO_MODULE NOT loaded  ->  dmesg | grep -i it87"

echo "== chip nodes =="
ls -l /dev/gpiochip* 2>/dev/null || echo "  none — the driver did not bind"
command -v gpiodetect >/dev/null && gpiodetect 2>/dev/null

echo "== group membership (passwd database) =="
id "$KIOSK_USER"

echo "== groups of the RUNNING app (this is what actually matters) =="
pid=$(pgrep -u "$KIOSK_USER" -f "$APP_BIN" | head -1)
if [[ -n "$pid" ]]; then
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

echo "== can the kiosk user open the chip? =="
if sudo -u "$KIOSK_USER" test -r /dev/gpiochip0 && sudo -u "$KIOSK_USER" test -w /dev/gpiochip0; then
    echo "  yes"
else
    echo "  NO — check /etc/udev/rules.d/99-gpio.rules and the groups above"
fi

echo "== who is holding the lines? =="
# A stray 'ngpio watch' left running over SSH makes the app's open() return
# EBUSY. gpioinfo shows the consumer label of every claimed line.
command -v gpioinfo >/dev/null && gpioinfo 2>/dev/null | grep -E 'ngpio|used' | head -20
EOF
sed -i "s#KIOSKUSER_PLACEHOLDER#${KIOSK_USER}#"   /usr/local/bin/kiosk-gpio-check
sed -i "s#GPIOGROUP_PLACEHOLDER#${GPIO_GROUP}#"   /usr/local/bin/kiosk-gpio-check
sed -i "s#GPIOMODULE_PLACEHOLDER#${GPIO_MODULE}#" /usr/local/bin/kiosk-gpio-check
sed -i "s#APPBIN_PLACEHOLDER#${APP_DIR}/${APP_BINARY}#" /usr/local/bin/kiosk-gpio-check
chmod 755 /usr/local/bin/kiosk-gpio-check
chown root:root /usr/local/bin/kiosk-gpio-check

# ---- per-device identity --------------------------------------------------
cat > /usr/local/bin/first-setup <<'EOF'
#!/bin/bash
# Give a freshly cloned kiosk a unique identity.
# Usage: sudo first-setup kiosk-01
[[ $EUID -eq 0 ]]  || { echo "run as root: sudo first-setup kiosk-01"; exit 1; }
[[ -n "${1:-}" ]]  || { echo "usage: sudo first-setup <name>"; exit 1; }
NEWNAME="$1"
echo "==> hostname -> $NEWNAME"; hostnamectl set-hostname "$NEWNAME"
echo "==> regenerating machine-id"; rm -f /etc/machine-id; systemd-machine-id-setup
echo "Device: $NEWNAME"
read -p "Reboot now? [y/N] " a; [[ "$a" == y || "$a" == Y ]] && reboot
EOF
chmod 755 /usr/local/bin/first-setup
chown root:root /usr/local/bin/first-setup

# ============================================================================
say "DONE. Summary:"
if [[ ! -x /usr/local/bin/devctl ]]; then
    DEVCTL_STATUS="NOT installed (binary missing from the bundle)"
elif [[ -z "$DEVCTL_AUTHORIZED_KEYS" ]]; then
    DEVCTL_STATUS="installed, but NO key authorized — do this before shipping"
else
    DEVCTL_STATUS="installed, $(grep -c '^ssh-' <<< "$DEVCTL_AUTHORIZED_KEYS" || true) key(s) authorized"
fi
if [[ -z "$SPLASH_LOGO" ]]; then
    SPLASH_STATUS="disabled"
elif [[ -f "/usr/share/plymouth/themes/${SPLASH_THEME}/watermark.png" ]]; then
    SPLASH_STATUS="theme '${SPLASH_THEME}', ${SPLASH_WIDTH}px logo, '${SPLASH_STYLE}' indicator"
else
    SPLASH_STATUS="NOT installed — see the STEP 8 warning above"
fi
cat <<EOF

  Session ............. cage (Wayland), no window manager, no X server
                        cage ${CAGE_ARGS} -- ${APP_DIR}/${APP_BINARY}
                        started from autologin on tty1 (cage needs a seat)
                        restarted forever by a while-loop in .bash_profile
  Kiosk user .......... ${KIOSK_USER}  (no sudo)
                        group 'uucp'   -> RS485 / serial
                        group '${GPIO_GROUP}'   -> /dev/gpiochip* digital IO
  Admin user .......... ${ADMIN_USER}  (full sudo, SSH only)
  App ................. ${APP_DIR}/${APP_BINARY}
  Source .............. ${APP_REPO:-${APP_SRC:-<pre-placed>}}
  Branch .............. ${APP_BRANCH:-<repo default>}${APP_COMMIT:+  (pinned @ ${APP_COMMIT})}
  App log ............. ${KIOSK_HOME}/.cage.log  (rotated at 10M, keep 3)
  fd limit ............ ${APP_NOFILE} via ulimit
  VT switching ........ ${TTY_SWITCH}
  Cursor .............. no pointer is drawn for touch (wlroots behaviour —
                        nothing to configure, unlike the X11 build)
  Boot splash ......... ${SPLASH_STATUS}
                        GRUB menu hidden, timeout 0 (hold Shift to force it)
  GPIO ................ module '${GPIO_MODULE}', udev -> root:${GPIO_GROUP} 0660
                        terminals 1-8 = gpiochip0 lines 48-55
  devctl .............. ${DEVCTL_STATUS}

  NOT PRESENT (by design): X.org, openbox, rofi, xterm, chromium, pcmanfm,
  xdotool, unclutter, RustDesk, F12 menu, Ctrl+Alt+C/T, Alt+F4 guard.
  There is NO on-panel escape hatch. SSH is the way in.

  HELPERS (all over SSH):
    sudo kiosk-app {restart|stop|start|status|log}
    sudo kiosk-update-app <branch>        re-deploy, with rollback on a bad binary
    sudo kiosk-gpio-check                 diagnose dead digital IO
    sudo kiosk-touch-check                diagnose the touchscreen (libinput)
    sudo set-splash [image] [width]       change the boot logo
    sudo first-setup <name>               per-device identity, run once on clones

  NEXT:
    1) reboot
    2) FIRST THING: does the app come up at all? If the screen is black:
         sudo kiosk-app log
       A GTK/Wayland startup failure lands there. This is the single most
       likely failure mode of this build — Flutter's embedder running under
       Wayland is the part that was never verified on your hardware.
    3) touch:  sudo kiosk-touch-check     (expect TOUCH_DOWN / TOUCH_MOTION)
       Then flick a long list IN THE APP and lift your finger:
         momentum scroll -> touch is working end to end. Done.
         stops dead      -> app-side fix (ScrollBehavior.dragDevices), not an
                            OS one. Switching compositor will not help.
    4) GPIO:  sudo kiosk-gpio-check       (every line should say OK)
    5) RS485: configure port/baud/parity in the app
    6) devctl: ssh -A ${ADMIN_USER}@<device>, then sudo devctl health
    7) if the app will not run under Wayland at all, re-run the X11
       setup-kiosk.sh to go back. Keep it to hand.

EOF
warn "Group memberships (uucp, ${GPIO_GROUP}) only reach the running app after a"
warn "full reboot — a process cannot change its own supplementary groups."
echo ""
read -p "  Reboot now? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] && reboot || echo "Reboot later with: sudo reboot"
