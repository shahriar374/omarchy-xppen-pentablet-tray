# omarchy-xppen-pentablet-tray

Close-to-tray and a native system-tray icon for the **XP-Pen PenTablet** Linux
driver on **Omarchy / Hyprland**.

Closing the PenTablet settings window no longer kills the driver — it hides, the
pen keeps working, and a tray icon in the Omarchy bar lets you show the window
again, restart the driver, or quit it.

The icon is a genuine `StatusNotifierItem`, so Omarchy's `omarchy.tray` files it
automatically in the **drawer** behind the chevron (exactly like Free Download
Manager) and reveals it on hover/click. No third-party SNI bridge is used.

## The problem

PenTablet is a closed-source Qt5 application that:

- has no system-tray integration of its own (only a legacy XEmbed icon, which
  Wayland shells ignore), and
- never calls `QGuiApplication::setQuitOnLastWindowClosed(false)`.

So closing its only window runs Qt's last-window path
(`libQt5Widgets → QCoreApplicationPrivate::maybeQuit()`), the event loop exits,
`main()` returns, and the driver process dies — which stops the tablet.

Free Download Manager survives the same close because it does call
`setQuitOnLastWindowClosed(false)` and publishes a `StatusNotifierItem`.

## The fix (two independent pieces)

1. **`libnoquit.so`** — a tiny `LD_PRELOAD` shim that makes
   `QCoreApplicationPrivate::maybeQuit()` a no-op. This is exactly equivalent to
   `setQuitOnLastWindowClosed(false)`: the window hides and the driver stays
   alive. See `shim/noquit.c`.
2. **`xppen-sni`** — a small PyGObject/GDBus service that publishes a real
   `org.kde.StatusNotifierItem` (`org.kde.StatusNotifierItem-xppen`) with a
   `com.canonical.dbusmenu` menu: **Show window / Restart driver / Quit driver**.
   It registers with `org.kde.StatusNotifierWatcher` (hosted by quickshell) and
   re-registers automatically when the shell restarts.

## Architecture

```
login
 └─ ~/.config/autostart/xppentablet.desktop
      └─ xppentablet-xcb                      (wrapper: LD_PRELOAD + xcb)
           └─ PenTablet.sh ── PenTablet (Qt5, XWayland)
                                  ▲
   xppen-tray.service ─ xppen-sni │  Activate / dbusmenu (D-Bus)
        (StatusNotifierItem) ─────┘
             │ registers with
             ▼
      org.kde.StatusNotifierWatcher (quickshell)
             │
             ▼
        omarchy.tray  ──►  drawer behind the chevron
```

## Requirements

- Omarchy (Arch Linux) with Hyprland and the Omarchy shell/bar.
- The **official XP-Pen Linux driver** installed, providing:
  - `/usr/lib/pentablet/PenTablet.sh`
  - the `xppentablet` icon in `/usr/share/icons/hicolor/*/apps/`
  - a system autostart entry.
- Build/runtime deps (all in the default Omarchy base):
  - a C compiler (`gcc` / `base-devel`)
  - `python` + `python-gobject` (PyGObject, for GDBus)
  - `systemd` user session

## Install

```sh
git clone git@github.com:shahriar374/omarchy-xppen-pentablet-tray.git
cd omarchy-xppen-pentablet-tray
./install.sh
```

`install.sh` is idempotent. It builds the shim, installs everything under
`~/.local` and `~/.config`, back up any existing autostart entry, enables the
tray service, and restarts the driver so the shim takes effect.

If the driver was already running outside systemd, restart it (log out/in, or
start `~/.local/bin/xppentablet-xcb`) so `LD_PRELOAD` is applied.

## Verify

```sh
tests/verify.sh          # non-destructive checks
xppen-status             # -> "running shown" / "running hidden" / "stopped hidden"
```

Manual check: close the PenTablet window — it should disappear while
`pgrep -x PenTablet` still succeeds, and `xppen-status` prints `running hidden`.

## Usage

| Command             | Effect                                            |
| ------------------- | ------------------------------------------------- |
| `xppen-ctl show`    | Show the window (starts the driver if needed)     |
| `xppen-ctl quit`    | Stop the driver                                   |
| `xppen-ctl restart` | Restart the driver                                |
| `xppen-status`      | Print `running\|stopped` + `shown\|hidden`        |

Tray icon: **left click** shows the window; **right click** opens the menu.

## Troubleshooting

- **No icon in the tray**: make sure `omarchy.tray` is in your bar layout
  (`~/.config/omarchy/shell.json`) and run `omarchy restart shell`. Confirm the
  item is registered:
  `busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems`.
- **Closing the window still stops the driver**: the shim is not loaded. Check
  the wrapper (`~/.local/bin/xppentablet-xcb`), then
  `grep -z LD_PRELOAD /proc/$(pgrep -x PenTablet)/environ`.
  Debug logging: set `PENTABLET_SHIM_LOG=/tmp/noquit.log` in the wrapper.
- **Service fails / driver unit name differs**: adjust `SERVICE` in
  `bin/xppen-ctl` (find it with `systemctl --user list-units 'app-xppentablet*'`).

## Uninstall

```sh
./uninstall.sh
```

## Files

| Path                                   | Purpose                                    |
| -------------------------------------- | ------------------------------------------ |
| `shim/noquit.c`, `noquit.map`, `build.sh` | `LD_PRELOAD` quit-suppression shim       |
| `bin/xppentablet-xcb`                  | Driver wrapper (`LD_PRELOAD` + `xcb`)      |
| `bin/xppen-sni`                        | StatusNotifierItem + dbusmenu daemon       |
| `bin/xppen-ctl`, `bin/xppen-status`    | Control/status helpers                     |
| `systemd/xppen-tray.service`           | User unit for the tray daemon              |
| `autostart/xppentablet.desktop.in`     | Driver autostart template                  |
| `install.sh`, `uninstall.sh`           | Installer / uninstaller                    |
| `tests/verify.sh`, `tests/close-window.py` | Verification                           |
| `docs/ENGINEERING-NOTES.md`            | Deep technical notes                       |
