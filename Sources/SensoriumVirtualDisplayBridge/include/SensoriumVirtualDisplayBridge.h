#ifndef SENSORIUM_VIRTUAL_DISPLAY_BRIDGE_H
#define SENSORIUM_VIRTUAL_DISPLAY_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Creates one virtual display called `name` -- what a person at this machine
/// sees it named in their display settings. Creates nothing and returns NULL
/// if `name` is NULL or is not valid UTF-8.
void *sensorium_create_virtual_display(const char *name,
                                        int32_t logical_width,
                                        int32_t logical_height,
                                        int32_t pixel_width,
                                        int32_t pixel_height,
                                        uint32_t vendor_id,
                                        uint32_t product_id,
                                        uint32_t serial_number,
                                        uint32_t *display_id);

/// Whether the undocumented runtime classes this bridge creates a display
/// with resolve on this machine at all. Distinguishes hardware that can never
/// host from a creation macOS refused for some other reason -- an identity
/// already taken by a display an earlier host left behind, say -- which the
/// caller can retry under a different identity.
int sensorium_virtual_display_runtime_available(void);

/// Gives up the display before returning, rather than leaving it to an
/// autorelease pool the caller may never drain. macOS removes the display
/// itself on its own schedule after that.
void sensorium_destroy_virtual_display(void *display_handle);

int sensorium_virtual_display_get_metrics(void *display_handle,
                                           uint32_t *max_pixels_wide,
                                           uint32_t *max_pixels_high,
                                           uint32_t *hi_dpi_scale);

#ifdef __cplusplus
}
#endif

#endif
