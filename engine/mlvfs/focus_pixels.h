/*
 * Focus pixel correction from MLV App .fpm maps.
 *
 * Map lookup and interpolation are ported from MLV App (ilia3101/MLV-App,
 * src/mlv/llrawproc/pixelproc.c @ d1c8921). MLV App selects a map by camera model
 * and the full raw buffer size (RAWI raw_info.width x raw_info.height), file
 * name "<camera hex>_<raw_width>x<raw_height>.fpm" (or .fpm.gz, preferred); map coordinates are in raw
 * buffer space and are shifted by the VIDF pan position, rounded like MLV App.
 *
 * Original code: Copyright (C) 2014 The Magic Lantern Team, Copyright (C) 2017 bouncyball (MLV App).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 */

#ifndef mlvfs_focus_pixels_h
#define mlvfs_focus_pixels_h

#include <stdint.h>

/*
 * Interpolates the focus pixels listed in the matching .fpm map in place.
 * raw:        width x height 16-bit samples (unpacked, original bit depth)
 * crop_x/y:   VIDF panPosX / panPosY
 * fpm_dir:    directory holding the .fpm files (NULL = current directory)
 * raw_width/raw_height: RAWI raw_info.width / raw_info.height (selects the map)
 * black_level: RAWI raw_info.black_level (for the log-domain interpolation)
 * Returns the number of pixels corrected in this frame (0 if no map matches).
 * Thread safe; maps are loaded once and cached.
 */
int fpm_fix(uint16_t *raw, int width, int height, uint32_t camera_model, int crop_x, int crop_y,
            const char *fpm_dir, int raw_width, int raw_height, int black_level);

/* Returns 1 the first time it is called for a given key (e.g. clip path), 0 afterwards. Thread safe. */
int fpm_first_time(const char *key);

#endif
