/* mlvmotion: per-frame image motion of an LJ92 MLV clip (phase correlation). */
#ifndef MOTION_H
#define MOTION_H
#include <stdio.h>
#include <stdint.h>

typedef struct { uint32_t num; uint64_t off; uint64_t size; } mm_frame;

typedef struct {
    char *path;
    mm_frame *frames;      /* sorted by frame number */
    int count;
    double auto_squeeze;   /* horizontal squeeze from RAWC, 1.0 if unknown */
} mm_clip;

/* 0 on success; otherwise a non-zero code and a one-line reason in err. */
int mm_open(mm_clip *c, const char *path, char *err, size_t errlen);
void mm_close(mm_clip *c);
/* Writes the CSV (header + one row per frame >= 1). squeeze <= 0 means use auto. */
int mm_extract(const mm_clip *c, double squeeze, FILE *out, char *err, size_t errlen);
#endif
