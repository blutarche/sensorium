#include "sensorium-wayland-glue.h"

#if defined(__linux__)

#include <string.h>
#include <wayland-client.h>

#include "fractional-scale-v1-client-protocol.h"
#include "keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h"
#include "linux-dmabuf-v1-client-protocol.h"
#include "pointer-constraints-unstable-v1-client-protocol.h"
#include "presentation-time-client-protocol.h"
#include "relative-pointer-unstable-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

static const struct wl_interface *description_named(const char *interface)
{
    if (!strcmp(interface, "wl_compositor")) return &wl_compositor_interface;
    if (!strcmp(interface, "wl_subcompositor")) return &wl_subcompositor_interface;
    if (!strcmp(interface, "wl_shm")) return &wl_shm_interface;
    if (!strcmp(interface, "wl_seat")) return &wl_seat_interface;
    if (!strcmp(interface, "wl_output")) return &wl_output_interface;
    // Core protocol, declared by wayland-client.h itself -- no generated
    // protocol header needed.
    if (!strcmp(interface, "wl_data_device_manager")) return &wl_data_device_manager_interface;
    if (!strcmp(interface, "xdg_wm_base")) return &xdg_wm_base_interface;
    if (!strcmp(interface, "zxdg_decoration_manager_v1")) return &zxdg_decoration_manager_v1_interface;
    if (!strcmp(interface, "wp_viewporter")) return &wp_viewporter_interface;
    if (!strcmp(interface, "wp_fractional_scale_manager_v1")) return &wp_fractional_scale_manager_v1_interface;
    if (!strcmp(interface, "wp_presentation")) return &wp_presentation_interface;
    if (!strcmp(interface, "zwp_relative_pointer_manager_v1")) return &zwp_relative_pointer_manager_v1_interface;
    if (!strcmp(interface, "zwp_pointer_constraints_v1")) return &zwp_pointer_constraints_v1_interface;
    if (!strcmp(interface, "zwp_keyboard_shortcuts_inhibit_manager_v1")) return &zwp_keyboard_shortcuts_inhibit_manager_v1_interface;
    if (!strcmp(interface, "zwp_linux_dmabuf_v1")) return &zwp_linux_dmabuf_v1_interface;
    return NULL;
}

void *sensorium_wayland_bind(
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version)
{
    const struct wl_interface *description = description_named(interface);
    if (!description) {
        return NULL;
    }
    return wl_registry_bind(registry, name, description, version);
}

#else

void *sensorium_wayland_bind(
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version)
{
    (void)registry;
    (void)name;
    (void)interface;
    (void)version;
    return 0;
}

#endif
