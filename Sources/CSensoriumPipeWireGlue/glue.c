#include "sensorium-pipewire-glue.h"

// PipeWire exists only on Linux; this file is empty elsewhere so a
// whole-package build on another platform still compiles.
#if defined(__linux__)

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h>
#include <spa/param/buffers.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>

// The cursor image sizes a producer may attach, as a meta size: the two
// header structs plus 32-bit pixels. A producer sends the smallest size that
// holds its current cursor, up to the largest offered here.
#define CURSOR_META_SIZE(w, h) \
    (sizeof(struct spa_meta_cursor) + sizeof(struct spa_meta_bitmap) + (w) * (h) * 4)

struct sensorium_pw_capture {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook core_listener;
    struct spa_hook stream_listener;

    uint32_t node_id;
    uint64_t serial;

    sensorium_pw_frame_callback frame_callback;
    sensorium_pw_state_callback state_callback;
    void *user_data;

    // The negotiated video format, valid once `has_format` is set. Read and
    // written on the loop thread only.
    struct spa_video_info_raw format;
    sensorium_pw_format format_kind;
    bool has_format;

    bool loop_started;
};

static pthread_once_t pipewire_init_once = PTHREAD_ONCE_INIT;

static void pipewire_init(void) {
    pw_init(NULL, NULL);
}

static void write_error(char *error, size_t error_size, const char *message) {
    if (error != NULL && error_size > 0) {
        snprintf(error, error_size, "%s", message);
    }
}

static sensorium_pw_format format_kind_for(enum spa_video_format format) {
    switch (format) {
    case SPA_VIDEO_FORMAT_BGRx: return SENSORIUM_PW_FORMAT_BGRX;
    case SPA_VIDEO_FORMAT_BGRA: return SENSORIUM_PW_FORMAT_BGRA;
    default: return SENSORIUM_PW_FORMAT_UNKNOWN;
    }
}

static void report_state(struct sensorium_pw_capture *capture, sensorium_pw_state state, const char *message) {
    if (capture->state_callback != NULL) {
        capture->state_callback(capture->user_data, state, message);
    }
}

static void on_core_error(void *data, uint32_t id, int seq, int res, const char *message) {
    struct sensorium_pw_capture *capture = data;
    // An error on the core itself (id 0) is the connection going away. An
    // error on another object is reported through that object's own state.
    if (id == PW_ID_CORE) {
        report_state(capture, SENSORIUM_PW_STATE_ERROR, message != NULL ? message : spa_strerror(res));
    }
}

static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS,
    .error = on_core_error,
};

static void on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    struct sensorium_pw_capture *capture = data;
    switch (state) {
    case PW_STREAM_STATE_ERROR:
        report_state(capture, SENSORIUM_PW_STATE_ERROR, error != NULL ? error : "the stream failed");
        break;
    case PW_STREAM_STATE_STREAMING:
        report_state(capture, SENSORIUM_PW_STATE_STREAMING, NULL);
        break;
    case PW_STREAM_STATE_PAUSED:
        report_state(capture, SENSORIUM_PW_STATE_PAUSED, NULL);
        break;
    default:
        report_state(capture, SENSORIUM_PW_STATE_CONNECTING, NULL);
        break;
    }
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    struct sensorium_pw_capture *capture = data;
    if (param == NULL || id != SPA_PARAM_Format) {
        return;
    }

    struct spa_video_info info;
    memset(&info, 0, sizeof(info));
    if (spa_format_parse(param, &info.media_type, &info.media_subtype) < 0 ||
        info.media_type != SPA_MEDIA_TYPE_video ||
        info.media_subtype != SPA_MEDIA_SUBTYPE_raw) {
        return;
    }
    spa_format_video_raw_parse(param, &info.info.raw);

    sensorium_pw_format kind = format_kind_for(info.info.raw.format);
    if (kind == SENSORIUM_PW_FORMAT_UNKNOWN) {
        report_state(capture, SENSORIUM_PW_STATE_ERROR, "the compositor chose a pixel format this host cannot read");
        return;
    }
    capture->format = info.info.raw;
    capture->format_kind = kind;
    capture->has_format = true;

    uint32_t stride = SPA_ROUND_UP_N(info.info.raw.size.width * 4, 4);
    uint32_t size = stride * info.info.raw.size.height;

    uint8_t buffer[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[3];

    params[0] = spa_pod_builder_add_object(&builder,
        SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(8, 2, 16),
        SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
        SPA_PARAM_BUFFERS_size, SPA_POD_Int(size),
        SPA_PARAM_BUFFERS_stride, SPA_POD_Int(stride),
        // Shared memory only: memory this process can map and read.
        SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
    params[1] = spa_pod_builder_add_object(&builder,
        SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
        SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
        SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));
    params[2] = spa_pod_builder_add_object(&builder,
        SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
        SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Cursor),
        SPA_PARAM_META_size, SPA_POD_CHOICE_RANGE_Int(
            CURSOR_META_SIZE(64, 64), CURSOR_META_SIZE(1, 1), CURSOR_META_SIZE(256, 256)));
    pw_stream_update_params(capture->stream, params, 3);
}

