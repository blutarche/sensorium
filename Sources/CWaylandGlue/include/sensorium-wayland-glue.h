#ifndef SENSORIUM_WAYLAND_GLUE_H
#define SENSORIUM_WAYLAND_GLUE_H

#include <stdint.h>

struct wl_registry;

// Binds one advertised global by the interface name the registry announced it
// under.
//
// `wl_registry_bind` needs the address of the interface description
// generated for that protocol, and a proxy keeps that address for as long as
// it lives. Swift has no way to hand over the address of a C global and
// promise it stays put, so the lookup from name to description happens here,
// in the same translation unit the descriptions are linked into.
//
// Returns NULL for an interface this viewer does not speak, which is most of
// what a compositor advertises.
void *sensorium_wayland_bind(
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version);

#endif
