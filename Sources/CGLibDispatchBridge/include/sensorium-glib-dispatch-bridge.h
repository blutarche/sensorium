#ifndef SENSORIUM_GLIB_DISPATCH_BRIDGE_H
#define SENSORIUM_GLIB_DISPATCH_BRIDGE_H

// Attaches the calling thread's Dispatch main queue to the default GLib main
// context, so that work enqueued on the main queue -- which is what a
// `@MainActor` job on this platform becomes -- runs on the thread that is
// inside `g_main_loop_run`.
//
// Returns whether the main queue could be attached. It cannot be once the
// process has entered `dispatch_main()` on another thread, so this has to be
// called from the main actor, before the GLib loop is entered.
int sensorium_attach_dispatch_main_queue(void);

#endif
