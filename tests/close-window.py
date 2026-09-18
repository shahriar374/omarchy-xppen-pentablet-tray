#!/usr/bin/env python3
"""Send WM_DELETE_WINDOW to an X11/XWayland window.

Usage:
  close-window.py <window-id-hex>        # e.g. 0x800006
  close-window.py --pid <pid>            # find the window owned by pid

Pure ctypes/libX11 so it works without xdotool/wmctrl/python-xlib.
Exits 0 if the ClientMessage was sent, 1 on error.
"""
import ctypes
import ctypes.util
import re
import subprocess
import sys

X11 = ctypes.CDLL(ctypes.util.find_library("X11"))
X11.XOpenDisplay.restype = ctypes.c_void_p
X11.XOpenDisplay.argtypes = [ctypes.c_char_p]
X11.XInternAtom.restype = ctypes.c_ulong
X11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
X11.XSendEvent.restype = ctypes.c_int
X11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                           ctypes.c_long, ctypes.c_void_p]
X11.XFlush.argtypes = [ctypes.c_void_p]
X11.XCloseDisplay.argtypes = [ctypes.c_void_p]

CLIENT_MESSAGE = 33
WM_PROTOCOLS = "WM_PROTOCOLS"
WM_DELETE_WINDOW = "WM_DELETE_WINDOW"


class XClientMessageEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", ctypes.c_ulong),
        ("message_type", ctypes.c_ulong),
        ("format", ctypes.c_int),
        ("data", ctypes.c_long * 5),
    ]


class XEvent(ctypes.Union):
    _fields_ = [
        ("type", ctypes.c_int),
        ("xclient", XClientMessageEvent),
        ("pad", ctypes.c_long * 24),
    ]


def pid_to_window(pid):
    out = subprocess.run(["xprop", "-root", "_NET_CLIENT_LIST"],
                         capture_output=True, text=True).stdout
    for win in re.findall(r"0x[0-9a-fA-F]+", out):
        wp = subprocess.run(["xprop", "-id", win, "_NET_WM_PID"],
                            capture_output=True, text=True).stdout
        m = re.search(r"=\s*(\d+)", wp)
        if m and m.group(1) == str(pid):
            return win
    return None


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--pid":
        win = pid_to_window(sys.argv[2])
        if not win:
            print("no window for pid %s" % sys.argv[2], file=sys.stderr)
            return 1
    elif len(sys.argv) == 2:
        win = sys.argv[1]
    else:
        print(__doc__, file=sys.stderr)
        return 1

    display = X11.XOpenDisplay(None)
    if not display:
        print("cannot open display", file=sys.stderr)
        return 1

    wm_protocols = X11.XInternAtom(display, WM_PROTOCOLS.encode(), False)
    wm_delete = X11.XInternAtom(display, WM_DELETE_WINDOW.encode(), False)

    ev = XEvent()
    ev.xclient.type = CLIENT_MESSAGE
    ev.xclient.send_event = 1
    ev.xclient.display = display
    ev.xclient.window = int(win, 16)
    ev.xclient.message_type = wm_protocols
    ev.xclient.format = 32
    ev.xclient.data[0] = wm_delete
    ev.xclient.data[1] = 0

    X11.XSendEvent(display, ev.xclient.window, False, 0, ctypes.byref(ev))
    X11.XFlush(display)
    X11.XCloseDisplay(display)
    print("sent WM_DELETE_WINDOW to %s" % win)
    return 0


if __name__ == "__main__":
    sys.exit(main())
