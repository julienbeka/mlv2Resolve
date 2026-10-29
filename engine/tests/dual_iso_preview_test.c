/* SPDX-License-Identifier: GPL-3.0-or-later
 * Exercise the real preview path and histogram allocator; track histogram ownership.
 * Unused high-quality processing is removed by the linker (no FUSE or MLV needed).
 */
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include "histogram.h"
static int live_histograms;
static struct histogram *tracked_create(uint16_t white) {
    struct histogram *hist = hist_create(white);
    assert(hist && hist->data);
    live_histograms++;
    return hist;
}
static void tracked_destroy(struct histogram *hist) {
    assert(hist && live_histograms > 0);
    live_histograms--;
    hist_destroy(hist);
}
#define hist_create tracked_create
#define hist_destroy tracked_destroy
#include "../mlvfs/hdr.c"
#undef hist_create
#undef hist_destroy

int main(void) {
    struct frame_headers headers = {0};
    headers.rawi_hdr.xRes = 64;
    headers.rawi_hdr.yRes = 64;
    headers.rawi_hdr.raw_info.black_level = 512;
    headers.rawi_hdr.raw_info.white_level = 16383;
    uint16_t pixels[64 * 64];
    for (int i = 0; i < 64 * 64; i++) pixels[i] = 1024;
    for (int frame = 0; frame < 128; frame++) {
        assert(hdr_convert_data(&headers, pixels, 0, sizeof(pixels)) == 0);
        if (live_histograms != 0) {
            fprintf(stderr, "FAIL: frame %d retained %d histograms after rejected detection\n", frame, live_histograms);
            return 1;
        }
        for (int i = 0; i < 64 * 64; i++) assert(pixels[i] == 1024);
    }
    puts("PASS: 128 rejected preview frames release all histograms and preserve pixels");
    return 0;
}
