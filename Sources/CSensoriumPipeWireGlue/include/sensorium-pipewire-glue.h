#ifndef SENSORIUM_PIPEWIRE_GLUE_H
#define SENSORIUM_PIPEWIRE_GLUE_H

// A plain C face on a PipeWire video-capture stream. PipeWire's stream
// callbacks, format pods and buffer metadata are macros and inline functions
// Swift cannot import, so this file is the whole surface the Swift side sees.
// Nothing here exposes a PipeWire type.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The pixel layouts the stream is offered. Both are 32 bits per pixel, so a
// consumer treats the alpha byte of BGRA as padding.
typedef enum {
    SENSORIUM_PW_FORMAT_UNKNOWN = 0,
    SENSORIUM_PW_FORMAT_BGRX = 1,
    SENSORIUM_PW_FORMAT_BGRA = 2
} sensorium_pw_format;

typedef enum {
    SENSORIUM_PW_STATE_CONNECTING = 0,
    // The format was negotiated; frames follow.
    SENSORIUM_PW_STATE_STREAMING = 1,
    SENSORIUM_PW_STATE_PAUSED = 2,
    // The stream or the connection failed. `message` says why.
    SENSORIUM_PW_STATE_ERROR = 3
} sensorium_pw_state;

// One delivered buffer. Every pointer is valid only for the duration of the
// callback that receives it.
typedef struct {
    // Pixels. Null for a buffer that carries only a cursor update.
    const uint8_t *pixels;
    uint32_t width;
    uint32_t height;
    // Bytes per row, taken from the buffer's own chunk.
    uint32_t stride;
    sensorium_pw_format format;
    // Presentation time in nanoseconds on PipeWire's monotonic clock, or 0
    // when the producer attached none.
    int64_t presentation_time_ns;

    // Cursor metadata, present only when the producer sent any.
    bool has_cursor;
    // False when the producer sent a bitmap with no image data, which hides
    // the cursor. True otherwise, including when the cursor image is
    // unchanged and only its position is new.
    bool cursor_visible;
    int32_t cursor_x;
    int32_t cursor_y;
    int32_t cursor_hotspot_x;
    int32_t cursor_hotspot_y;
    // The cursor image, or null when this update carries a position only.
    const uint8_t *cursor_bitmap;
    uint32_t cursor_width;
    uint32_t cursor_height;
    uint32_t cursor_stride;
    sensorium_pw_format cursor_format;
} sensorium_pw_frame;

typedef void (*sensorium_pw_frame_callback)(void *user_data, const sensorium_pw_frame *frame);
typedef void (*sensorium_pw_state_callback)(void *user_data, sensorium_pw_state state, const char *message);

typedef struct sensorium_pw_capture sensorium_pw_capture;

// Connects to the PipeWire remote on `fd`, which the capture takes ownership
// of and closes when it is destroyed or when creation fails, and prepares a
// stream for `node_id`. When `serial` is not 0 the stream is targeted by that
// object serial, which PipeWire never reuses. Nothing is delivered until
// `sensorium_pw_capture_start`. Returns null on failure and writes a reason
// into `error` (at most `error_size` bytes).
sensorium_pw_capture *sensorium_pw_capture_create(
    int fd,
    uint32_t node_id,
    uint64_t serial,
    sensorium_pw_frame_callback frame_callback,
    sensorium_pw_state_callback state_callback,
    void *user_data,
    char *error,
    size_t error_size);

// Starts the PipeWire loop thread and connects the stream. Callbacks run on
// that thread, never the caller's. Returns 0 or a negative errno.
int sensorium_pw_capture_start(sensorium_pw_capture *capture);

// Stops the loop thread and releases everything, including the descriptor.
// Once it returns, no callback is running and none will run again.
void sensorium_pw_capture_destroy(sensorium_pw_capture *capture);

// The DMA-BUF entry point. Frames are shared memory today; importing GPU
// buffers into the encoder is not built, so this always returns -ENOTSUP.
int sensorium_pw_capture_enable_dmabuf(sensorium_pw_capture *capture);

#ifdef __cplusplus
}
#endif

#endif
