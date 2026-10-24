/*
 * Sidecar name rules and index (no FUSE): make -f Makefile.arm64 sidecar-test
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "sidecar.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static char *slurp(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    char *buf = calloc(1, 65536);
    fread(buf, 1, 65535, f);
    fclose(f);
    return buf;
}

int main(void)
{
    /* protected names */
    const char *prot[] = { "M24-1546.MLV", "a.mlv", "M24-1546.M00", "x.m42", "x.M99", "x.IDX", "x.idx", "x.MLD",
                           SIDECAR_INDEX_NAME };
    for (size_t i = 0; i < sizeof(prot) / sizeof(*prot); i++) CHECK(sidecar_name_protected(prot[i]));
    const char *free_[] = { "M24-1546.gyroflow", "lens.json", "x.M0", "x.M100", "x.Mab", "x.gcsv", "MLV", "x.MLVX" };
    for (size_t i = 0; i < sizeof(free_) / sizeof(*free_); i++) CHECK(!sidecar_name_protected(free_[i]));

    /* hidden and virtual names */
    CHECK(sidecar_name_hidden(".DS_Store"));
    CHECK(sidecar_name_hidden("._M24-1546.gyroflow"));
    CHECK(sidecar_name_hidden(SIDECAR_INDEX_NAME));
    CHECK(sidecar_name_hidden(".") && sidecar_name_hidden(".."));
    CHECK(!sidecar_name_hidden(".nfs0001") && !sidecar_name_hidden("lens.json"));
    CHECK(sidecar_name_virtual("a_000000.dng") && sidecar_name_virtual("A.DNG") && sidecar_name_virtual("x.wav"));
    CHECK(sidecar_name_virtual("_PREVIEW.gif") && sidecar_name_virtual("x.log"));
    CHECK(!sidecar_name_virtual("x.gyroflow") && !sidecar_name_virtual("dng"));

    /* prefix rule */
    CHECK(sidecar_prefix_match("M24-1546", "M24-1546.gyroflow"));
    CHECK(sidecar_prefix_match("M24-1546", "M24-1546MLV_1_2026-10-24_0001_C0000.gyroflow"));
    CHECK(sidecar_prefix_match("M24-1546", "m24-1546mlv_x.json"));
    CHECK(sidecar_prefix_match("M24-1546", "M24-1546_gyro.gcsv"));
    CHECK(sidecar_prefix_match("M24-1546", "M24-1546 copy.json"));
    CHECK(!sidecar_prefix_match("M24-15", "M24-1546.gyroflow"));
    CHECK(!sidecar_prefix_match("M24-1546", "M24-1546B.gyroflow"));
    CHECK(!sidecar_prefix_match("M24-1546", "M24-1546"));      /* nothing after the base */
    CHECK(!sidecar_prefix_match("M24-1546", "M24-154.json"));
    CHECK(!sidecar_prefix_match("M24-1546", "odd.txt"));
    CHECK(!sidecar_prefix_match("", "x.txt"));

    /* index in memory, JSON round trip with awkward names */
    struct sidecar_index idx = {0};
    CHECK(sidecar_index_set(&idx, "odd-name.txt", "M24-1546"));
    CHECK(sidecar_index_set(&idx, "été \"q\" \\ x\t.json", "M24-15"));
    CHECK(!sidecar_index_set(&idx, "odd-name.txt", "M24-1546"));
    CHECK(sidecar_index_set(&idx, "odd-name.txt", "M24-15"));
    CHECK(strcmp(sidecar_index_get(&idx, "odd-name.txt"), "M24-15") == 0);
    char *json = sidecar_index_serialize(&idx);
    CHECK(json && strstr(json, "\"files\""));
    struct sidecar_index back = {0};
    CHECK(sidecar_index_parse(json, &back) == 1);
    CHECK(back.count == 2);
    CHECK(back.count == 2 && strcmp(sidecar_index_get(&back, "été \"q\" \\ x\t.json"), "M24-15") == 0);
    free(json);
    sidecar_index_free(&back);
    CHECK(sidecar_index_set(&idx, "odd-name.txt", NULL));
    CHECK(!sidecar_index_set(&idx, "absent", NULL));
    CHECK(idx.count == 1 && sidecar_index_get(&idx, "odd-name.txt") == NULL);

    /* ownership: index entry wins over the prefix rule */
    sidecar_index_set(&idx, "M24-1546.note", "M24-15");
    CHECK(!sidecar_owned_by(&idx, "M24-1546", "M24-1546.note"));
    CHECK(sidecar_owned_by(&idx, "M24-15", "M24-1546.note"));
    CHECK(sidecar_owned_by(&idx, "M24-1546", "M24-1546.gyroflow"));
    CHECK(sidecar_owned_by(NULL, "M24-1546", "M24-1546.gyroflow"));
    sidecar_index_free(&idx);

    /* malformed input */
    struct sidecar_index bad = {0};
    CHECK(sidecar_index_parse("{\"files\": {\"a\": ", &bad) == 0 && bad.count == 0);
    CHECK(sidecar_index_parse("garbage", &bad) == 0 && bad.count == 0);
    CHECK(sidecar_index_parse("{\"files\": {\"\\u00e9.txt\": \"C\"}}", &bad) == 1);
    CHECK(bad.count == 1 && strcmp(bad.names[0], "\xc3\xa9.txt") == 0);
    sidecar_index_free(&bad);

    /* disk: removing from a missing index creates nothing; the last removal deletes the file */
    char dir[] = "/tmp/sidecar_test_XXXXXX";
    CHECK(mkdtemp(dir) != NULL);
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", dir, SIDECAR_INDEX_NAME);
    struct stat st;
    CHECK(sidecar_index_update(dir, "x.txt", NULL) == 0);
    CHECK(stat(path, &st) != 0);
    CHECK(sidecar_index_update(dir, "x.txt", "M24-1546") == 0);
    CHECK(sidecar_index_update(dir, "y.txt", "M24-15") == 0);
    char *text = slurp(path);
    CHECK(text && strstr(text, "x.txt") && strstr(text, "y.txt"));
    free(text);
    struct sidecar_index disk = {0};
    sidecar_index_load(dir, &disk);
    CHECK(disk.count == 2 && strcmp(sidecar_index_get(&disk, "y.txt"), "M24-15") == 0);
    sidecar_index_free(&disk);
    CHECK(sidecar_index_update(dir, "x.txt", NULL) == 0);
    CHECK(stat(path, &st) == 0);
    CHECK(sidecar_index_update(dir, "y.txt", NULL) == 0);
    CHECK(stat(path, &st) != 0);
    rmdir(dir);

    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("sidecar_test: all checks passed\n");
    return 0;
}
