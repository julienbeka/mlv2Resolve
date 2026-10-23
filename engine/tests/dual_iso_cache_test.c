/*
 * Unit test: live dual ISO switching by signals and the image buffer cache.
 *
 * - SIGUSR2 / SIGUSR1 switch the mode (1 <-> 2), bump the generation, keep the process alive.
 * - a cached buffer is reused while the mode is unchanged;
 * - after a switch the cached buffer is not served: the frame callback runs again in the new mode;
 * - a buffer still held (in use) across a switch is not freed under its holder.
 *
 * Usage: make -C engine -f Makefile.arm64 dual-iso-cache-test
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include "resource_manager.h"
#include "dual_iso_switch.h"

/* index.c chunk helpers referenced by resource_manager.c; unused here */
FILE **load_chunks(const char *path, uint32_t *chunk_count) { (void)path; *chunk_count = 0; return NULL; }
void close_chunks(FILE **chunk_files, uint32_t chunk_count) { (void)chunk_files; (void)chunk_count; }

static int failures = 0;
static int decode_calls = 0;
static int last_decode_mode = -1;

#define CHECK(cond, ...) do { if (cond) { printf("ok: " __VA_ARGS__); printf("\n"); } \
                              else { printf("FAIL: " __VA_ARGS__); printf("\n"); failures++; } } while (0)

/* stands in for process_frame: records the mode the frame is decoded in */
static int fake_decode(struct image_buffer *b)
{
    decode_calls++;
    last_decode_mode = dual_iso_mode();
    b->size = 16;
    b->data = malloc(b->size);
    b->header = malloc(4);
    b->header_size = 4;
    if (!b->data || !b->header) return 0;
    memset(b->data, last_decode_mode, b->size);
    return 1;
}

static struct image_buffer *get(const char *path)
{
    int created = 0;
    return get_or_create_image_buffer(path, &fake_decode, &created);
}

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *dng = "/clip/frame_000000.dng";

    dual_iso_switch_init(1);
    CHECK(dual_iso_mode() == 1, "initial mode 1");
    unsigned g0 = dual_iso_generation();

    struct image_buffer *a = get(dng);
    CHECK(a && decode_calls == 1 && last_decode_mode == 1, "first read decodes in mode 1 (calls=%d)", decode_calls);
    release_image_buffer_by_path(dng);
    struct image_buffer *a2 = get(dng);
    CHECK(a2 == a && decode_calls == 1, "same mode: cached buffer reused (calls=%d)", decode_calls);
    release_image_buffer_by_path(dng);

    /* switch to mode 2 */
    kill(getpid(), SIGUSR2);
    CHECK(dual_iso_poll() == 1, "SIGUSR2 applied by the poll (process alive)");
    CHECK(dual_iso_mode() == 2 && dual_iso_generation() == g0 + 1, "mode 2, generation bumped");
    struct image_buffer *b = get(dng);
    CHECK(b && decode_calls == 2 && last_decode_mode == 2, "after switch: decoded again in mode 2 (calls=%d)", decode_calls);
    CHECK(b && ((uint8_t *)b->data)[0] == 2, "served data is the mode 2 decode");

    /* hold b across the next switch (open file handle): it must survive the purge */
    kill(getpid(), SIGUSR1);
    struct image_buffer *c = get(dng); /* applies the pending SIGUSR1 itself, no explicit poll */
    CHECK(dual_iso_mode() == 1, "SIGUSR1 -> mode 1 (applied lazily at lookup)");
    CHECK(c && c != b && decode_calls == 3 && last_decode_mode == 1, "after switch back: decoded again in mode 1 (calls=%d)", decode_calls);
    CHECK(((uint8_t *)b->data)[0] == 2, "held stale buffer not freed under its holder");

    /* same mode again: no change, no new generation */
    unsigned g = dual_iso_generation();
    kill(getpid(), SIGUSR1);
    CHECK(dual_iso_poll() == 0 && dual_iso_generation() == g, "repeated SIGUSR1: no change");
    release_image_buffer_by_path(dng);
    struct image_buffer *c2 = get(dng);
    CHECK(c2 == c && decode_calls == 3, "cache reused again after repeated signal (calls=%d)", decode_calls);
    release_image_buffer_by_path(dng);

    free_all_image_buffers();
    printf("%d failures\n", failures);
    return failures ? 1 : 0;
}
