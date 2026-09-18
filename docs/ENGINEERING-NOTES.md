# Engineering notes

Deep technical notes for anyone maintaining or re-deriving this integration.
Everything here was verified on Omarchy (Arch) + Hyprland + XWayland.

## 1. Why closing the window killed the driver

PenTablet is a Qt5 Widgets app. It links against the bundled Qt in
`/usr/lib/pentablet/lib`. It creates exactly one top-level window and never:

- calls `QGuiApplication::setQuitOnLastWindowClosed(false)`, nor
- calls `QApplication::setQuitOnLastWindowClosed(false)`.

Qt's default behaviour therefore applies: when the last visible window closes,
`libQt5Widgets` posts a quit, which ends in:

```text
QWidget::close()
  └─ QWidgetPrivate::close_helper()
       └─ QCoreApplicationPrivate::maybeQuit()      [Qt_5_PRIVATE_API]
            └─ if (quitLockRef.load() == 0) quit()
  └─ QCoreApplication::exec() returns
       └─ main() returns 0
```

`maybeQuit()` is the single decisive choke point. `quitLockRef` is an atomic
counter in `QCoreApplicationPrivate`; `setQuitOnLastWindowClosed(false)`
increments it, which is why apps that call it survive. PenTablet never does.

### How this was confirmed

- `LD_DEBUG=bindings` showed the close path resolving
  `_ZN23QCoreApplicationPrivate9maybeQuitEv` from `libQt5Core` with version
  node `Qt_5_PRIVATE_API`.
- Disassembly showed `maybeQuit()` reading the counter at `0x70(%rdi)` and
  branching to quit when zero.
- Interposing `maybeQuit()` with an `LD_PRELOAD` library that returns `0`
  immediately made the process survive close. Log line:
  `maybeQuit BLOCKED pid=…`.

## 2. The shim (`shim/noquit.c`, `shim/noquit.map`)

`libnoquit.so` defines the **literal Itanium C++ mangled names** as plain C
symbols (legal in C, so no `objcopy --redefine-sym` is needed) and uses a linker
version script to attach the **exact ELF version nodes**:

| Symbol                                    | Version node     |
| ----------------------------------------- | ---------------- |
| `_ZN23QCoreApplicationPrivate9maybeQuitEv`| `Qt_5_PRIVATE_API` |
| `_ZN16QCoreApplication17isQuitLockEnabledEv` | `Qt_5`        |
| `_ZN15QGuiApplication25setQuitOnLastWindowClosedEb` | `Qt_5` |

**Critical**: the dynamic linker only binds an interposed symbol if its version
node matches the reference. An unversioned definition is silently ignored for a
versioned reference — verified with `LD_DEBUG=bindings`. `maybeQuit` is a Qt
*private* API symbol, hence `Qt_5_PRIVATE_API`; the other two are public `Qt_5`.

`maybeQuit` is the only interposition strictly required to keep the process
alive; `isQuitLockEnabled`/`setQuitOnLastWindowClosed` are included for
completeness (and to make the shim behave like a genuine
`setQuitOnLastWindowClosed(false)`).

Build:

```sh
cd shim && ./build.sh
# nm -D --with-symbol-versions libnoquit.so | grep ' T '
```

Optional debug logging: set `PENTABLET_SHIM_LOG=/path/file` for the driver
process (add it to the wrapper) to log `libnoquit loaded` and
`maybeQuit BLOCKED` lines.

### Wrapper

`~/.local/bin/xppentablet-xcb`:

```sh
#!/bin/sh
exec env LD_PRELOAD="$HOME/.local/share/pentablet/libnoquit.so" \
         QT_QPA_PLATFORM=xcb \
         /usr/lib/pentablet/PenTablet.sh "$@"
```

`QT_QPA_PLATFORM=xcb` is required so the Qt app talks to XWayland (where the
SNI-less legacy tray path is at least harmless); it is unrelated to the shim.

## 3. Why a real StatusNotifierItem is required

Omarchy's bar renders the tray from `widgets/Tray.qml`. Its `classifyItem`
logic puts an SNI entry in the **drawer** (behind the chevron) when it is
*not* pinned and is `Active`, and shows it inline when pinned. A custom QML bar
module occupies its own slot in the bar layout and **can never enter the drawer**
— there is no shell API to publish a synthetic SNI item. Therefore the only way
to behave like FDM is to own a real SNI item on the session bus.

