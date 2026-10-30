/* Same algorithm as poc/mlv_motion.py: 2x2 Bayer bin, 2x decimation, log, Hann window,
 * phase correlation, parabolic sub-pixel peak. FFTs are zero-padded to powers of two (vDSP). */
#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <stdatomic.h>
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
    if (x->num != y->num) return x->num < y->num ? -1 : 1;
    return x->seq < y->seq ? -1 : x->seq > y->seq;   /* stable on file order */
}

/* Scans one file of the clip, appending VIDF blocks. Returns 0 or 2. */
static int scan_file(mm_clip *c, int file_idx, int *cap, uint64_t *seq, char *err, size_t errlen)
{
    FILE *f = fopen(c->paths[file_idx], "rb");
    if (!f) { seterr(err, errlen, "cannot open clip"); return 2; }
    struct stat st;
    if (fstat(fileno(f), &st)) { fclose(f); seterr(err, errlen, "cannot stat clip"); return 2; }
    uint64_t fsize = (uint64_t)st.st_size;
    mlv_file_hdr_t fh;
    if (fread(&fh, sizeof fh, 1, f) != 1 || memcmp(fh.fileMagic, "MLVI", 4) || fh.blockSize < sizeof fh) {
        fclose(f); seterr(err, errlen, "not an MLV file"); return 2;
    }
    if (file_idx == 0) {
        uint16_t need = MLV_VIDEO_CLASS_RAW | MLV_VIDEO_CLASS_FLAG_LJ92;
        if ((fh.videoClass & need) != need) {
            fclose(f); seterr(err, errlen, "clip is not LJ92-compressed raw video"); return 2;
        }
        c->file_count = fh.fileCount ? fh.fileCount : 1;
        c->fps = fh.sourceFpsDenom ? (double)fh.sourceFpsNom / fh.sourceFpsDenom : 0;
    }
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
                if (c->count == *cap) {
                    mm_frame *n = realloc(c->frames, sizeof(mm_frame) * (size_t)*cap * 2);
                    if (!n) { fclose(f); seterr(err, errlen, "out of memory"); return 2; }
                    c->frames = n; *cap *= 2;
                }
                c->frames[c->count++] = (mm_frame){ num, (uint32_t)file_idx, (*seq)++, pos + 32 + space, size - 32 - space };
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
    return 0;
}

int mm_open(mm_clip *c, const char *path, char *err, size_t errlen)
{
    memset(c, 0, sizeof *c);
    c->auto_squeeze = 1.0;
    size_t len = strlen(path);
    int cap = 1024;
    uint64_t seq = 0;
    c->frames = malloc(sizeof(mm_frame) * cap);
    c->paths = calloc(MM_MAX_FILES, sizeof(char *));
    if (!c->frames || !c->paths) { mm_close(c); seterr(err, errlen, "out of memory"); return 2; }
    c->paths[0] = strdup(path);
    if (!c->paths[0]) { mm_close(c); seterr(err, errlen, "out of memory"); return 2; }
    c->path_count = 1;
    int rc = scan_file(c, 0, &cap, &seq, err, errlen);
    /* chunks: same convention as MLVFS (index.c load_chunks): last two chars of the name become 00, 01, ... */
    for (int i = 0; !rc && i < 99 && len >= 2; i++) {
        char *p = strdup(path);
        if (!p) { rc = 2; seterr(err, errlen, "out of memory"); break; }
        snprintf(p + len - 2, 3, "%02d", i);
        if (access(p, R_OK)) { free(p); break; }
        c->paths[c->path_count++] = p;
        rc = scan_file(c, c->path_count - 1, &cap, &seq, err, errlen);
    }
    if (!rc && c->path_count < c->file_count) { rc = 2; seterr(err, errlen, "clip chunk missing (fewer files than the MLV header declares)"); }
    if (!rc && c->count < 2) { rc = 2; seterr(err, errlen, "clip has fewer than 2 video frames"); }
    if (rc) { mm_close(c); return 2; }
    qsort(c->frames, c->count, sizeof(mm_frame), cmp_frame);
    int w = 0;   /* drop duplicate frame numbers, keep the first */
    for (int i = 0; i < c->count; i++)
        if (w == 0 || c->frames[i].num != c->frames[w - 1].num) c->frames[w++] = c->frames[i];
    c->count = w;
    if (c->count < 2) { mm_close(c); seterr(err, errlen, "clip has fewer than 2 distinct video frames"); return 2; }
    return 0;
}

void mm_close(mm_clip *c)
{
    free(c->frames);
    if (c->paths) for (int i = 0; i < MM_MAX_FILES; i++) free(c->paths[i]);
    free(c->paths);
    memset(c, 0, sizeof *c);
}

typedef struct { float *px; int h, w; } mm_img;

