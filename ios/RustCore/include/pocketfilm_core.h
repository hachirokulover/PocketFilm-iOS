#ifndef POCKETFILM_CORE_H
#define POCKETFILM_CORE_H

#include "spektrafilm/spk_engine.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    double width;
    double height;
} pf_image_size;

int64_t pf_processing_edge(int64_t max_edge, bool border, bool preview);
double pf_compression_quality(double quality);
pf_image_size pf_resized_size(double width, double height, int64_t max_edge);

// Both functions borrow their input strings. Free returned strings using
// pf_free_string. A successful render hands the caller a retained Metal texture.
char* pf_engine_delta(const uint8_t* data, size_t length, bool preview, const char* edge_text);
void* pf_render_texture(spk_engine* engine, void* buffer, uint32_t width, uint32_t height,
                        const uint8_t* data, size_t length, bool preview, const char* edge_text,
                        char** out_error);
void pf_free_string(char* value);

#endif
