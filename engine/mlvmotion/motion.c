/* Same algorithm as poc/mlv_motion.py: 2x2 Bayer bin, 2x decimation, log, Hann window,
 * phase correlation, parabolic sub-pixel peak. FFTs are zero-padded to powers of two (vDSP). */
#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "motion.h"
#include "raw.h"
#include "mlv.h"
#include "lj92.h"

#define CHUNK 48

static void seterr(char *err, size_t n, const char *msg) { snprintf(err, n, "%s", msg); }

static int cmp_frame(const void *a, const void *b)
{
    const mm_frame *x = a, *y = b;
    return x->num < y->num ? -1 : x->num > y->num;
}

int mm_open(mm_clip *c, const char *path, char *err, size_t errlen)
{
    memset(c, 0, sizeof *c);
    c->auto_squeeze = 1.0;
    FILE *f = fopen(path, "rb");
    if (!f) { seterr(err, errlen, "cannot open clip"); return 2; }
    struct stat st;
    if (fstat(fileno(f), &st)) { fclose(f); seterr(err, errlen, "cannot stat clip"); return 2; }
    uint64_t fsize = (uint64_t)st.st_size;
    mlv_file_hdr_t fh;
    if (fread(&fh, sizeof fh, 1, f) != 1 || memcmp(fh.fileMagic, "MLVI", 4)) {
        fclose(f); seterr(err, errlen, "not an MLV file"); return 2;
    }
    if (fh.videoClass != (MLV_VIDEO_CLASS_RAW | MLV_VIDEO_CLASS_FLAG_LJ92)) {
        fclose(f); seterr(err, errlen, "clip is not LJ92-compressed raw video"); return 2;
    }
    int cap = 1024;
    c->frames = malloc(sizeof(mm_frame) * cap);
    uint64_t pos = fh.blockSize;
    while (pos + 16 <= fsize) {
        uint8_t hdr[16];
        if (fseeko(f, (off_t)pos, SEEK_SET) || fread(hdr, 16, 1, f) != 1) break;
        uint32_t size; memcpy(&size, hdr + 4, 4);
        if (size < 16 || pos + size > fsize) break;  /* truncated tail */
        if (!memcmp(hdr, "VIDF", 4) && size >= 32) {
            uint8_t body[16];
            if (fread(body, 16, 1, f) != 1) break;
            uint32_t num, space;
            memcpy(&num, body, 4); memcpy(&space, body + 12, 4);
            if (32 + (uint64_t)space < size) {
                if (c->count == cap) { cap *= 2; c->frames = realloc(c->frames, sizeof(mm_frame) * cap); }
                c->frames[c->count++] = (mm_frame){ num, pos + 32 + space, size - 32 - space };
            }
        } else if (!memcmp(hdr, "RAWC", 4) && size >= sizeof(mlv_rawc_hdr_t)) {
            mlv_rawc_hdr_t rc;
            if (fseeko(f, (off_t)pos, SEEK_SET) == 0 && fread(&rc, sizeof rc, 1, f) == 1) {
                int sx = rc.binning_x + rc.skipping_x, sy = rc.binning_y + rc.skipping_y;
                if (sx > 0 && sy > 0 && sx > sy) c->auto_squeeze = (double)sx / sy;
            }
        }
        pos += size;
    }
    fclose(f);
    if (c->count < 2) { mm_close(c); seterr(err, errlen, "clip has fewer than 2 video frames"); return 2; }
    qsort(c->frames, c->count, sizeof(mm_frame), cmp_frame);
    c->path = strdup(path);
    return 0;
}

void mm_close(mm_clip *c) { free(c->frames); free(c->path); memset(c, 0, sizeof *c); }

typedef struct { float *px; int h, w; } mm_img;

/* Decode + bin + window. Returns 0 on success. */
static int load_gray(const mm_clip *c, int fd, const mm_frame *fr, mm_img *out)
{
    uint8_t *buf = malloc(fr->size);
    if (!buf) return -1;
    if (pread(fd, buf, fr->size, (off_t)fr->off) != (ssize_t)fr->size) { free(buf); return -1; }
    lj92 lj; int w = 0, h = 0, bd = 0, comp = 0;
    if (lj92_open(&lj, buf, (int)fr->size, &w, &h, &bd, &comp) != LJ92_ERROR_NONE) { free(buf); return -1; }
    size_t n = (size_t)w * h * comp;
    uint16_t *raw = malloc(n * sizeof(uint16_t));
    int rc = raw ? lj92_decode(lj, raw, (int)n, 0, NULL, 0) : -1;
    lj92_close(lj);
    free(buf);
    if (rc != LJ92_ERROR_NONE) { free(raw); return -1; }
    int W = w * comp;
    int oh = (h / 2) / 2, ow = (W / 2) / 2;
    if (oh < 4 || ow < 4) { free(raw); return -1; }
    float *g = malloc(sizeof(float) * oh * ow);
    float mn = INFINITY;
    for (int y = 0; y < oh; y++)
        for (int x = 0; x < ow; x++) {
            const uint16_t *p = raw + (size_t)(4 * y) * W + 4 * x;
            uint32_t s = 0;
            for (int j = 0; j < 4; j++, p += W) s += p[0] + p[1] + p[2] + p[3];
            float v = (float)s * 0.25f;   /* mean of 2x2 of (sum of 2x2) */
            g[y * ow + x] = v;
            if (v < mn) mn = v;
        }
    free(raw);
    double sum = 0;
    for (int i = 0; i < oh * ow; i++) { g[i] = log1pf(fmaxf(g[i] - mn, 0)); sum += g[i]; }
    float mean = (float)(sum / (oh * ow));
    float *wy = malloc(sizeof(float) * oh), *wx = malloc(sizeof(float) * ow);
    for (int i = 0; i < oh; i++) wy[i] = 0.5f - 0.5f * cosf(2 * (float)M_PI * i / (oh - 1));
    for (int i = 0; i < ow; i++) wx[i] = 0.5f - 0.5f * cosf(2 * (float)M_PI * i / (ow - 1));
    for (int y = 0; y < oh; y++)
        for (int x = 0; x < ow; x++) g[y * ow + x] = (g[y * ow + x] - mean) * wy[y] * wx[x];
    free(wy); free(wx);
    out->px = g; out->h = oh; out->w = ow;
    return 0;
}

