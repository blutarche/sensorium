#ifndef SENSORIUM_VA_SURFACE_EXPORT_H
#define SENSORIUM_VA_SURFACE_EXPORT_H

#include <stdint.h>

#define SENSORIUM_EXPORTED_SURFACE_MAX_LAYERS 4

// One plane of an exported surface, in exactly the terms an EGL dma-buf
// import needs. The descriptor VA-API fills uses nested anonymous structs and
// fixed-size arrays, which are unreadable from Swift; this is the same
// information, flattened.
typedef struct {
    uint32_t drm_format;
    uint32_t width;
    uint32_t height;
    int fd;
    uint32_t offset;
    uint32_t pitch;
    uint64_t modifier;
} SensoriumExportedSurfaceLayer;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t layer_count;
    SensoriumExportedSurfaceLayer layers[SENSORIUM_EXPORTED_SURFACE_MAX_LAYERS];
    // The descriptors this export owns. Closed by
    // `sensorium_close_exported_surface`, never by the caller one at a time:
    // two layers can share one object.
    int fds[SENSORIUM_EXPORTED_SURFACE_MAX_LAYERS];
    uint32_t fd_count;
} SensoriumExportedSurface;

// Exports one VA-API surface as DRM PRIME descriptors, one layer per plane.
// Returns 0 on success, or the VA status code otherwise. Only 4:2:0 two-plane
// surfaces are exported; anything else is refused, because the presenter has
// no shader for it.
int sensorium_export_va_surface(void *va_display, unsigned int surface, SensoriumExportedSurface *exported);

// Closes every descriptor a successful export produced. Called once the GPU
// has finished reading the images imported from them.
void sensorium_close_exported_surface(SensoriumExportedSurface *exported);

#endif