// Reads the cursor meta of one buffer into `frame`. Every offset the producer
// wrote is checked against the meta's own size before it is followed.
static void read_cursor(struct spa_buffer *buffer, sensorium_pw_frame *frame) {
    struct spa_meta *meta = spa_buffer_find_meta(buffer, SPA_META_Cursor);
    if (meta == NULL || meta->size < sizeof(struct spa_meta_cursor)) {
        return;
    }
    const struct spa_meta_cursor *cursor = meta->data;
    if (!spa_meta_cursor_is_valid(cursor)) {
        return;
    }
    frame->has_cursor = true;
    frame->cursor_visible = true;
    frame->cursor_x = cursor->position.x;
    frame->cursor_y = cursor->position.y;
    frame->cursor_hotspot_x = cursor->hotspot.x;
    frame->cursor_hotspot_y = cursor->hotspot.y;

    if (cursor->bitmap_offset < sizeof(struct spa_meta_cursor) ||
        (uint64_t)cursor->bitmap_offset + sizeof(struct spa_meta_bitmap) > meta->size) {
        return;
    }
    const struct spa_meta_bitmap *bitmap = SPA_PTROFF(cursor, cursor->bitmap_offset, struct spa_meta_bitmap);
    if (!spa_meta_bitmap_is_valid(bitmap)) {
        return;
    }
    if (bitmap->offset == 0) {
        // A bitmap with no image data is a hidden cursor.
        frame->cursor_visible = false;
        return;
    }
    sensorium_pw_format kind = format_kind_for((enum spa_video_format)bitmap->format);
    int32_t stride = bitmap->stride;
    uint32_t width = bitmap->size.width;
    uint32_t height = bitmap->size.height;
    uint64_t image_end = (uint64_t)cursor->bitmap_offset + bitmap->offset + (uint64_t)(stride > 0 ? stride : 0) * height;
    if (kind == SENSORIUM_PW_FORMAT_UNKNOWN || stride <= 0 || width == 0 || height == 0 ||
        bitmap->offset < sizeof(struct spa_meta_bitmap) || image_end > meta->size) {
        return;
    }
    frame->cursor_bitmap = SPA_PTROFF(bitmap, bitmap->offset, uint8_t);
    frame->cursor_width = width;
    frame->cursor_height = height;
    frame->cursor_stride = (uint32_t)stride;
    frame->cursor_format = kind;
}

static void on_process(void *data) {
    struct sensorium_pw_capture *capture = data;
    struct pw_buffer *pw_buffer;

    // Every buffer is delivered in order, none skipped: a cursor image is sent
    // once, on the buffer where it changes, and skipping that buffer would
    // lose it.
    while ((pw_buffer = pw_stream_dequeue_buffer(capture->stream)) != NULL) {
        struct spa_buffer *buffer = pw_buffer->buffer;
        sensorium_pw_frame frame;
        memset(&frame, 0, sizeof(frame));

        if (capture->has_format) {
            frame.width = capture->format.size.width;
            frame.height = capture->format.size.height;
            frame.format = capture->format_kind;
        }

        struct spa_meta_header *header = spa_buffer_find_meta_data(buffer, SPA_META_Header, sizeof(*header));
        if (header != NULL) {
            frame.presentation_time_ns = header->pts;
        }
        bool corrupted = header != NULL && (header->flags & SPA_META_HEADER_FLAG_CORRUPTED) != 0;

        if (buffer->n_datas > 0 && capture->has_format && !corrupted) {
            struct spa_data *plane = &buffer->datas[0];
            struct spa_chunk *chunk = plane->chunk;
            // A chunk of size zero is a buffer with no new picture, such as a
            // cursor-only update.
            if (plane->data != NULL && chunk != NULL && chunk->size > 0 &&
                (chunk->flags & SPA_CHUNK_FLAG_CORRUPTED) == 0 &&
                (plane->type == SPA_DATA_MemPtr || plane->type == SPA_DATA_MemFd)) {
                uint32_t stride = chunk->stride > 0 ? (uint32_t)chunk->stride : frame.width * 4;
                uint64_t needed = (uint64_t)chunk->offset + (uint64_t)stride * frame.height;
                if (stride >= frame.width * 4 && needed <= plane->maxsize) {
                    frame.pixels = SPA_PTROFF(plane->data, chunk->offset, uint8_t);
                    frame.stride = stride;
                }
            }
        }
        read_cursor(buffer, &frame);

        if ((frame.pixels != NULL || frame.has_cursor) && capture->frame_callback != NULL) {
            capture->frame_callback(capture->user_data, &frame);
        }
        pw_stream_queue_buffer(capture->stream, pw_buffer);
    }
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .param_changed = on_param_changed,
    .process = on_process,
};

