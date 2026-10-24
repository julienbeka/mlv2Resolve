/*
 * mlv2dng sidecar files: real files written through the mount (e.g. a .gyroflow saved by a gyro
 * tool into a clip folder) are stored in the MLV's own folder, next to the .MLV.
 *
 * A clip folder <mount>/<clipdir>/ (clip <base>.MLV) lists, besides its virtual DNGs/WAV, every
 * regular file of the MLV's folder it "owns":
 *   - a file named in the per-folder index SIDECAR_INDEX_NAME is owned by the clip it names;
 *   - otherwise a file whose name starts with <base> followed by a non-alphanumeric character or by
 *     "MLV" (case-insensitive) is owned by that clip (M24-1546.gyroflow -> clip M24-1546, not M24-15).
 * Files created through a clip folder that do not match the prefix rule get an index entry.
 *
 * Protected names (never created, written, renamed, deleted through the mount): the MLV family
 * (.MLV, .M00-.M99), .IDX, .MLD, the index itself, and Finder metadata (.DS_Store, ._*).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef mlvfs_sidecar_h
#define mlvfs_sidecar_h

#include <stddef.h>

#define SIDECAR_INDEX_NAME ".mlv2dng-sidecars.json"

/* MLV family (.MLV .M00-.M99), .IDX, .MLD, the index file: never writable through the mount. */
int sidecar_name_protected(const char *name);
/* Never listed nor writable: the index, Finder metadata (.DS_Store, AppleDouble ._*), "." and "..". */
int sidecar_name_hidden(const char *name);
/* Names served virtually inside a clip folder (.dng .wav .gif .log, any case): never a sidecar. */
int sidecar_name_virtual(const char *name);
/* 1 if `name` starts with clip `base` followed by a non-alphanumeric char or "MLV" (case-insensitive). */
int sidecar_prefix_match(const char *base, const char *name);

struct sidecar_index
{
    size_t count;
    char **names;
    char **clips;
};

/* Parses the index JSON ({"files": {"name": "clip base", ...}}). Malformed input -> empty index, 0. */
int sidecar_index_parse(const char *json, struct sidecar_index *idx);
/* malloc'ed JSON text (caller frees). */
char *sidecar_index_serialize(const struct sidecar_index *idx);
const char *sidecar_index_get(const struct sidecar_index *idx, const char *name);
/* clip == NULL removes the entry. Returns 1 if the index changed. */
int sidecar_index_set(struct sidecar_index *idx, const char *name, const char *clip);
void sidecar_index_free(struct sidecar_index *idx);

/* 1 if clip `base` owns `name` (index entry first, else prefix rule). idx may be NULL. */
int sidecar_owned_by(const struct sidecar_index *idx, const char *base, const char *name);

/* Locked disk access to <dir>/SIDECAR_INDEX_NAME. load: a missing/unreadable index is empty. */
void sidecar_index_load(const char *dir, struct sidecar_index *idx);
/* Sets (clip != NULL) or removes the entry for `name`, rewriting the index in place only if it
   changed; an index left empty is deleted, and nothing is created just to remove an entry.
   Returns 0 or -errno. */
int sidecar_index_update(const char *dir, const char *name, const char *clip);

#endif
