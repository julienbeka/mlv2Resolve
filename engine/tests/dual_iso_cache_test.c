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
static size_t frame_bytes = 16;

#define CHECK(cond, ...) do { if (cond) { printf("ok: " __VA_ARGS__); printf("\n"); } \
                              else { printf("FAIL: " __VA_ARGS__); printf("\n"); failures++; } } while (0)

/* stands in for process_frame: records the mode the frame is decoded in */
static int fake_decode(struct image_buffer *b)
{
    decode_calls++;
    last_decode_mode = b->dual_iso;
    b->size = frame_bytes;
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

/* reads every byte of a buffer's data: a use-after-free crashes under Guard Malloc / ASan */
static int data_mode(struct image_buffer *b)
{
    int v = ((volatile uint8_t *)b->data)[0];
    for (size_t i = 1; i < b->size; i++) if (((volatile uint8_t *)b->data)[i] != v) return -1;
    return v;
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
    release_image_buffer(a);
    struct image_buffer *a2 = get(dng);
    CHECK(a2 == a && decode_calls == 1, "same mode: cached buffer reused (calls=%d)", decode_calls);
    release_image_buffer(a2);
    CHECK(get_image_buffer_ref_count(a) == 0, "balanced acquire/release -> ref 0");

    /* switch to mode 2 */
    kill(getpid(), SIGUSR2);
    CHECK(dual_iso_poll() == 1, "SIGUSR2 applied by the poll (process alive)");
    CHECK(dual_iso_mode() == 2 && dual_iso_generation() == g0 + 1, "mode 2, generation bumped");
    struct image_buffer *b = get(dng);
    CHECK(b && decode_calls == 2 && last_decode_mode == 2, "after switch: decoded again in mode 2 (calls=%d)", decode_calls);
    CHECK(b && data_mode(b) == 2, "served data is the mode 2 decode");

    /* hold b across the next switch (open file handle): it must survive the purge */
    kill(getpid(), SIGUSR1);
    struct image_buffer *c = get(dng); /* applies the pending SIGUSR1 itself, no explicit poll */
    CHECK(dual_iso_mode() == 1, "SIGUSR1 -> mode 1 (applied lazily at lookup)");
    CHECK(c && c != b && decode_calls == 3 && last_decode_mode == 1, "after switch back: decoded again in mode 1 (calls=%d)", decode_calls);
    CHECK(data_mode(b) == 2, "held stale buffer not freed under its holder");
    release_image_buffer(b);
    release_image_buffer(c);

    /* same mode again: no change, no new generation */
    unsigned g = dual_iso_generation();
    kill(getpid(), SIGUSR1);
    CHECK(dual_iso_poll() == 0 && dual_iso_generation() == g, "repeated SIGUSR1: no change");
    struct image_buffer *c2 = get(dng);
    CHECK(c2 == c && decode_calls == 3, "cache reused again after repeated signal (calls=%d)", decode_calls);
    release_image_buffer(c2);

    /* review scenario: H1 and H2 open the same DNG, a switch, H2 closes, a new lookup:
       H1's (old generation) buffer must stay valid until H1 closes. */
    const char *dng2 = "/clip/frame_000001.dng";
    struct image_buffer *h1 = get(dng2);
    struct image_buffer *h2 = get(dng2);
    CHECK(h1 && h1 == h2 && get_image_buffer_ref_count(h1) == 2, "two handles share one buffer, ref 2");
    kill(getpid(), SIGUSR2);
    release_image_buffer(h2); /* H2 closes */
    CHECK(get_image_buffer_ref_count(h1) == 1, "H2's close drops only its own reference (ref 1)");
    struct image_buffer *l = get(dng2); /* lookup after the switch: purges stale unreferenced buffers */
    CHECK(l && l != h1 && last_decode_mode == 2, "lookup after switch decodes a new mode 2 buffer");
    CHECK(data_mode(h1) == 1, "H1's old-generation buffer still valid (not purged)");
    /* a third handle opened and closed after the switch must not affect H1 either */
    struct image_buffer *h3 = get(dng2);
    release_image_buffer(h3);
    struct image_buffer *l2 = get(dng2);
    CHECK(data_mode(h1) == 1 && get_image_buffer_ref_count(h1) == 1, "H1 still valid after H3 open/close");
    release_image_buffer(l2);
    release_image_buffer(l);
    release_image_buffer(h1); /* H1 closes: now unreferenced and stale */
    int before = get_image_buffer_count();
    struct image_buffer *l3 = get(dng2);
    CHECK(get_image_buffer_count() == before - 1, "H1's stale buffer purged once unreferenced (%d -> %d)",
          before, get_image_buffer_count());
    release_image_buffer(l3);

    /* A playback read-ahead window must be reusable, rather than decoded again per read. */
    frame_bytes = 1024 * 1024;
    struct image_buffer *window[24];
    int calls_before = decode_calls;
    for (int i = 0; i < 24; i++) {
        char name[64]; snprintf(name, sizeof(name), "/clip/window_%06d.dng", i);
        window[i] = get(name);
    }
    for (int i = 0; i < 24; i++) {
        lock_image_buffer_data(window[i], fake_decode);
        unlock_image_buffer_data(window[i]);
    }
    CHECK(decode_calls - calls_before == 24, "24-frame playback window decoded once (got %d)", decode_calls - calls_before);
    for (int i = 0; i < 24; i++) release_image_buffer(window[i]);
    frame_bytes = 8 * 1024 * 1024;

    /* Resolve can retain thousands of open DNG handles after reading thumbnails. */
    struct image_buffer *held[64];
    for (int i = 0; i < 64; i++) {
        char name[64]; snprintf(name, sizeof(name), "/clip/retained_%06d.dng", i);
        held[i] = get(name);
    }
    int decoded = 0;
    for (int i = 0; i < 64; i++) if (held[i] && held[i]->data) decoded++;
    CHECK(decoded <= 32, "open handles keep decoded frames within 256 MiB (got %d x 8 MiB)", decoded);
    /* Re-reading an older retained frame makes it hot; insertion age must not evict it. */
    lock_image_buffer_data(held[33], fake_decode);
    unlock_image_buffer_data(held[33]);
    struct image_buffer *pressure = get("/clip/lru_pressure.dng");
    CHECK(held[33]->data != NULL && held[34]->data == NULL, "recently reread frame survives while older idle data is evicted");
    release_image_buffer(pressure);
    /* Evicted data can be regenerated in the handle's original mode after a live switch. */
    int expected = held[0]->dual_iso;
    kill(getpid(), expected == 1 ? SIGUSR2 : SIGUSR1);
    dual_iso_poll();
    lock_image_buffer_data(held[0], fake_decode);
    CHECK(data_mode(held[0]) == expected, "evicted open handle redecodes in its original mode");
    for (int i = 0; i < 32; i++) {
        char name[64]; snprintf(name, sizeof(name), "/clip/other_%06d.dng", i);
        struct image_buffer *other = get(name); release_image_buffer(other);
    }
    CHECK(data_mode(held[0]) == expected, "active reader survives cache eviction pressure");
    unlock_image_buffer_data(held[0]);
    for (int i = 0; i < 64; i++) release_image_buffer(held[i]);

    free_all_image_buffers();
    printf("%d failures\n", failures);
    return failures ? 1 : 0;
}
