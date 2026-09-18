#!/bin/sh
# Install the XPPen PenTablet tray integration for Omarchy / Hyprland.
#
# Idempotent. Run as your normal desktop user (NOT root, NOT with sudo):
#   ./install.sh
#
# What it does:
#   1. builds libnoquit.so (needs a C compiler)
#   2. installs the shim + helper scripts under ~/.local
#   3. installs a user autostart entry that runs the driver via the shim
#   4. installs + starts the StatusNotifierItem tray service
set -eu

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
HOME_DIR=$HOME
SHARE_DIR="$HOME_DIR/.local/share/pentablet"
BIN_DIR="$HOME_DIR/.local/bin"
SYSTEMD_DIR="$HOME_DIR/.config/systemd/user"
AUTOSTART_DIR="$HOME_DIR/.config/autostart"
DRIVER_UNIT="app-xppentablet@autostart.service"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- prereqs
[ "$(id -u)" -ne 0 ] || die "run as your desktop user, not root"

[ -x /usr/lib/pentablet/PenTablet.sh ] \
    || die "XP-Pen driver not found at /usr/lib/pentablet/PenTablet.sh (install the official driver first)"

command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 \
    || die "no C compiler (install base-devel / gcc)"

python3 -c 'from gi.repository import Gio, GLib' >/dev/null 2>&1 \
    || die "python-gobject missing (install python-gobject)"

command -v systemctl >/dev/null 2>&1 || die "systemd user session required"

# ---------------------------------------------------------------- build
say "==> building libnoquit.so"
( cd "$REPO_DIR/shim" && ./build.sh >/dev/null )
[ -f "$REPO_DIR/shim/libnoquit.so" ] || die "shim build failed"

# ---------------------------------------------------------------- install
say "==> installing files"
mkdir -p "$SHARE_DIR" "$BIN_DIR" "$SYSTEMD_DIR" "$AUTOSTART_DIR"

install -m 0755 "$REPO_DIR/shim/libnoquit.so"      "$SHARE_DIR/libnoquit.so"
install -m 0755 "$REPO_DIR/bin/xppentablet-xcb"    "$BIN_DIR/xppentablet-xcb"
install -m 0755 "$REPO_DIR/bin/xppen-ctl"          "$BIN_DIR/xppen-ctl"
install -m 0755 "$REPO_DIR/bin/xppen-status"       "$BIN_DIR/xppen-status"
install -m 0755 "$REPO_DIR/bin/xppen-sni"          "$BIN_DIR/xppen-sni"
install -m 0644 "$REPO_DIR/systemd/xppen-tray.service" "$SYSTEMD_DIR/xppen-tray.service"

# Autostart: run the driver through the shim wrapper. Back up any existing file.
if [ -f "$AUTOSTART_DIR/xppentablet.desktop" ]; then
    cp -f "$AUTOSTART_DIR/xppentablet.desktop" \
          "$AUTOSTART_DIR/xppentablet.desktop.bak.$$"
    say "    backed up existing autostart to xppentablet.desktop.bak.$$"
fi
sed "s|@HOME@|$HOME_DIR|g" "$REPO_DIR/autostart/xppentablet.desktop.in" \
    > "$AUTOSTART_DIR/xppentablet.desktop"

# ---------------------------------------------------------------- enable
say "==> enabling tray service"
systemctl --user daemon-reload
systemctl --user enable --now xppen-tray.service

# Restart the driver so the shim is loaded into the running process.
if systemctl --user list-unit-files "$DRIVER_UNIT" >/dev/null 2>&1; then
    systemctl --user restart "$DRIVER_UNIT" 2>/dev/null || true
fi

say ""
say "Done. The XPPen icon now lives in the tray drawer (hover the arrow)."
say "  status : xppen-status"
say "  show   : xppen-ctl show"
say "  quit   : xppen-ctl quit"
say "  verify : $REPO_DIR/tests/verify.sh"
say ""
say "If the driver was already running outside systemd, restart it manually"
say "so the shim takes effect: run $HOME_DIR/.local/bin/xppentablet-xcb"
