/*
 * libnoquit.so — LD_PRELOAD shim for the XP-Pen PenTablet driver (Qt5).
 *
 * WHY
 * ---
 * PenTablet is a closed-source Qt5 application that ships no system tray and
 * never calls QGuiApplication::setQuitOnLastWindowClosed(false). When the
 * settings window is closed, Qt5 Widgets runs its normal last-window path:
 *
 *   QWidget close -> QCoreApplicationPrivate::maybeQuit() -> quit event loop
 *
 * which makes main() return and the whole driver process exit — so closing the
 * window also stops the tablet. Free Download Manager avoids this by calling
 * setQuitOnLastWindowClosed(false); we cannot change PenTablet, so instead we
 * make the one decisive function, QCoreApplicationPrivate::maybeQuit(),
 * a no-op. That is exactly equivalent to setQuitOnLastWindowClosed(false):
 * closing the last window hides it, and the event loop keeps running.
 *
 * HOW THE SYMBOLS BIND
 * --------------------
 * The app links against versioned Qt symbols:
 *   maybeQuit                  -> Qt_5_PRIVATE_API   (bool maybeQuit())
 *   isQuitLockEnabled          -> Qt_5
 *   setQuitOnLastWindowClosed  -> Qt_5
 *
 * An interposed symbol only replaces the reference if it carries the SAME ELF
 * version node, so the version script (noquit.map) tags each export with the
 * exact node. Unversioned definitions are silently ignored by the dynamic
 * linker for versioned references — verified with LD_DEBUG=bindings.
 *
 * The C identifiers below are the literal Itanium C++ mangled names, which is
 * legal in C and removes the need for objcopy --redefine-sym.
 *
 * DEBUGGING
 * ---------
 * Set PENTABLET_SHIM_LOG=/path/to/file to log load/blocked events.
 * Without it the shim is silent.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>

static void shim_log(const char *fmt, long value)
{
    const char *path = getenv("PENTABLET_SHIM_LOG");
    if (!path || !*path)
        return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0)
        return;
    char buf[160];
    int n = snprintf(buf, sizeof buf, fmt, value);
    if (n > 0) {
        ssize_t ignored = write(fd, buf, (size_t)n);
        (void)ignored;
    }
    close(fd);
}

__attribute__((constructor)) static void shim_loaded(void)
{
    shim_log("libnoquit loaded pid=%ld\n", (long)getpid());
}

/* QCoreApplicationPrivate::maybeQuit() -> return immediately (block quit) */
int _ZN23QCoreApplicationPrivate9maybeQuitEv(void *self)
{
    (void)self;
    shim_log("maybeQuit BLOCKED pid=%ld\n", (long)getpid());
    return 0;
}

/* QCoreApplication::isQuitLockEnabled() -> false */
int _ZN16QCoreApplication17isQuitLockEnabledEv(void)
{
    return 0;
}

/* QGuiApplication::setQuitOnLastWindowClosed(bool) -> no-op */
void _ZN15QGuiApplication25setQuitOnLastWindowClosedEb(void *self, int enabled)
{
    (void)self;
    (void)enabled;
}