/* Decode + bin + window. Returns 0 on success. */
static int load_gray(const mm_clip *c, const int *fds, const mm_frame *fr, mm_img *out)
{
    int fd = fds[fr->file];
    uint8_t *buf = malloc(fr->size);
    if (!buf) return -1;
    if (pread(fd, buf, fr->size, (off_t)fr->off) != (ssize_t)fr->size) { free(buf); return -1; }
    lj92 lj; int w = 0, h = 0, bd = 0, comp = 0;
    if (lj92_open(&lj, buf, (int)fr->size, &w, &h, &bd, &comp) != LJ92_ERROR_NONE) { free(buf); return -1; }
    if (w < 1 || h < 1 || comp < 1 || comp > 4 || w > 16384 || h > 16384 || (size_t)w * h * comp > ((size_t)64 << 20)) {
        lj92_close(lj); free(buf); return -1;
    }
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
    if (!g) { free(raw); return -1; }
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
    if (!wy || !wx) { free(wy); free(wx); free(g); return -1; }
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

/* peak < 0 on allocation failure */
static mm_shift phase_shift(FFTSetup setup, const mm_img *a, const mm_img *b, int lw, int lh)
{
    int NW = 1 << lw, NH = 1 << lh;
    size_t N = (size_t)NW * NH;
    float *mem = calloc(N * 4, sizeof(float));
    if (!mem) return (mm_shift){ 0, 0, -1 };
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

static int extract(const mm_clip *c, double squeeze, FILE *out, int header, char *err, size_t errlen)
{
    if (!(squeeze > 0) || !isfinite(squeeze)) squeeze = c->auto_squeeze;
    int *fds = malloc(sizeof(int) * c->path_count);
    mm_img *imgs = calloc(c->count, sizeof(mm_img));
    mm_shift *res = calloc(CHUNK + 1, sizeof(mm_shift));
    static _Atomic int failed_flag;
    atomic_int *failed = &failed_flag;
    atomic_store(failed, 0);
    const char *reason = NULL;
    int nopen = 0, lw = 0, lh = 0;
    FFTSetup setup = NULL;
    if (!fds || !imgs || !res) reason = "out of memory";
    for (int i = 0; !reason && i < c->path_count; i++) {
        fds[i] = open(c->paths[i], O_RDONLY);
        if (fds[i] < 0) reason = "cannot open clip"; else nopen++;
    }
    const int *cfds = fds;
    if (!reason && header) fputs("frame,dx,dy,peak\n", out);
    for (int base = 0; !reason && base < c->count; base += CHUNK) {
        int n = c->count - base < CHUNK ? c->count - base : CHUNK;
        dispatch_apply(n, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t k) {
            if (load_gray(c, cfds, &c->frames[base + k], &imgs[base + k])) atomic_store(failed, 1);
        });
        if (atomic_load(failed)) { reason = "failed to decode a frame (corrupt LJ92 data)"; break; }
        if (!setup) {
            lw = ilog2_ceil(imgs[0].w); lh = ilog2_ceil(imgs[0].h);
            setup = vDSP_create_fftsetup(lw > lh ? lw : lh, kFFTRadix2);
            if (!setup) { reason = "out of memory"; break; }
        }
        int first = base == 0 ? 1 : base;   /* pair (i-1, i) */
        int cnt = base + n - first;
        FFTSetup s = setup; int LW = lw, LH = lh;
        dispatch_apply(cnt, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t k) {
            int i = first + (int)k;
            if (imgs[i].w != imgs[i - 1].w || imgs[i].h != imgs[i - 1].h) { atomic_store(failed, 2); return; }
            res[k] = phase_shift(s, &imgs[i - 1], &imgs[i], LW, LH);
            if (res[k].peak < 0) atomic_store(failed, 3);
        });
        int fl = atomic_load(failed);
        if (fl) { reason = fl == 2 ? "frame size changed within clip" : "out of memory"; break; }
        for (int k = 0; k < cnt; k++) {
            int i = first + k;
            fprintf(out, "%u,%.3f,%.3f,%.4f\n", c->frames[i].num, res[k].dx * squeeze, res[k].dy, res[k].peak);
        }
        for (int i = base; i < base + n - 1; i++) { free(imgs[i].px); imgs[i].px = NULL; }  /* keep last as carry */
    }
    if (imgs) for (int i = 0; i < c->count; i++) free(imgs[i].px);
    if (setup) vDSP_destroy_fftsetup(setup);
    for (int i = 0; i < nopen; i++) close(fds[i]);
    free(imgs); free(res); free(fds);
    if (reason) seterr(err, errlen, reason);
    return reason ? 2 : 0;
}

int mm_extract(const mm_clip *c, double squeeze, FILE *out, char *err, size_t errlen)
{
    return extract(c, squeeze, out, 1, err, errlen);
}

int mm_extract_sampled(const mm_clip *c, double squeeze, FILE *out, char *err, size_t errlen)
{
    enum { WINDOWS = 3 };
    // At least six seconds of evidence even at high frame rates, comfortably
    // above the solver's three-second coverage floor. Invalid rates use full analysis.
    if (!(c->fps > 0) || c->fps > (double)c->count / 6)
        return mm_extract(c, squeeze, out, err, errlen);
    int window = 1 + (int)fmax(64, ceil(2 * c->fps)); /* predecessor + adjacent pairs */
    if (c->count <= (int64_t)window * WINDOWS) return mm_extract(c, squeeze, out, err, errlen);
    for (int w = 0; w < WINDOWS; w++) {
        mm_clip part = *c;  /* borrowed frame slice; never mm_close this copy */
        part.frames = c->frames + (int)((int64_t)w * (c->count - window) / (WINDOWS - 1));
        part.count = window;
        int rc = extract(&part, squeeze, out, w == 0, err, errlen);
        if (rc) return rc;
    }
    return 0;
}
