/*
 * Focus pixel correction from MLV App .fpm maps.
 *
 * Ported from MLV App (https://github.com/ilia3101/MLV-App,
 * src/mlv/llrawproc/pixelproc.c: load_pixel_map, fix_focus_pixels with the
 * default "MLVFS" interpolation method, interpolate_around/_vertical/_horizontal,
 * get_raw2ev/get_ev2raw). Original code: Copyright (C) 2014 The Magic Lantern Team,
 * Copyright (C) 2017 bouncyball (MLV App).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <zlib.h>
#include "focus_pixels.h"

#define FPM_EV_RES 65536
#define FPM_MIN(a,b) (((a)<(b))?(a):(b))
#define FPM_MAX(a,b) (((a)>(b))?(a):(b))
#define FPM_COERCE(x,lo,hi) FPM_MAX(FPM_MIN((x),(hi)),(lo))
#define FPM_ABS(a) ((a) > 0 ? (a) : -(a))

struct fpm_xy { int x, y; };

struct fpm_map
{
    uint32_t camera;
    int raw_width, raw_height;
    char *dir;
    size_t count;
    struct fpm_xy *pixels;
    struct fpm_map *next;
};

struct fpm_luts
{
    int black;
    int *raw2ev;
    int *ev2raw; /* points 10*FPM_EV_RES into its allocation, valid for [-10, 14) EV */
    struct fpm_luts *next;
};

struct fpm_key
{
    char *key;
    struct fpm_key *next;
};

static pthread_mutex_t fpm_lock = PTHREAD_MUTEX_INITIALIZER;
static struct fpm_map *fpm_maps = NULL;
static struct fpm_luts *fpm_lut_list = NULL;
static struct fpm_key *fpm_keys = NULL;

static int same_dir(const char *a, const char *b)
{
    if (!a || !b) return a == b;
    return strcmp(a, b) == 0;
}

/* MLV App load_pixel_map(): optional "#FPM <camera hex>" header, then "x y" per line.
   Reads "<name>.fpm.gz" (preferred) or plain "<name>.fpm" through zlib. */
static void fpm_load(struct fpm_map *map)
{
    char base[4096], path[4200];
    if (map->dir && map->dir[0])
        snprintf(base, sizeof(base), "%s/%x_%ix%i.fpm", map->dir, map->camera, map->raw_width, map->raw_height);
    else
        snprintf(base, sizeof(base), "%x_%ix%i.fpm", map->camera, map->raw_width, map->raw_height);

    snprintf(path, sizeof(path), "%s.gz", base);
    gzFile f = gzopen(path, "rb");
    if (!f)
    {
        snprintf(path, sizeof(path), "%s", base);
        f = gzopen(path, "rb"); /* zlib reads uncompressed files transparently */
    }
    if (!f) return;

    size_t capacity = 25000;
    map->pixels = malloc(sizeof(struct fpm_xy) * capacity);
    char line[256];
    int first_line = 1;
    while (map->pixels && gzgets(f, line, sizeof(line)))
    {
        if (first_line)
        {
            first_line = 0;
            unsigned int cam_id = 0;
            if (sscanf(line, "#FPM%*[ ]%X", &cam_id) == 1)
            {
                /* a header with a different camera id rejects the map, like MLV App */
                if (cam_id != 0 && cam_id != map->camera)
                {
                    free(map->pixels);
                    map->pixels = NULL;
                    break;
                }
                continue;
            }
        }
        int x, y;
        if (sscanf(line, "%d%*[ \t]%d", &x, &y) != 2) continue;
        if (map->count >= capacity)
        {
            capacity *= 2;
            struct fpm_xy *p = realloc(map->pixels, sizeof(struct fpm_xy) * capacity);
            if (!p)
            {
                free(map->pixels);
                map->pixels = NULL;
                map->count = 0;
                break;
            }
            map->pixels = p;
        }
        map->pixels[map->count].x = x;
        map->pixels[map->count].y = y;
        map->count++;
    }
    gzclose(f);
    fprintf(stderr, "focus pixel map '%s': %zu pixels loaded\n", path, map->count);
}

