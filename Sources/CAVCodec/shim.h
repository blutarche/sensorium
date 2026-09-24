#ifndef SENSORIUM_CAVCODEC_SHIM_H
#define SENSORIUM_CAVCODEC_SHIM_H

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>

// The libavcodec return codes a decode loop has to tell apart are
// function-like macros over errno values, and a macro is invisible to the
// Swift importer. These wrappers are the only way to compare against them
// from Swift.
static inline int sensorium_averror_again(void) { return AVERROR(EAGAIN); }

static inline int sensorium_averror_eof(void) { return AVERROR_EOF; }

static inline int sensorium_averror_invalid_data(void) { return AVERROR_INVALIDDATA; }

// Extradata must be allocated with this many spare bytes past its declared
// size, so an optimised bitstream reader may read past the end without
// leaving the allocation.
static inline int sensorium_av_input_buffer_padding_size(void)
{
    return AV_INPUT_BUFFER_PADDING_SIZE;
}

#endif
