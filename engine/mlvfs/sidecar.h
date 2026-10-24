/*
 * mlv2dng sidecar files: real files written through the mount (e.g. a .gyroflow saved by a gyro
 * tool into a clip folder) are stored in the MLV's own folder, next to the .MLV.
 *
 * A clip folder <mount>/<clipdir>/ (clip <base>.MLV) lists, besides its virtual DNGs/WAV, every
 * regular file of the MLV's folder it "owns":
 *   - a file associated in the per-folder index SIDECAR_INDEX_NAME is owned by the clip it names;
 *   - otherwise a file whose name starts with <base> followed by a non-alphanumeric character or by
 *     "MLV" (case-insensitive) is owned by that clip (M24-1546.gyroflow -> clip M24-1546, not M24-15).
 * Files created through a clip folder that do not match the prefix rule get an index association.
 *
 * Protected names (never created, written, renamed, deleted through the mount): the MLV family
 * (.MLV, .M00-.M99), .IDX, .MLD, the index and its temp files, .DS_Store, AppleDouble "._x" of a
 * protected x, and any path through ".", "..", a hidden component or a .MLD/.IDX component.
 *
 * Allowlist: an EXISTING file may be modified (written, truncated, renamed, deleted) through the mount
 * only if its extension is one of SIDECAR_MODIFIABLE_EXTS or the index records it as created through
 * the mount. New files of any non-protected name may be created.
 *
 * Index names are compared with Unicode canonical equivalence and case-insensitively (APFS semantics),
 * so an accented name keeps its association whether a tool writes it in NFC or NFD.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef mlvfs_sidecar_h
#define mlvfs_sidecar_h

#include <stddef.h>

#define SIDECAR_INDEX_NAME ".mlv2dng-sidecars.json"
/* the index and its temporary files (".mlv2dng-sidecars.json.tmp.*") share this prefix */
#define SIDECAR_INDEX_PREFIX ".mlv2dng-sidecars"
#define SIDECAR_MODIFIABLE_EXTS { "gyroflow", "gcsv", "json", "csv", "txt", "xml", "log", "cube", "srt" }

/* MLV family (.MLV .M00-.M99), .IDX, .MLD, the index (any case): never writable through the mount. */
int sidecar_name_protected(const char *name);
/* Never listed nor writable: the index and its temp files, .DS_Store, AppleDouble ._*, "." and ".." (any case). */
int sidecar_name_hidden(const char *name);
/* Names served virtually inside a clip folder (.dng .wav .gif .log, any case): never a sidecar. */
int sidecar_name_virtual(const char *name);
/* 1 if `name` starts with clip `base` followed by a non-alphanumeric char or "MLV" (case-insensitive). */
int sidecar_prefix_match(const char *base, const char *name);
/* 1 if an existing file of that name may be modified by extension alone (SIDECAR_MODIFIABLE_EXTS, any case). */
int sidecar_ext_modifiable(const char *name);
/* Unicode canonical equivalence (NFC == NFD) and case-insensitive equality of two UTF-8 names. */
int sidecar_name_equal(const char *a, const char *b);

/* "dir/._x" -> malloc'ed "dir/x"; NULL if the last component is not an AppleDouble name (or is "._._x"). */
char *sidecar_appledouble_subject(const char *path);
/* Name policy of a mount path ("/a/b"): 0 if it may be a writable regular file, -EACCES otherwise
   (protected/hidden last name, ".", "..", hidden or .MLD/.IDX intermediate components; "._x" follows x). */
int sidecar_path_check(const char *path);

struct sidecar_entry
{
    char *name;
    char *clip;   /* clip base this name is shown in, or NULL */
    int created;  /* created through the mount (modifiable whatever its extension) */
};

struct sidecar_index
{
    size_t count;
    struct sidecar_entry *entries;
};

/* Parses the index JSON ({"files": {"name": "clip", ...}, "created": ["name", ...]}).
   Returns 1 on success; on malformed input the index is left empty and 0 is returned. */
int sidecar_index_parse(const char *json, struct sidecar_index *idx);
/* malloc'ed JSON text (caller frees). */
char *sidecar_index_serialize(const struct sidecar_index *idx);
const char *sidecar_index_get(const struct sidecar_index *idx, const char *name);
int sidecar_index_created(const struct sidecar_index *idx, const char *name);
/* clip == NULL removes the association. Returns 1 if the index changed. */
int sidecar_index_set(struct sidecar_index *idx, const char *name, const char *clip);
int sidecar_index_set_created(struct sidecar_index *idx, const char *name, int created);
void sidecar_index_free(struct sidecar_index *idx);

/* 1 if clip `base` owns `name` (index association first, else prefix rule). idx may be NULL. */
int sidecar_owned_by(const struct sidecar_index *idx, const char *base, const char *name);

/* One change applied by sidecar_index_apply: SIDECAR_KEEP leaves a field, SET/CLEAR change it. */
enum { SIDECAR_KEEP = 0, SIDECAR_SET = 1, SIDECAR_CLEAR = 2 };
struct sidecar_change
{
    const char *name;
    int clip_op;
    const char *clip;
    int created_op;
};

/* Locked read of <dir>/SIDECAR_INDEX_NAME (opened O_NOFOLLOW, must be a regular file).
   0: loaded or missing (empty); -EIO: unreadable or malformed (idx empty); -EACCES: not a regular file. */
int sidecar_index_load(const char *dir, struct sidecar_index *idx);
/* 0 if the index of `dir` is missing or valid, so it can be updated; else as sidecar_index_load. */
int sidecar_index_writable(const char *dir);
/* Applies the changes in one locked transaction and rewrites the index atomically (temp file created
   O_EXCL|O_NOFOLLOW in `dir`, fsync, rename) only if it changed; an index left empty is deleted, nothing is
   created just to clear. A malformed or non-regular existing index is never overwritten (error returned). */
int sidecar_index_apply(const char *dir, const struct sidecar_change *changes, size_t count);

#endif
