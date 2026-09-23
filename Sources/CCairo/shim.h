#ifndef SENSORIUM_CCAIRO_SHIM_H
#define SENSORIUM_CCAIRO_SHIM_H

#include <cairo/cairo.h>
#include <pango/pango.h>
#include <pango/pangocairo.h>

// Pango states text sizes in its own fixed-point units, and the conversion is
// a C macro, which is not something Swift can import. The two wrappers below
// are those macros and nothing else, so the Swift side works in whole points
// and the arithmetic happens here.

static inline int sensorium_pango_units_from_points(double points) {
    return (int)(points * PANGO_SCALE);
}

static inline double sensorium_pango_points_from_units(int units) {
    return (double)units / (double)PANGO_SCALE;
}

#endif
