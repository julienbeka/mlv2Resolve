/*
 * Regression test: the LJ92 decoder must reject truncated / corrupt Magic Lantern lossless
 * frames with an error instead of reading past the end of its input.
 *
 * Usage: lj92_truncation_test <clip.MLV> [<ref.u16>]
 * Takes frame 0's VIDF payload from the clip and decodes it from a buffer that ends exactly at a
 * PROT_NONE guard page (any read past the end crashes the test):
 *   - intact payload            -> LJ92_ERROR_NONE (and, with <ref.u16>, identical to the reference)
 *   - truncated to 98% and 50%  -> error
 *   - every length 0..2048 bytes (header region) and every 1/64 of the payload -> error, no crash
 *   - intact payload with a corrupted DHT / SOF / SOS length -> no crash
 * Build: make -f Makefile.arm64 lj92-test (from engine/). Exit 0 = pass.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "lj92.h"

static uint8_t *payload;
static size_t payload_len;
static int failures;

static int read_frame0(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 0; }
    uint8_t hdr[32];
    long pos = 0;
    while (fseek(f, pos, SEEK_SET) == 0 && fread(hdr, 1, 32, f) == 32) {
        uint32_t size; memcpy(&size, hdr + 4, 4);
        if (size < 16) break;
        if (!memcmp(hdr, "VIDF", 4)) {
            uint32_t frame, space; memcpy(&frame, hdr + 16, 4); memcpy(&space, hdr + 28, 4);
            if (frame == 0) {
                payload_len = size - 32 - space;
                payload = malloc(payload_len);
                fseek(f, pos + 32 + space, SEEK_SET);
                int ok = payload && fread(payload, 1, payload_len, f) == payload_len;
                fclose(f);
                return ok;
            }
        }
        pos += size;
    }
    fclose(f);
    fprintf(stderr, "frame 0 VIDF not found in %s\n", path);
    return 0;
}

/* Decode the first len bytes of src from a buffer whose last byte sits right before a guard page. */
static int decode_guarded(const uint8_t *src, size_t len, uint16_t **out, int *out_pixels)
{
    size_t page = (size_t)getpagesize();
    size_t span = (len + page - 1) / page * page;
    uint8_t *base = mmap(NULL, span + page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) { perror("mmap"); exit(2); }
    if (mprotect(base + span, page, PROT_NONE)) { perror("mprotect"); exit(2); }
    uint8_t *buf = base + span - len;
    memcpy(buf, src, len);

    lj92 h;
    int w = 0, ht = 0, bits = 0, comp = 0;
    int ret = lj92_open(&h, buf, (int)len, &w, &ht, &bits, &comp);
    if (ret == LJ92_ERROR_NONE) {
        int n = w * ht * comp;
        uint16_t *img = malloc((size_t)n * sizeof(uint16_t));
        ret = img ? lj92_decode(h, img, n, 0, NULL, 0) : LJ92_ERROR_NO_MEMORY;
        lj92_close(h);
        if (out && ret == LJ92_ERROR_NONE) { *out = img; *out_pixels = n; }
        else free(img);
    }
    munmap(base, span + page);
    return ret;
}

static void expect_error(const uint8_t *src, size_t len, const char *what)
{
    int ret = decode_guarded(src, len, NULL, NULL);
    if (ret == LJ92_ERROR_NONE) {
        printf("FAIL: %s (%zu bytes) decoded without error\n", what, len);
        failures++;
    }
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <clip.MLV> [<ref.u16>]\n", argv[0]); return 2; }
    setvbuf(stdout, NULL, _IONBF, 0); // keep output if a guard-page fault kills the process
    if (!read_frame0(argv[1])) return 2;
    printf("frame 0 payload: %zu bytes\n", payload_len);

    uint16_t *img = NULL;
    int n = 0;
    int ret = decode_guarded(payload, payload_len, &img, &n);
    printf("intact: ret=%d pixels=%d\n", ret, n);
    if (ret != LJ92_ERROR_NONE) failures++;
    if (argc > 2 && img) {
        FILE *rf = fopen(argv[2], "rb");
        uint16_t *ref = malloc((size_t)n * sizeof(uint16_t));
        size_t got = rf && ref ? fread(ref, sizeof(uint16_t), (size_t)n + 1, rf) : 0;
        int same = got == (size_t)n && !memcmp(ref, img, (size_t)n * sizeof(uint16_t));
        printf("intact vs %s: %s\n", argv[2], same ? "identical" : "DIFFERENT");
        if (!same) failures++;
        if (rf) fclose(rf);
        free(ref);
    }
    free(img);

    ret = decode_guarded(payload, payload_len * 98 / 100, NULL, NULL);
    printf("truncated 98%%: ret=%d\n", ret);
    if (ret == LJ92_ERROR_NONE) failures++;
    ret = decode_guarded(payload, payload_len / 2, NULL, NULL);
    printf("truncated 50%%: ret=%d\n", ret);
    if (ret == LJ92_ERROR_NONE) failures++;

    for (size_t len = 0; len <= 2048 && len < payload_len; len++) expect_error(payload, len, "header-region cut");
    for (int k = 1; k < 64; k++) expect_error(payload, payload_len * k / 64, "fractional cut");
    printf("sweep: cuts at 0..2048 bytes and k/64 of the payload done\n");

    /* corrupt header lengths / counts: must not crash (result may be an error or garbage pixels) */
    uint8_t *bad = malloc(payload_len);
    static const uint8_t markers[] = { 0xc4, 0xc3, 0xda };
    for (int m = 0; m < 3; m++) {
        uint8_t *p = memchr(payload, 0xff, payload_len);
        while (p && p + 1 < payload + payload_len && p[1] != markers[m])
            p = memchr(p + 1, 0xff, (size_t)(payload + payload_len - p - 1));
        if (!p) continue;
        size_t at = (size_t)(p - payload) + 2;
        for (int v = 0; v < 4; v++) {
            static const uint8_t vals[][2] = { {0, 0}, {0xff, 0xff}, {0, 2}, {0x7f, 0xff} };
            memcpy(bad, payload, payload_len);
            bad[at] = vals[v][0]; bad[at + 1] = vals[v][1];
            decode_guarded(bad, payload_len, NULL, NULL);
            memcpy(bad, payload, payload_len);
            bad[at + 7 < payload_len ? at + 7 : at] ^= 0xff; // component count / table data
            decode_guarded(bad, payload_len, NULL, NULL);
        }
    }
    free(bad);
    printf("corrupt-header cases: no crash\n");

    printf(failures ? "FAILED (%d)\n" : "PASS\n", failures);
    return failures ? 1 : 0;
}
