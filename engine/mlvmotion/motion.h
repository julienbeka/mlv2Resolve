/* mlvmotion: per-frame image motion of an LJ92 MLV clip (phase correlation). */
#ifndef MOTION_H
#define MOTION_H
#include <stdio.h>
#include <stdint.h>

#define MM_MAX_FILES 100   /* .MLV + .M00 ... .M98 */

typedef struct { uint32_t num; uint32_t file; uint64_t seq; uint64_t off; uint64_t size; } mm_frame;

typedef struct {
    char **paths;          /* MLV then .M00, .M01 ... (same naming as MLVFS) */
    int path_count;
    int file_count;        /* declared by the MLV header */
    mm_frame *frames;      /* sorted by frame number */
    int count;
    double auto_squeeze;   /* horizontal squeeze from RAWC, 1.0 if unknown */
    double fps;            /* source frame rate, used for the sampled analysis budget */
} mm_clip;

/* 0 on success; otherwise a non-zero code and a one-line reason in err. */
int mm_open(mm_clip *c, const char *path, char *err, size_t errlen);
void mm_close(mm_clip *c);
/* Output columns: frame number, dx (pixels of the 2x-binned image, times squeeze), dy, peak.
 * `peak` is a relative confidence on mlvmotion's own scale (zero-padded power-of-two FFT, 1/N scaling);
 * it is NOT comparable to the numpy PoC's values. Rows are written only as they are computed: callers must
 * discard the output on a non-zero return (main buffers it and prints only on success). */
/* Writes the CSV (header + one row per frame >= 1). squeeze <= 0 means use auto. */
int mm_extract(const mm_clip *c, double squeeze, FILE *out, char *err, size_t errlen);
/* Three windows (start, middle, end), each at least 64 pairs and two seconds,
 * with original frame numbers.
 * Short clips are analysed in full. No pairs are formed across window boundaries. */
int mm_extract_sampled(const mm_clip *c, double squeeze, FILE *out, char *err, size_t errlen);
#endif
