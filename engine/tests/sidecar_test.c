/*
 * Sidecar name rules, path policy and index (no FUSE): make -f Makefile.arm64 sidecar-test
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <errno.h>
#include <pthread.h>
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

static void spit(const char *path, const char *text)
{
    FILE *f = fopen(path, "wb");
    fputs(text, f);
    fclose(f);
}

static const char *thread_dir;
static void *apply_thread(void *arg)
{
    long n = (long)arg;
    for (int i = 0; i < 20; i++)
    {
        char name[64];
        snprintf(name, sizeof(name), "t%ld-%d.bin", n, i);
        struct sidecar_change c = { name, SIDECAR_SET, "CLIP", SIDECAR_SET };
        if (sidecar_index_apply(thread_dir, &c, 1) != 0) return (void *)1;
    }
    return NULL;
}

int main(void)
{
    /* protected names (any case) */
    const char *prot[] = { "M24-1546.MLV", "m24-1546.mlv", "X.Mlv", "M24-1546.M00", "x.m07", "x.M99", "x.IDX",
                           "x.idx", "x.MLD", "X.gyroflow.MLV", SIDECAR_INDEX_NAME, ".MLV2DNG-SIDECARS.JSON",
                           ".mlv2dng-sidecars.json.tmp.1.2" };
    for (size_t i = 0; i < sizeof(prot) / sizeof(*prot); i++) CHECK(sidecar_name_protected(prot[i]));
    const char *free_[] = { "M24-1546.gyroflow", "X.MLV.gyroflow", "lens.json", "x.M0", "x.M100", "x.Mab", "x.gcsv",
                            "MLV", "x.MLVX" };
    for (size_t i = 0; i < sizeof(free_) / sizeof(*free_); i++) CHECK(!sidecar_name_protected(free_[i]));

    /* hidden and virtual names */
    CHECK(sidecar_name_hidden(".DS_Store") && sidecar_name_hidden(".ds_store") && sidecar_name_hidden(".DS_STORE"));
    CHECK(sidecar_name_hidden("._M24-1546.gyroflow"));
    CHECK(sidecar_name_hidden(SIDECAR_INDEX_NAME) && sidecar_name_hidden(".MLV2DNG-SIDECARS.JSON"));
    CHECK(sidecar_name_hidden(".") && sidecar_name_hidden(".."));
    CHECK(!sidecar_name_hidden(".nfs0001") && !sidecar_name_hidden("lens.json"));
    CHECK(sidecar_name_virtual("a_000000.dng") && sidecar_name_virtual("A.DNG") && sidecar_name_virtual("x.wav"));
    CHECK(sidecar_name_virtual("_PREVIEW.gif") && sidecar_name_virtual("x.log"));
    CHECK(!sidecar_name_virtual("x.gyroflow") && !sidecar_name_virtual("dng"));

    /* path policy (what mlvfs_writable_target applies before resolving anything) */
    const char *refused[] = { "/m24-1546.mlv", "/X.Mlv", "/x.m07", "/X.gyroflow.MLV", "/._X.MLV", "/clip/._X.MLV",
                              "/._._x", "/a/../X.MLV", "/a/../x.txt", "/a/./x.txt", "/sub.mld/x", "/sub.MLD/x",
                              "/sub.Idx/x", "/.MLV2DNG-SIDECARS.JSON", "/clip/.mlv2dng-sidecars.json", "/.ds_store",
                              "/clip/.DS_Store", "/._.DS_Store", "/.hidden/._x/y", "/._dir/x", "/", "" };
    for (size_t i = 0; i < sizeof(refused) / sizeof(*refused); i++)
    {
        int r = sidecar_path_check(refused[i]);
        if (r != -EACCES) fprintf(stderr, "path accepted: '%s'\n", refused[i]);
        CHECK(r == -EACCES);
    }
    const char *allowed[] = { "/X.MLV.gyroflow", "/clip/M24-1546.gyroflow", "/clip/._M24-1546.gyroflow", "/odd.txt",
                              "/Audio/take.wav", "/X.MLV/x.txt", "/clip/.nfs0001" };
    for (size_t i = 0; i < sizeof(allowed) / sizeof(*allowed); i++)
    {
        int r = sidecar_path_check(allowed[i]);
        if (r != 0) fprintf(stderr, "path refused: '%s'\n", allowed[i]);
        CHECK(r == 0);
    }
    char *s = sidecar_appledouble_subject("/clip/._x.json");
    CHECK(s && strcmp(s, "/clip/x.json") == 0);
    free(s);
    CHECK(sidecar_appledouble_subject("/clip/._._x") == NULL);
    CHECK(sidecar_appledouble_subject("/clip/._") == NULL);
    CHECK(sidecar_appledouble_subject("/clip/x._y") == NULL);

    /* allowlist of extensions an existing file may be modified by */
    const char *mod[] = { "a.gyroflow", "A.GYROFLOW", "a.gcsv", "a.json", "a.csv", "a.txt", "a.xml", "a.log", "a.cube", "a.srt" };
    for (size_t i = 0; i < sizeof(mod) / sizeof(*mod); i++) CHECK(sidecar_ext_modifiable(mod[i]));
    const char *ro[] = { "a.wav", "a.mov", "a.mp4", "a.dng", "a.cr2", "a.bin", "json", ".json", "a.json.bak", "a" };
    for (size_t i = 0; i < sizeof(ro) / sizeof(*ro); i++) CHECK(!sidecar_ext_modifiable(ro[i]));

    /* prefix rule */
    CHECK(sidecar_prefix_match("M24-1546", "M24-1546.gyroflow"));
    CHECK(sidecar_prefix_match("M24-1546", "M24-1546MLV_1_2026-10-24_0001_C0000.gyroflow"));
    CHECK(sidecar_prefix_match("M24-1546", "m24-1546mlv_x.json"));
    CHECK(sidecar_prefix_match("M24-1546", "M24-1546_gyro.gcsv"));
    CHECK(sidecar_prefix_match("M24-1546", "M24-1546 copy.json"));
    CHECK(!sidecar_prefix_match("M24-15", "M24-1546.gyroflow"));
    CHECK(!sidecar_prefix_match("M24-1546", "M24-1546B.gyroflow"));
    CHECK(!sidecar_prefix_match("M24-1546", "M24-1546"));
    CHECK(!sidecar_prefix_match("M24-1546", "odd.txt"));
    CHECK(!sidecar_prefix_match("", "x.txt"));

    /* Unicode: NFC "é" (c3 a9) and NFD "e + U+0301" (65 cc 81) name the same file */
    const char *nfc = "\x63\x61\x66\xc3\xa9.txt", *nfd = "\x63\x61\x66\x65\xcc\x81.txt";
    CHECK(sidecar_name_equal(nfc, nfd) && sidecar_name_equal("Odd.TXT", "odd.txt"));
    CHECK(!sidecar_name_equal(nfc, "cafe.txt"));

    /* index in memory, JSON round trip with awkward names */
    struct sidecar_index idx = {0};
    CHECK(sidecar_index_set(&idx, "odd-name.txt", "M24-1546"));
    CHECK(sidecar_index_set(&idx, "été \"q\" \\ x\t.json", "M24-15"));
    CHECK(!sidecar_index_set(&idx, "odd-name.txt", "M24-1546"));
    CHECK(sidecar_index_set(&idx, "odd-name.txt", "M24-15"));
    CHECK(sidecar_index_set_created(&idx, "temp.bin", 1));
    CHECK(sidecar_index_set_created(&idx, "odd-name.txt", 1));
    CHECK(strcmp(sidecar_index_get(&idx, "odd-name.txt"), "M24-15") == 0);
    CHECK(sidecar_index_set(&idx, nfc, "M24-1546"));
    CHECK(sidecar_index_get(&idx, nfd) && strcmp(sidecar_index_get(&idx, nfd), "M24-1546") == 0);
    char *json = sidecar_index_serialize(&idx);
    CHECK(json && strstr(json, "\"files\"") && strstr(json, "\"created\""));
    struct sidecar_index back = {0};
    CHECK(sidecar_index_parse(json, &back) == 1);
    CHECK(back.count == 4);
    CHECK(strcmp(sidecar_index_get(&back, "été \"q\" \\ x\t.json"), "M24-15") == 0);
    CHECK(sidecar_index_created(&back, "temp.bin") && sidecar_index_get(&back, "temp.bin") == NULL);
    CHECK(sidecar_index_created(&back, "odd-name.txt") && !sidecar_index_created(&back, nfc));
    free(json);
    sidecar_index_free(&back);
    CHECK(sidecar_index_set(&idx, "odd-name.txt", NULL));
    CHECK(sidecar_index_created(&idx, "odd-name.txt"));
    CHECK(sidecar_index_set_created(&idx, "odd-name.txt", 0));
    CHECK(sidecar_index_get(&idx, "odd-name.txt") == NULL && !sidecar_index_created(&idx, "odd-name.txt"));
    CHECK(!sidecar_index_set(&idx, "absent", NULL) && !sidecar_index_set_created(&idx, "absent", 0));
    CHECK(idx.count == 3);

    /* ownership: index association wins over the prefix rule */
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
    CHECK(sidecar_index_parse("{\"version\": 2}", &bad) == 0);
    CHECK(sidecar_index_parse("{\"files\": {}} trailing", &bad) == 0);
    CHECK(sidecar_index_parse("{\"files\": {\"\\u00e9.txt\": \"C\"}, \"version\": 1}", &bad) == 1);
    CHECK(bad.count == 1 && strcmp(bad.entries[0].name, "\xc3\xa9.txt") == 0);
    sidecar_index_free(&bad);

    /* disk */
    char dir[] = "/tmp/sidecar_test_XXXXXX";
    CHECK(mkdtemp(dir) != NULL);
    char path[512], other[512];
    snprintf(path, sizeof(path), "%s/%s", dir, SIDECAR_INDEX_NAME);
    struct stat st;
    struct sidecar_change clear_x = { "x.txt", SIDECAR_CLEAR, NULL, SIDECAR_CLEAR };
    CHECK(sidecar_index_apply(dir, &clear_x, 1) == 0);
    CHECK(stat(path, &st) != 0);  /* nothing created just to clear */
    struct sidecar_change two[] = { { "x.txt", SIDECAR_SET, "M24-1546", SIDECAR_KEEP },
                                    { "y.bin", SIDECAR_KEEP, NULL, SIDECAR_SET } };
    CHECK(sidecar_index_apply(dir, two, 2) == 0);
    char *text = slurp(path);
    CHECK(text && strstr(text, "x.txt") && strstr(text, "y.bin"));
    free(text);
    struct sidecar_index disk = {0};
    CHECK(sidecar_index_load(dir, &disk) == 0);
    CHECK(disk.count == 2 && sidecar_index_created(&disk, "y.bin"));
    sidecar_index_free(&disk);
    CHECK(sidecar_index_writable(dir) == 0);

    /* a malformed index is never overwritten */
    spit(path, "{\"files\": {\"x.txt\": ");
    struct sidecar_change set_z = { "z.txt", SIDECAR_SET, "C", SIDECAR_KEEP };
    CHECK(sidecar_index_apply(dir, &set_z, 1) == -EIO);
    CHECK(sidecar_index_writable(dir) == -EIO);
    text = slurp(path);
    CHECK(text && strcmp(text, "{\"files\": {\"x.txt\": ") == 0);
    free(text);

    /* a symlinked or hard-linked index is refused (never followed, never written through) */
    unlink(path);
    snprintf(other, sizeof(other), "%s/victim", dir);
    spit(other, "{\"files\": {}}");
    CHECK(symlink(other, path) == 0);
    CHECK(sidecar_index_apply(dir, &set_z, 1) == -EACCES);
    text = slurp(other);
    CHECK(text && strcmp(text, "{\"files\": {}}") == 0);
    free(text);
    unlink(path);
    CHECK(link(other, path) == 0);
    CHECK(sidecar_index_apply(dir, &set_z, 1) == -EACCES);
    unlink(path);
    unlink(other);

    /* concurrent updates: 8 threads x 20 names, all kept */
    thread_dir = dir;
    pthread_t th[8];
    for (long i = 0; i < 8; i++) pthread_create(&th[i], NULL, apply_thread, (void *)i);
    int thread_errors = 0;
    for (int i = 0; i < 8; i++)
    {
        void *ret;
        pthread_join(th[i], &ret);
        if (ret) thread_errors++;
    }
    CHECK(thread_errors == 0);
    CHECK(sidecar_index_load(dir, &disk) == 0 && disk.count == 160);
    sidecar_index_free(&disk);
    /* no temp file left behind */
    char cmd[600];
    snprintf(cmd, sizeof(cmd), "ls -a '%s' | grep -c tmp >/dev/null", dir);
    CHECK(system(cmd) != 0);
    for (long n = 0; n < 8; n++)
        for (int i = 0; i < 20; i++)
        {
            char name[64];
            snprintf(name, sizeof(name), "t%ld-%d.bin", n, i);
            struct sidecar_change c = { name, SIDECAR_CLEAR, NULL, SIDECAR_CLEAR };
            sidecar_index_apply(dir, &c, 1);
        }
    CHECK(stat(path, &st) != 0); /* last removal deletes the index */
    rmdir(dir);

    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("sidecar_test: all checks passed\n");
    return 0;
}