sensorium_pw_capture *sensorium_pw_capture_create(
    int fd,
    uint32_t node_id,
    uint64_t serial,
    sensorium_pw_frame_callback frame_callback,
    sensorium_pw_state_callback state_callback,
    void *user_data,
    char *error,
    size_t error_size) {
    pthread_once(&pipewire_init_once, pipewire_init);

    struct sensorium_pw_capture *capture = calloc(1, sizeof(*capture));
    if (capture == NULL) {
        close(fd);
        write_error(error, error_size, "out of memory");
        return NULL;
    }
    capture->node_id = node_id;
    capture->serial = serial;
    capture->frame_callback = frame_callback;
    capture->state_callback = state_callback;
    capture->user_data = user_data;

    capture->loop = pw_thread_loop_new("sensorium-capture", NULL);
    if (capture->loop == NULL) {
        close(fd);
        write_error(error, error_size, "the PipeWire loop could not be created");
        goto fail;
    }
    capture->context = pw_context_new(pw_thread_loop_get_loop(capture->loop), NULL, 0);
    if (capture->context == NULL) {
        close(fd);
        write_error(error, error_size, "the PipeWire context could not be created");
        goto fail;
    }
    // The core owns `fd` from here, and closes it when it is disconnected.
    capture->core = pw_context_connect_fd(capture->context, fd, NULL, 0);
    if (capture->core == NULL) {
        close(fd);
        write_error(error, error_size, "the PipeWire remote could not be connected");
        goto fail;
    }
    pw_core_add_listener(capture->core, &capture->core_listener, &core_events, capture);

    struct pw_properties *properties = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Video",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Screen",
        NULL);
    if (properties != NULL && serial != 0) {
        char target[32];
        snprintf(target, sizeof(target), "%llu", (unsigned long long)serial);
        pw_properties_set(properties, PW_KEY_TARGET_OBJECT, target);
    }
    // The stream takes the properties, and frees them if it cannot be made.
    capture->stream = pw_stream_new(capture->core, "sensorium-capture", properties);
    if (capture->stream == NULL) {
        write_error(error, error_size, "the PipeWire stream could not be created");
        goto fail;
    }
    pw_stream_add_listener(capture->stream, &capture->stream_listener, &stream_events, capture);
    return capture;

fail:
    sensorium_pw_capture_destroy(capture);
    return NULL;
}

int sensorium_pw_capture_start(sensorium_pw_capture *capture) {
    int result = pw_thread_loop_start(capture->loop);
    if (result < 0) {
        return result;
    }
    capture->loop_started = true;

    uint8_t buffer[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    struct spa_rectangle default_size = SPA_RECTANGLE(1920, 1080);
    struct spa_rectangle minimum_size = SPA_RECTANGLE(1, 1);
    struct spa_rectangle maximum_size = SPA_RECTANGLE(16384, 16384);
    // A rate of 0/1 is "variable", which is what a screen producer offers.
    struct spa_fraction default_rate = SPA_FRACTION(60, 1);
    struct spa_fraction minimum_rate = SPA_FRACTION(0, 1);
    struct spa_fraction maximum_rate = SPA_FRACTION(1000, 1);
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(&builder,
        SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(3,
            SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA),
        SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&default_size, &minimum_size, &maximum_size),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&default_rate, &minimum_rate, &maximum_rate));

    pw_thread_loop_lock(capture->loop);
    // With a serial the target is named by the property set at creation, and
    // the node id is left to PipeWire.
    result = pw_stream_connect(
        capture->stream,
        PW_DIRECTION_INPUT,
        capture->serial != 0 ? PW_ID_ANY : capture->node_id,
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
        params, 1);
    pw_thread_loop_unlock(capture->loop);
    return result;
}

void sensorium_pw_capture_destroy(sensorium_pw_capture *capture) {
    if (capture == NULL) {
        return;
    }
    if (capture->loop != NULL) {
        pw_thread_loop_lock(capture->loop);
        if (capture->stream != NULL) {
            pw_stream_destroy(capture->stream);
            capture->stream = NULL;
        }
        if (capture->core != NULL) {
            spa_hook_remove(&capture->core_listener);
            pw_core_disconnect(capture->core);
            capture->core = NULL;
        }
        pw_thread_loop_unlock(capture->loop);
        if (capture->loop_started) {
            pw_thread_loop_stop(capture->loop);
        }
        if (capture->context != NULL) {
            pw_context_destroy(capture->context);
        }
        pw_thread_loop_destroy(capture->loop);
    }
    free(capture);
}

int sensorium_pw_capture_enable_dmabuf(sensorium_pw_capture *capture) {
    (void)capture;
    return -ENOTSUP;
}

#endif
