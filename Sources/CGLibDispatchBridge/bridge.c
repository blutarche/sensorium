#include "sensorium-glib-dispatch-bridge.h"

#if defined(__linux__)

#include <glib.h>
#include <stdint.h>
#include <unistd.h>

// Dispatch's own integration points for a foreign run loop. They are what
// CoreFoundation uses to drain the main queue from a run loop it owns, and
// they are the only supported way to do the same from a GLib main loop: the
// first hands over a file descriptor that becomes readable when the main
// queue has work, and the second drains whatever is waiting.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *message);

static gboolean sensorium_drain_main_queue(GIOChannel *channel, GIOCondition condition, gpointer data)
{
    (void)condition;
    (void)data;
    uint64_t signalled;
    // The descriptor is an eventfd whose only purpose is to wake this
    // watch; its counter carries no information worth reading.
    ssize_t read_bytes = read(g_io_channel_unix_get_fd(channel), &signalled, sizeof signalled);
    (void)read_bytes;
    _dispatch_main_queue_callback_4CF(NULL);
    return G_SOURCE_CONTINUE;
}

int sensorium_attach_dispatch_main_queue(void)
{
    int handle = _dispatch_get_main_queue_handle_4CF();
    if (handle < 0) {
        return 0;
    }
    GIOChannel *channel = g_io_channel_unix_new(handle);
    g_io_add_watch(channel, G_IO_IN, sensorium_drain_main_queue, NULL);
    g_io_channel_unref(channel);
    return 1;
}

#else

int sensorium_attach_dispatch_main_queue(void)
{
    return 0;
}

#endif
