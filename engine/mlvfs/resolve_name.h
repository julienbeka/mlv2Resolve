/*
 * Maps a DaVinci Resolve style clip folder name back to its MLV file
 * (--resolve-naming). Replaces the SLRE regex previously used for this.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 */

#ifndef mlvfs_resolve_name_h
#define mlvfs_resolve_name_h

/*
 * Searches `path` for "(.+)(MLV|mlv)_1_[0-9]+-[0-9]+-[0-9]+_[0-9]+_[Cc][0-9]+"
 * (POSIX extended regex, unanchored, leftmost-longest). On a match, *base and
 * *ext receive malloc'ed copies of the two groups (caller frees) and 1 is
 * returned; otherwise 0, with *base and *ext untouched.
 * Example: "/x/M29-0615MLV_1_2026-08-29_0001_C0000" -> "/x/M29-0615", "MLV".
 */
int resolve_name_match(const char *path, char **base, char **ext);

#endif
