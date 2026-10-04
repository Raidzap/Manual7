#include "M7Math.h"
#include <limits.h>
#include <math.h>
#include <string.h>

static bool valid_range(double lo, double hi) {
    return isfinite(lo) && isfinite(hi) && lo > 0 && hi >= lo;
}

bool m7_shutter_range(double lo, double hi, int *first, int *last) {
    if (!first || !last || !valid_range(lo, hi)) return false;
    double a = ceil(3.0 * log2(lo)), b = floor(3.0 * log2(hi));
    if (a < INT_MIN || a > INT_MAX || b < INT_MIN || b > INT_MAX) return false;
    int low = (int)a, high = (int)b;
    // Correct floating-point rounding around exact powers, without adding
    // off-grid clamped endpoints that would break the third-stop interval.
    while (low > INT_MIN && m7_shutter_seconds(low - 1) >= lo) --low;
    while (m7_shutter_seconds(low) < lo && low < INT_MAX) ++low;
    while (high < INT_MAX && m7_shutter_seconds(high + 1) <= hi) ++high;
    while (m7_shutter_seconds(high) > hi && high > INT_MIN) --high;
    if (low > high) return false;
    *first = low; *last = high;
    return true;
}

double m7_shutter_seconds(int index) { return exp2((double)index / 3.0); }

bool m7_shutter_nearest(double seconds, double lo, double hi, int *index) {
    int first, last;
    if (!index || !isfinite(seconds) || seconds <= 0 ||
        !m7_shutter_range(lo, hi, &first, &last)) return false;
    double selected = round(3.0 * log2(seconds));
    *index = (int)fmax(first, fmin(last, selected));
    return true;
}

double m7_iso_from_slider(double position, double lo, double hi) {
    if (!valid_range(lo, hi) || !isfinite(position)) return NAN;
    position = fmax(0, fmin(1, position));
    return fmax(lo, fmin(hi, exp(log(lo) + position * (log(hi) - log(lo)))));
}

bool m7_peaking(const uint8_t *p, size_t w, size_t h, size_t stride,
                uint8_t *out, size_t out_stride, double threshold) {
    if (!p || !out || w < 3 || h < 3 || w > SIZE_MAX / 4 ||
        stride < w || out_stride < 4 * w || h > SIZE_MAX / stride ||
        h > SIZE_MAX / out_stride || !isfinite(threshold) ||
        threshold < 0 || threshold > 1) return false;
    for (size_t y = 0; y < h; ++y) memset(out + y * out_stride, 0, 4 * w);
    // Maximum L1 Sobel magnitude for bounded 8-bit samples is 6*255.
    double limit = threshold * 1530.0;
    for (size_t y = 1; y + 1 < h; ++y) {
        const uint8_t *a = p + (y - 1) * stride;
        const uint8_t *b = p + y * stride;
        const uint8_t *c = p + (y + 1) * stride;
        for (size_t x = 1; x + 1 < w; ++x) {
            int gx = -a[x-1] + a[x+1] - 2*b[x-1] + 2*b[x+1] - c[x-1] + c[x+1];
            int gy = -a[x-1] - 2*a[x] - a[x+1] + c[x-1] + 2*c[x] + c[x+1];
            double magnitude = fabs((double)gx) + fabs((double)gy);
            if (magnitude > limit) {
                size_t at = y * out_stride + 4 * x;
                out[at + 1] = 210; out[at + 3] = 210;
            }
        }
    }
    return true;
}
