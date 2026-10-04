#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Exact third stops anchored to one second. Limits come from activeFormat.
bool m7_shutter_range(double min_seconds, double max_seconds, int *first, int *last);
double m7_shutter_seconds(int index);
bool m7_shutter_nearest(double seconds, double min_seconds, double max_seconds,
                        int *index);
double m7_iso_from_slider(double position, double min_iso, double max_iso);

// Input: 8-bit luma, output: premultiplied RGBA green overlay. Separate buffers.
// threshold is normalized Sobel magnitude [0,1]; stride values are bytes.
// Returns false for invalid dimensions, strides, pointers or threshold.
bool m7_peaking(const uint8_t *luma, size_t width, size_t height, size_t stride,
                uint8_t *rgba, size_t rgba_stride, double threshold);