static struct fpm_map *fpm_get_map(uint32_t camera, int raw_width, int raw_height, const char *dir)
{
    pthread_mutex_lock(&fpm_lock);
    struct fpm_map *m;
    for (m = fpm_maps; m; m = m->next)
    {
        if (m->camera == camera && m->raw_width == raw_width && m->raw_height == raw_height && same_dir(m->dir, dir))
            break;
    }
    if (!m)
    {
        m = calloc(1, sizeof(struct fpm_map));
        if (m)
        {
            m->camera = camera;
            m->raw_width = raw_width;
            m->raw_height = raw_height;
            m->dir = dir ? strdup(dir) : NULL;
            fpm_load(m); /* a missing map is cached with count 0 */
            m->next = fpm_maps;
            fpm_maps = m;
        }
    }
    pthread_mutex_unlock(&fpm_lock);
    return (m && m->count) ? m : NULL;
}

static struct fpm_luts *fpm_get_luts(int black)
{
    pthread_mutex_lock(&fpm_lock);
    struct fpm_luts *l;
    for (l = fpm_lut_list; l; l = l->next)
    {
        if (l->black == black) break;
    }
    if (!l)
    {
        l = calloc(1, sizeof(struct fpm_luts));
        int *raw2ev = malloc(FPM_EV_RES * sizeof(int));
        int *ev2raw_base = malloc(24 * FPM_EV_RES * sizeof(int));
        if (!l || !raw2ev || !ev2raw_base)
        {
            free(l); free(raw2ev); free(ev2raw_base);
            pthread_mutex_unlock(&fpm_lock);
            return NULL;
        }
        for (int i = 0; i < FPM_EV_RES; i++)
            raw2ev[i] = log2(FPM_MAX(1, i - black)) * FPM_EV_RES;
        int *ev2raw = ev2raw_base + 10 * FPM_EV_RES;
        for (int i = -10 * FPM_EV_RES; i < 14 * FPM_EV_RES; i++)
            ev2raw[i] = black + pow(2, (float)i / FPM_EV_RES);
        l->black = black;
        l->raw2ev = raw2ev;
        l->ev2raw = ev2raw;
        l->next = fpm_lut_list;
        fpm_lut_list = l;
    }
    pthread_mutex_unlock(&fpm_lock);
    return l;
}

static inline void interpolate_horizontal(uint16_t *image_data, int i, int *raw2ev, int *ev2raw)
{
    int gh1 = image_data[i + 3];
    int gh2 = image_data[i + 1];
    int gh3 = image_data[i - 1];
    int gh4 = image_data[i - 3];
    int dh1 = FPM_ABS(raw2ev[gh1] - raw2ev[gh2]);
    int dh2 = FPM_ABS(raw2ev[gh3] - raw2ev[gh4]);
    int sum = dh1 + dh2;

    if (sum == 0)
    {
        image_data[i] = image_data[i + 2];
    }
    else if (sum < (3 * FPM_EV_RES))
    {
        int ch1 = (dh1 << 8) / sum;
        int ch2 = (dh2 << 8) / sum;
        int ev_corr = ((raw2ev[image_data[i - 2]] * ch1) >> 8) + ((raw2ev[image_data[i + 2]] * ch2) >> 8);
        int p = ev2raw[FPM_COERCE(ev_corr, 0, 14 * FPM_EV_RES - 1)];
        if (p < image_data[i])
        {
            image_data[i] = p;
        }
    }
}

static inline void interpolate_vertical(uint16_t *image_data, int i, int w, int *raw2ev, int *ev2raw)
{
    int gv1 = image_data[i + w * 3];
    int gv2 = image_data[i + w];
    int gv3 = image_data[i - w];
    int gv4 = image_data[i - w * 3];
    int dv1 = FPM_ABS(raw2ev[gv1] - raw2ev[gv2]);
    int dv2 = FPM_ABS(raw2ev[gv3] - raw2ev[gv4]);
    int sum = dv1 + dv2;
    if (sum == 0)
    {
        image_data[i] = image_data[i + w * 2];
    }
    else
    {
        int cv1 = ((sum - dv1) << 8) / sum;
        int cv2 = ((sum - dv2) << 8) / sum;
        int ev_corr = ((raw2ev[image_data[i + w * 2]] * cv1) >> 8) + ((raw2ev[image_data[i - w * 2]] * cv2) >> 8);
        image_data[i] = ev2raw[FPM_COERCE(ev_corr, 0, 14 * FPM_EV_RES - 1)];
    }
}

