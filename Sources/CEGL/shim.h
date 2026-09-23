#ifndef SENSORIUM_CEGL_SHIM_H
#define SENSORIUM_CEGL_SHIM_H

#include <stddef.h>
#include <stdint.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

// The three entry points a zero-copy frame needs are extensions, so they are
// not linkable symbols: they have to be resolved through eglGetProcAddress at
// run time. A function pointer resolved that way is awkward to call from
// Swift, so each is wrapped here instead, resolved once per translation unit.

static inline EGLImageKHR sensorium_egl_create_dma_buf_image(
    EGLDisplay display,
    const EGLint *attributes)
{
    static PFNEGLCREATEIMAGEKHRPROC create;
    if (!create) {
        create = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    }
    if (!create) {
        return EGL_NO_IMAGE_KHR;
    }
    return create(display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attributes);
}

static inline EGLBoolean sensorium_egl_destroy_image(EGLDisplay display, EGLImageKHR image)
{
    static PFNEGLDESTROYIMAGEKHRPROC destroy;
    if (!destroy) {
        destroy = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    }
    if (!destroy || image == EGL_NO_IMAGE_KHR) {
        return EGL_FALSE;
    }
    return destroy(display, image);
}

static inline void sensorium_gl_bind_egl_image_to_texture(EGLImageKHR image)
{
    static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC bind;
    if (!bind) {
        bind = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    }
    if (!bind) {
        return;
    }
    bind(GL_TEXTURE_2D, (GLeglImageOES)image);
}

// `EGL_NO_IMAGE_KHR` and `EGL_NO_CONTEXT` are casts of an integer literal to a
// pointer, which the Swift importer cannot read as constants.
static inline EGLImageKHR sensorium_egl_no_image(void) { return EGL_NO_IMAGE_KHR; }

static inline EGLContext sensorium_egl_no_context(void) { return EGL_NO_CONTEXT; }

static inline EGLSurface sensorium_egl_no_surface(void) { return EGL_NO_SURFACE; }

static inline EGLDisplay sensorium_egl_no_display(void) { return EGL_NO_DISPLAY; }

// `EGLNativeDisplayType` and `EGLNativeWindowType` are whichever types the
// platform's own EGL headers picked, which is not something Swift can name.
// A raw pointer is what both of them are on Wayland.

static inline EGLDisplay sensorium_egl_display_for_native(void *native)
{
    return eglGetDisplay((EGLNativeDisplayType)native);
}

static inline EGLSurface sensorium_egl_create_window_surface(
    EGLDisplay display,
    EGLConfig config,
    void *native_window)
{
    return eglCreateWindowSurface(display, config, (EGLNativeWindowType)(uintptr_t)native_window, NULL);
}

#endif
