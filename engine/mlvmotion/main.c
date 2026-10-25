/* mlvmotion <clip.MLV> [--squeeze N]  ->  CSV "frame,dx,dy,peak" on stdout. Exit 2: unusable clip. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "motion.h"

int main(int argc, char **argv)
{
    const char *path = NULL;
    double squeeze = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--squeeze") && i + 1 < argc) {
            char *end; squeeze = strtod(argv[++i], &end);
            if (*end || squeeze <= 0) { fprintf(stderr, "mlvmotion: bad --squeeze value\n"); return 2; }
        } else if (!path && argv[i][0] != '-') path = argv[i];
        else { fprintf(stderr, "usage: mlvmotion <clip.MLV> [--squeeze N]\n"); return 2; }
    }
    if (!path) { fprintf(stderr, "usage: mlvmotion <clip.MLV> [--squeeze N]\n"); return 2; }
    char err[256] = "";
    mm_clip clip;
    if (mm_open(&clip, path, err, sizeof err)) { fprintf(stderr, "mlvmotion: %s\n", err); return 2; }
    int rc = mm_extract(&clip, squeeze, stdout, err, sizeof err);
    if (rc) fprintf(stderr, "mlvmotion: %s\n", err);
    mm_close(&clip);
    fflush(stdout);
    return rc ? 2 : 0;
}
