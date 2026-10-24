#!/usr/bin/env python3
"""Double-click the title bar only in the harness's nested KWin session."""
import ctypes
from pathlib import Path
import os
import select
import subprocess
import sys
import time

import gi
from gi.repository import Gio, GLib

if not os.environ.get("WAYLAND_DISPLAY", "").startswith("sensorium-harness-"):
    raise SystemExit("REFUSED: titlebar input requires the nested harness socket")
if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
    raise SystemExit("REFUSED: no isolated session bus")

output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
owner = bus.call_sync(
    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "GetConnectionUnixProcessID", GLib.Variant("(s)", ("org.kde.KWin",)),
    GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 5000, None,
).unpack()[0]
arguments = [os.fsdecode(argument) for argument in Path(f"/proc/{owner}/cmdline").read_bytes().split(b"\0") if argument]
try:
    nested_socket = arguments[arguments.index("--socket") + 1]
except (ValueError, IndexError):
    raise SystemExit("REFUSED: session bus does not belong to the nested compositor")
if "--virtual" not in arguments or nested_socket != os.environ["WAYLAND_DISPLAY"]:
    raise SystemExit("REFUSED: session bus and nested compositor socket do not match")
print("isolation: session bus owner is the matching virtual compositor", flush=True)
reply, descriptors = bus.call_with_unix_fd_list_sync(
    "org.kde.KWin", "/org/kde/KWin/EIS/RemoteDesktop",
    "org.kde.KWin.EIS.RemoteDesktop", "connectToEIS",
    GLib.Variant("(i)", (2,)), None, Gio.DBusCallFlags.NONE, 5000, None, None,
)
handle, cookie = reply.unpack()
lib = ctypes.CDLL("libei.so.1")
pointer = ctypes.c_void_p

def api(name, result, *arguments):
    function = getattr(lib, name)
    function.restype = result
    function.argtypes = list(arguments)
    return function

new = api("ei_new_sender", pointer, pointer)
configure = api("ei_configure_name", None, pointer, ctypes.c_char_p)
setup = api("ei_setup_backend_fd", ctypes.c_int, pointer, ctypes.c_int)
dispatch = api("ei_dispatch", None, pointer)
get_fd = api("ei_get_fd", ctypes.c_int, pointer)
get_event = api("ei_get_event", pointer, pointer)
event_type = api("ei_event_get_type", ctypes.c_int, pointer)
event_name = api("ei_event_type_to_string", ctypes.c_char_p, ctypes.c_int)
event_device = api("ei_event_get_device", pointer, pointer)
event_seat = api("ei_event_get_seat", pointer, pointer)
unref_event = api("ei_event_unref", pointer, pointer)
has = api("ei_device_has_capability", ctypes.c_bool, pointer, ctypes.c_int)
ref_device = api("ei_device_ref", pointer, pointer)
unref_device = api("ei_device_unref", pointer, pointer)
start = api("ei_device_start_emulating", None, pointer, ctypes.c_uint32)
move = api("ei_device_pointer_motion_absolute", None, pointer, ctypes.c_double, ctypes.c_double)
button = api("ei_device_button_button", None, pointer, ctypes.c_uint32, ctypes.c_bool)
frame = api("ei_device_frame", None, pointer, ctypes.c_uint64)
now = api("ei_now", ctypes.c_uint64, pointer)
unref = api("ei_unref", pointer, pointer)
# Public capability bits and signatures: libei libei.h.
# https://libinput.pages.freedesktop.org/libei/api/libei_8h_source.html
bind = api("ei_seat_bind_capabilities", None, pointer)
context = new(None)
configure(context, b"Sensorium nested maximize verification")
if setup(context, descriptors.get(handle)) != 0:
    raise SystemExit("FAIL: could not attach to nested compositor EIS")
absolute = None
buttons = None

def pump(seconds):
    global absolute, buttons
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        select.select([get_fd(context)], [], [], min(0.02, max(0, deadline - time.monotonic())))
        dispatch(context)
        while event := get_event(context):
            kind = event_type(event)
            
            if kind == 3:
                bind(event_seat(event), ctypes.c_int(2), ctypes.c_int(32), ctypes.c_int(0))
            elif kind == 8:
                device = event_device(event)
                start(device, 1)
                if has(device, 2):
                    absolute = ref_device(device)
                if has(device, 32):
                    buttons = ref_device(device)
            elif kind == 2:
                raise SystemExit("FAIL: nested compositor disconnected input sender")
            unref_event(event)

try:
    pump(2)
    if not absolute or not buttons:
        raise SystemExit("FAIL: nested compositor did not provide pointer and button devices")
    def shot(label):
        pump(0.5)
        subprocess.run(["spectacle", "-b", "-n", "-f", "-o", str(output / f"maximize-{label}.png")], check=True)
        print(f"maximize-{label}: screenshot saved", flush=True)
    def double_click(x, y):
        move(absolute, x, y)
        frame(absolute, now(context))
        pump(0.1)
        for _ in range(2):
            button(buttons, 272, True)
            frame(buttons, now(context))
            pump(0.04)
            button(buttons, 272, False)
            frame(buttons, now(context))
            pump(0.04)
        print(f"titlebar: sent actual left-button double-click at {x},{y}", flush=True)
    # A private 1920x1080 output places the restored 1280x800 window here.
    shot("before")
    double_click(960, 14)
    shot("restored")
    double_click(960, 135)
    shot("maximized")
    for cycle in range(2):
        double_click(960, 14)
        shot(f"restored-{cycle + 2}")
        double_click(960, 135)
        shot(f"maximized-{cycle + 2}")

finally:
    if absolute:
        unref_device(absolute)
    if buttons:
        unref_device(buttons)
    unref(context)
    bus.call_sync("org.kde.KWin", "/org/kde/KWin/EIS/RemoteDesktop",
                  "org.kde.KWin.EIS.RemoteDesktop", "disconnect",
                  GLib.Variant("(i)", (cookie,)), None, Gio.DBusCallFlags.NONE, 5000, None)
