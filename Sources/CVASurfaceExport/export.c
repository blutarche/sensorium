#include "sensorium-va-surface-export.h"

#if defined(__linux__)

#include <string.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drmcommon.h>

int sensorium_export_va_surface(void *va_display, unsigned int surface, SensoriumExportedSurface *exported)
{
    memset(exported, 0, sizeof *exported);

    VADRMPRIMESurfaceDescriptor descriptor;
    VAStatus status = vaExportSurfaceHandle(
        (VADisplay)va_display,
        (VASurfaceID)surface,
        VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
        VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS,
        &descriptor);
    if (status != VA_STATUS_SUCCESS) {
        return status;
    }

    // Two layers, luma and interleaved chroma at half resolution in both
    // directions. A surface laid out any other way would need a shader this
    // presenter does not have, so it goes down the software path instead.
    if (descriptor.num_layers != 2 || descriptor.num_objects > SENSORIUM_EXPORTED_SURFACE_MAX_LAYERS) {
        for (uint32_t i = 0; i < descriptor.num_objects; i++) {
            close(descriptor.objects[i].fd);
        }
        return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    }

    exported->width = descriptor.width;
    exported->height = descriptor.height;
    exported->layer_count = descriptor.num_layers;
    for (uint32_t layer = 0; layer < descriptor.num_layers; layer++) {
        uint32_t object = descriptor.layers[layer].object_index[0];
        if (object >= descriptor.num_objects) {
            for (uint32_t i = 0; i < descriptor.num_objects; i++) {
                close(descriptor.objects[i].fd);
            }
            return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
        }
        exported->layers[layer].drm_format = descriptor.layers[layer].drm_format;
        exported->layers[layer].width = layer == 0 ? descriptor.width : descriptor.width / 2;
        exported->layers[layer].height = layer == 0 ? descriptor.height : descriptor.height / 2;
        exported->layers[layer].fd = descriptor.objects[object].fd;
        exported->layers[layer].offset = descriptor.layers[layer].offset[0];
        exported->layers[layer].pitch = descriptor.layers[layer].pitch[0];
        exported->layers[layer].modifier = descriptor.objects[object].drm_format_modifier;
    }
    exported->fd_count = descriptor.num_objects;
    for (uint32_t i = 0; i < descriptor.num_objects; i++) {
        exported->fds[i] = descriptor.objects[i].fd;
    }
    return 0;
}

void sensorium_close_exported_surface(SensoriumExportedSurface *exported)
{
    for (uint32_t i = 0; i < exported->fd_count; i++) {
        if (exported->fds[i] >= 0) {
            close(exported->fds[i]);
            exported->fds[i] = -1;
        }
    }
    exported->fd_count = 0;
}

#else

int sensorium_export_va_surface(void *va_display, unsigned int surface, SensoriumExportedSurface *exported)
{
    (void)va_display;
    (void)surface;
    (void)exported;
    return -1;
}

void sensorium_close_exported_surface(SensoriumExportedSurface *exported) { (void)exported; }

#endif
