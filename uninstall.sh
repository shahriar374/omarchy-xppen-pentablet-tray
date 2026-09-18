#!/bin/sh
# Remove the XPPen PenTablet tray integration installed by install.sh.
# The stock XP-Pen driver stays installed and its system autostart entry is
# untouched, so after this the driver behaves as it did before (no tray).
set -eu

SHARE_DIR="$HOME/.local/share/pentablet"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
AUTOSTART_DIR="$HOME/.config/autostart"

say() { printf '%s\n' "$*"; }

say "==> stopping tray service"
systemctl --user disable --now xppen-tray.service 2>/dev/null || true

say "==> removing files"
rm -f "$BIN_DIR/xppen-sni" "$BIN_DIR/xppen-ctl" "$BIN_DIR/xppen-status" \
      "$BIN_DIR/xppentablet-xcb"
rm -f "$SHARE_DIR/libnoquit.so"
rm -f "$SYSTEMD_DIR/xppen-tray.service"

# Restore the previous autostart entry if install.sh made a backup, otherwise
# remove our override so the system entry takes over again.
if [ -f "$AUTOSTART_DIR/xppentablet.desktop.bak" ]; then
    mv -f "$AUTOSTART_DIR/xppentablet.desktop.bak" \
          "$AUTOSTART_DIR/xppentablet.desktop"
    say "    restored previous autostart from xppentablet.desktop.bak"
else
    rm -f "$AUTOSTART_DIR/xppentablet.desktop"
fi

systemctl --user daemon-reload
say ""
say "Removed. Restart the driver (or log out/in) to return to stock behaviour."