static int ilog2_ceil(int n) { int l = 0; while ((1 << l) < n) l++; return l; }

typedef struct { double dx, dy, peak; } mm_shift;

static double subpix(const float *cm, int i, int n, int stride)
{
    float y0 = cm[((i - 1 + n) % n) * stride], y1 = cm[i * stride], y2 = cm[((i + 1) % n) * stride];
    float d = y0 - 2 * y1 + y2;
    return i + (d != 0 ? 0.5f * (y0 - y2) / d : 0);
}

static mm_shift phase_shift(FFTSetup setup, const mm_img *a, const mm_img *b, int lw, int lh)
{
    int NW = 1 << lw, NH = 1 << lh;
    size_t N = (size_t)NW * NH;
    float *mem = calloc(N * 4, sizeof(float));
    DSPSplitComplex A = { mem, mem + N }, B = { mem + 2 * N, mem + 3 * N };
    for (int y = 0; y < a->h; y++) {
        memcpy(A.realp + (size_t)y * NW, a->px + (size_t)y * a->w, sizeof(float) * a->w);
        memcpy(B.realp + (size_t)y * NW, b->px + (size_t)y * b->w, sizeof(float) * b->w);
    }
    vDSP_fft2d_zip(setup, &A, 1, 0, lw, lh, FFT_FORWARD);
    vDSP_fft2d_zip(setup, &B, 1, 0, lw, lh, FFT_FORWARD);
    for (size_t i = 0; i < N; i++) {   /* r = fb * conj(fa), normalised; stored in A */
        float ar = A.realp[i], ai = A.imagp[i], br = B.realp[i], bi = B.imagp[i];
        float rr = br * ar + bi * ai, ri = bi * ar - br * ai;
        float m = sqrtf(rr * rr + ri * ri) + 1e-9f;
        A.realp[i] = rr / m; A.imagp[i] = ri / m;
    }
    vDSP_fft2d_zip(setup, &A, 1, 0, lw, lh, FFT_INVERSE);
    float *cc = A.realp;
    float scale = 1.0f / (float)N, best; vDSP_Length idx;
    vDSP_vsmul(cc, 1, &scale, cc, 1, N);
    vDSP_maxvi(cc, 1, &best, &idx, N);
    int iy = (int)(idx / NW), ix = (int)(idx % NW);
    double dy = subpix(cc + ix, iy, NH, NW);
    double dx = subpix(cc + (size_t)iy * NW, ix, NW, 1);
    if (dy > NH / 2.0) dy -= NH;
    if (dx > NW / 2.0) dx -= NW;
    free(mem);
    return (mm_shift){ dx, dy, best };
}

int mm_extract(const mm_clip *c, double squeeze, FILE *out, char *err, size_t errlen)
{
    if (squeeze <= 0) squeeze = c->auto_squeeze;
    int fd = open(c->path, O_RDONLY);
    if (fd < 0) { seterr(err, errlen, "cannot open clip"); return 2; }
    mm_img *imgs = calloc(c->count, sizeof(mm_img));
    mm_shift *res = calloc(CHUNK + 1, sizeof(mm_shift));
    __block int failed = 0;
    int lw = 0, lh = 0;
    FFTSetup setup = NULL;
    fputs("frame,dx,dy,peak\n", out);
    for (int base = 0; base < c->count; base += CHUNK) {
        int n = c->count - base < CHUNK ? c->count - base : CHUNK;
        dispatch_apply(n, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t k) {
            if (load_gray(c, fd, &c->frames[base + k], &imgs[base + k])) failed = 1;
        });
        if (failed) { seterr(err, errlen, "failed to decode a frame (corrupt LJ92 data)"); break; }
        if (!setup) {
            lw = ilog2_ceil(imgs[0].w); lh = ilog2_ceil(imgs[0].h);
            setup = vDSP_create_fftsetup(lw > lh ? lw : lh, kFFTRadix2);
        }
        int first = base == 0 ? 1 : base;   /* pair (i-1, i) */
        int cnt = base + n - first;
        FFTSetup s = setup; int LW = lw, LH = lh;
        dispatch_apply(cnt, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t k) {
            int i = first + (int)k;
            if (imgs[i].w != imgs[i - 1].w || imgs[i].h != imgs[i - 1].h) { failed = 1; return; }
            res[k] = phase_shift(s, &imgs[i - 1], &imgs[i], LW, LH);
        });
        if (failed) { seterr(err, errlen, "frame size changed within clip"); break; }
        for (int k = 0; k < cnt; k++) {
            int i = first + k;
            fprintf(out, "%u,%.3f,%.3f,%.4f\n", c->frames[i].num, res[k].dx * squeeze, res[k].dy, res[k].peak);
        }
        for (int i = base; i < base + n - 1; i++) { free(imgs[i].px); imgs[i].px = NULL; }  /* keep last as carry */
    }
    for (int i = 0; i < c->count; i++) free(imgs[i].px);
    if (setup) vDSP_destroy_fftsetup(setup);
    free(imgs); free(res); close(fd);
    return failed ? 2 : 0;
}