static inline void interpolate_around(uint16_t *image_data, int i, int w, int *raw2ev, int *ev2raw)
{
    int gv1 = image_data[i + w * 3];
    int gv2 = image_data[i + w];
    int gv3 = image_data[i - w];
    int gv4 = image_data[i - w * 3];
    int gh1 = image_data[i + 3];
    int gh2 = image_data[i + 1];
    int gh3 = image_data[i - 1];
    int gh4 = image_data[i - 3];
    int dv1 = FPM_ABS(raw2ev[gv1] - raw2ev[gv2]);
    int dv2 = FPM_ABS(raw2ev[gv3] - raw2ev[gv4]);
    int dh1 = FPM_ABS(raw2ev[gh1] - raw2ev[gh2]);
    int dh2 = FPM_ABS(raw2ev[gh3] - raw2ev[gh4]);
    int sum = dh1 + dh2 + dv1 + dv2;

    if (sum == 0)
    {
        image_data[i] = image_data[i + 2];
    }
    else
    {
        int cv1 = ((sum - dv1) << 8) / (3 * sum);
        int cv2 = ((sum - dv2) << 8) / (3 * sum);
        int ch1 = ((sum - dh1) << 8) / (3 * sum);
        int ch2 = ((sum - dh2) << 8) / (3 * sum);
        int ev_corr =
            ((raw2ev[image_data[i + w * 2]] * cv1) >> 8) +
            ((raw2ev[image_data[i - w * 2]] * cv2) >> 8) +
            ((raw2ev[image_data[i + 2]] * ch1) >> 8) +
            ((raw2ev[image_data[i - 2]] * ch2) >> 8);
        image_data[i] = ev2raw[FPM_COERCE(ev_corr, 0, 14 * FPM_EV_RES - 1)];
    }
}

int fpm_fix(uint16_t *raw, int width, int height, uint32_t camera_model, int crop_x, int crop_y,
            const char *fpm_dir, int raw_width, int raw_height, int black_level)
{
    if (!raw || width <= 0 || height <= 0) return 0;

    struct fpm_map *map = fpm_get_map(camera_model, raw_width, raw_height, fpm_dir);
    if (!map) return 0;
    struct fpm_luts *luts = fpm_get_luts(black_level);
    if (!luts) return 0;

    int *raw2ev = luts->raw2ev;
    int *ev2raw = luts->ev2raw;
    int w = width;
    int h = height;
    /* same rounding as MLV App / MLVFS (cropPosX had a bug, so round panPosX) */
    int cropX = (crop_x + 7) & ~7;
    int cropY = crop_y & ~1;
    int corrected = 0;

    for (size_t m = 0; m < map->count; m++)
    {
        int x = map->pixels[m].x - cropX;
        int y = map->pixels[m].y - cropY;
        int i = x + y * w;

        if (x > 2 && x < w - 3 && y > 2 && y < h - 3)
        {
            interpolate_around(raw, i, w, raw2ev, ev2raw);
            corrected++;
        }
        else if (x >= 0 && x < w && y >= 0 && y < h)
        {
            /* edge pixels, as in MLV App. Unlike MLV App (which only checks 0 < i < w*h), pixels outside
               the recorded window are skipped instead of wrapping into a neighbouring row, and the
               interpolation neighbourhood is kept inside the buffer. */
            int horizontal_edge = (x >= w - 3 && x < w) || (x >= 0 && x <= 3);
            int vertical_edge = (y >= h - 3 && y < h) || (y >= 0 && y <= 3);

            if (horizontal_edge && !vertical_edge && y >= 3 && y < h - 3)
            {
                interpolate_vertical(raw, i, w, raw2ev, ev2raw);
                corrected++;
            }
            else if (vertical_edge && !horizontal_edge && x >= 3 && x < w - 3)
            {
                interpolate_horizontal(raw, i, raw2ev, ev2raw);
                corrected++;
            }
            else if (x >= 0 && x <= 3)
            {
                raw[i] = raw[i + 2];
                corrected++;
            }
            else if (x >= w - 3 && x < w)
            {
                raw[i] = raw[i - 2];
                corrected++;
            }
        }
    }
    return corrected;
}

int fpm_first_time(const char *key)
{
    if (!key) return 0;
    int first = 1;
    pthread_mutex_lock(&fpm_lock);
    for (struct fpm_key *k = fpm_keys; k; k = k->next)
    {
        if (strcmp(k->key, key) == 0) { first = 0; break; }
    }
    if (first)
    {
        struct fpm_key *k = malloc(sizeof(struct fpm_key));
        if (k && (k->key = strdup(key)))
        {
            k->next = fpm_keys;
            fpm_keys = k;
        }
        else
        {
            free(k);
        }
    }
    pthread_mutex_unlock(&fpm_lock);
    return first;
}
