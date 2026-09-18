#!/bin/sh
# Non-destructive verification of the XPPen tray integration.
# By default it only inspects state. Pass --close to also exercise the
# close-to-tray behaviour (closes the window, then re-shows it).
set -u

WANT_CLOSE=0
[ "${1:-}" = "--close" ] && WANT_CLOSE=1

pass=0; fail=0
ok()   { printf '  [ok]   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
info() { printf '  [--]   %s\n' "$*"; }

SHARE="$HOME/.local/share/pentablet"
BIN="$HOME/.local/bin"
SNI="${SNI:-org.kde.StatusNotifierItem-xppen}"
WATCHER=org.kde.StatusNotifierWatcher

echo "== prerequisites =="
[ -x /usr/lib/pentablet/PenTablet.sh ] \
    && ok "driver present at /usr/lib/pentablet/PenTablet.sh" \
    || bad "driver missing at /usr/lib/pentablet/PenTablet.sh"
python3 -c 'from gi.repository import Gio, GLib' >/dev/null 2>&1 \
    && ok "python-gobject (GDBus) available" \
    || bad "python-gobject missing"

echo "== installed files =="
for f in "$SHARE/libnoquit.so" "$BIN/xppentablet-xcb" "$BIN/xppen-sni" \
         "$BIN/xppen-ctl" "$BIN/xppen-status"; do
    [ -e "$f" ] && ok "$f" || bad "missing $f"
done

echo "== shim =="
if [ -e "$SHARE/libnoquit.so" ]; then
    for sym in \
        '_ZN23QCoreApplicationPrivate9maybeQuitEv@@Qt_5_PRIVATE_API' \
        '_ZN16QCoreApplication17isQuitLockEnabledEv@@Qt_5' \
        '_ZN15QGuiApplication25setQuitOnLastWindowClosedEb@@Qt_5'; do
        nm -D --with-symbol-versions "$SHARE/libnoquit.so" 2>/dev/null \
            | grep -q -- "$sym" \
            && ok "exports $sym" || bad "missing export $sym"
    done
fi
grep -q 'LD_PRELOAD' "$BIN/xppentablet-xcb" 2>/dev/null \
    && ok "wrapper preloads the shim" || bad "wrapper does not preload the shim"

echo "== tray service =="
systemctl --user is-active --quiet xppen-tray.service \
    && ok "xppen-tray.service active" \
    || bad "xppen-tray.service not active (systemctl --user start xppen-tray.service)"

echo "== SNI registration =="
if busctl --user get-property "$WATCHER" /StatusNotifierWatcher "$WATCHER" \
        RegisteredStatusNotifierItems >/dev/null 2>&1; then
    if busctl --user get-property "$WATCHER" /StatusNotifierWatcher "$WATCHER" \
            RegisteredStatusNotifierItems 2>/dev/null | grep -q "$SNI"; then
        ok "$SNI registered with the watcher"
    else
        bad "$SNI not found in RegisteredStatusNotifierItems"
    fi
else
    info "watcher not reachable (is the Omarchy shell running?)"
fi
busctl --user get-property "$SNI" /StatusNotifierItem \
    org.kde.StatusNotifierItem Status >/dev/null 2>&1 \
    && ok "SNI interface responds" || bad "SNI interface does not respond"
busctl --user call "$SNI" /MenuBar com.canonical.dbusmenu GetLayout iias 0 1 0 \
    >/dev/null 2>&1 \
    && ok "dbusmenu GetLayout responds" || bad "dbusmenu GetLayout failed"

echo "== driver =="
if pgrep -x PenTablet >/dev/null 2>&1; then
    ok "driver running ($( "$BIN/xppen-status" 2>/dev/null || echo '?' ))"
    if grep -qa LD_PRELOAD /proc/"$(pgrep -x PenTablet | head -1)"/environ 2>/dev/null; then
        ok "running driver has LD_PRELOAD set"
    else
        bad "running driver has no LD_PRELOAD (restart it via the wrapper)"
    fi
else
    info "driver not running"
fi

if [ "$WANT_CLOSE" = 1 ]; then
    echo "== close-to-tray =="
    if ! pgrep -x PenTablet >/dev/null 2>&1; then
        "$BIN/xppen-ctl" show >/dev/null 2>&1
        sleep 4
    fi
    "$BIN/xppen-ctl" show >/dev/null 2>&1
    sleep 2
    before=$("$BIN/xppen-status" 2>/dev/null)
    python3 "$(dirname "$0")/close-window.py" --pid "$(pgrep -x PenTablet | head -1)" >/dev/null 2>&1
    sleep 3
    after=$("$BIN/xppen-status" 2>/dev/null)
    info "before=$before after=$after"
    case "$after" in
        "running hidden") ok "closing the window hid it and kept the driver alive" ;;
        *)                bad "close-to-tray failed (expected 'running hidden')" ;;
    esac
    "$BIN/xppen-ctl" show >/dev/null 2>&1
    sleep 2
    [ "$("$BIN/xppen-status" 2>/dev/null)" = "running shown" ] \
        && ok "re-show after close works" || bad "re-show after close failed"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