## 4. The SNI daemon (`bin/xppen-sni`)

- Python 3 + PyGObject (`gi.repository.Gio`, `GLib`).
- Bus name `org.kde.StatusNotifierItem-xppen`, object path `/StatusNotifierItem`.
- Properties: `Id=xppentablet`, `Title=XP-Pen PenTablet`,
  `IconName=xppentablet` (falls back to the hicolor theme icon),
  `Status=Active`, `Menu=/MenuBar`, `Category=ApplicationStatus`.
- `Activate` (left click) → `xppen-ctl show`.
- `com.canonical.dbusmenu` implemented at `/MenuBar`:

  | id | item              |
  | -- | ----------------- |
  | 1  | Show window       |
  | 2  | (separator)       |
  | 3  | Restart driver    |
  | 4  | Quit driver       |

- Registration: calls `org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem`
  once the watcher is present, and uses
  `Gio.bus_watch_name_on_connection` on `org.kde.StatusNotifierWatcher` to
  **re-register whenever the watcher restarts** (quickshell hosts the watcher,
  so `omarchy restart shell` would otherwise drop the icon).

### GDBus / GLib.Variant pitfalls

These cost real debugging time:

- The stdlib `dbus` Python module on this system is a limited build: no
  `dbus.Variant`, no `dbus.service.property`. Use PyGObject `GDBus` instead.
- **`a{sv}` values must be `GLib.Variant`** objects, not bare Python values.
- Build nested containers in **one** `GLib.Variant(type, value)` call using
  plain nested tuples for the fixed part. Passing an already-built container
  `GLib.Variant` where the signature expects a struct/tuple raises
  `Expected GLib.Variant, but got …` (or vice-versa).
- `GetLayout` must return signature `(u(ia{sv}av))`:
  `GLib.Variant("(u(ia{sv}av))", (1, (0, {"children-display": GLib.Variant("s","submenu")}, children)))`
  where `children` is a Python list of pre-built
  `GLib.Variant("(ia{sv}av)", …)` items (because the `av` element type is a
  variant).
- `IconPixmap`/`ToolTip` etc. may be left empty; the `IconName` theme lookup is
  enough because the XP-Pen driver installs
  `/usr/share/icons/hicolor/256x256/apps/xppentablet.png`.

## 5. Driver control path

PenTablet uses `QtSingleApplication`. Its local socket is
`/tmp/qtsingleapp-XPPenT-6c81` (path derived from app id + user). Protocol: a
4-byte **big-endian** length prefix followed by a UTF-8 message; the app replies
`ack`. `?Tray.show` raises the existing window (X11 window id `0x600006` on the
test machine — do **not** hardcode it; match by `_NET_WM_PID`).

Note: `Tray.exit` would normally quit, but its code path also goes through the
now-blocked `maybeQuit`, so it no longer exits. **Quit is therefore implemented
as `systemctl --user stop app-xppentablet@autostart.service`** (SIGTERM), which
works reliably.

`xppen-status` determines "shown" by scanning `_NET_CLIENT_LIST` and matching
`_NET_WM_PID` against the running `PenTablet` pid. It must not match a fixed X
id, because ids change on every restart.

## 6. Verification matrix (all passed)

| Check                                            | Result |
| ------------------------------------------------ | ------ |
| Close window → process survives                  | pass   |
| Close window → `xppen-status` = `running hidden` | pass   |
| SNI `Activate` → `running shown`                 | pass   |
| Menu id 1 (Show)    → `running shown`            | pass   |
| Menu id 3 (Restart) → `running shown`            | pass   |
| Menu id 4 (Quit)    → `stopped hidden`           | pass   |
| Survives `omarchy restart shell` (re-registers)  | pass   |
| `GetLayout` returns a valid dbusmenu tree        | pass   |

## 7. Rollback

```sh
systemctl --user disable --now xppen-tray.service
rm ~/.local/bin/xppen-sni ~/.local/bin/xppen-ctl ~/.local/bin/xppen-status
# make the wrapper not preload the shim (close then kills the driver again)
```

The stock behaviour is untouched on disk: the system autostart entry and the
`/usr/lib/pentablet` install are never modified, only shadowed by the user
autostart entry.
