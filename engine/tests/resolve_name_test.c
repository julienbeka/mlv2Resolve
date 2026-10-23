/*
 * Unit test for resolve_name_match (--resolve-naming folder -> MLV path).
 *
 * Usage: make -C engine -f Makefile.arm64 resolve-name-test
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "resolve_name.h"

static int failures = 0;
static int checks = 0;

static void expect_match(const char *path, const char *want_base, const char *want_ext)
{
    char *base = NULL, *ext = NULL;
    checks++;
    int ok = resolve_name_match(path, &base, &ext);
    if (!ok)
    {
        printf("FAIL: no match for \"%s\"\n", path);
        failures++;
    }
    else if (strcmp(base, want_base) != 0 || strcmp(ext, want_ext) != 0)
    {
        printf("FAIL: \"%s\" -> base \"%s\" ext \"%s\", want \"%s\" \"%s\"\n", path, base, ext, want_base, want_ext);
        failures++;
    }
    else
    {
        printf("ok: \"%s\" -> \"%s\" + \"%s\"\n", path, base, ext);
    }
    free(base);
    free(ext);
}

static void expect_no_match(const char *path)
{
    char *base = (char *)"untouched", *ext = (char *)"untouched";
    checks++;
    if (resolve_name_match(path, &base, &ext))
    {
        printf("FAIL: unexpected match for \"%s\" -> \"%s\" \"%s\"\n", path, base, ext);
        free(base);
        free(ext);
        failures++;
    }
    else if (strcmp(base, "untouched") != 0 || strcmp(ext, "untouched") != 0)
    {
        printf("FAIL: outputs modified on no match for \"%s\"\n", path);
        failures++;
    }
    else
    {
        printf("ok: no match for \"%s\"\n", path);
    }
}

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    /* the canonical generated folder name */
    expect_match("/x/M29-0615MLV_1_2026-08-29_0001_C0000", "/x/M29-0615", "MLV");
    expect_match("M29-0615MLV_1_2026-08-29_0001_C0000", "M29-0615", "MLV");
    /* lowercase extension and lowercase c */
    expect_match("/x/clipmlv_1_2026-08-29_0001_C0000", "/x/clip", "mlv");
    expect_match("/x/clipMLV_1_2026-08-29_0001_c0042", "/x/clip", "MLV");
    /* unanchored like SLRE: a trailing suffix does not prevent the match */
    expect_match("/x/M23-1246MLV_1_2026-01-02_0001_C0000_extra", "/x/M23-1246", "MLV");
    /* spaces and accents (UTF-8 bytes) in the directory and the clip name */
    expect_match("/Tournage été 2026/Scène 1MLV_1_2026-08-29_0001_C0000", "/Tournage été 2026/Scène 1", "MLV");
    expect_match("/Volumes/EOS_DIGITAL/DCIM/100CANON/Prise à l'aube MLV_1_2026-08-29_0001_C0000",
                 "/Volumes/EOS_DIGITAL/DCIM/100CANON/Prise à l'aube ", "MLV");
    /* the greedy base keeps an earlier "MLV" inside the clip name */
    expect_match("/x/MLV_testMLV_1_2026-08-29_0001_C0000", "/x/MLV_test", "MLV");

    /* non-matching names */
    expect_no_match("");
    expect_no_match("/");
    expect_no_match("/x/M29-0615.MLV");
    expect_no_match("/x/M29-0615");
    expect_no_match("MLV_1_2026-08-29_0001_C0000");          /* empty base: (.+) needs one char */
    expect_no_match("/x/M29-0615MLV_2_2026-08-29_0001_C0000"); /* not _1_ */
    expect_no_match("/x/M29-0615MLV_1_2026-08-29_0001_D0000"); /* not C/c */
    expect_no_match("/x/M29-0615MLV_1_2026-08-29_0001_|0000"); /* SLRE's [C|c] accepted '|'; [Cc] does not */
    expect_no_match("/x/M29-0615MLV_1_2026-08_0001_C0000");    /* missing date field */
    expect_no_match("/x/M29-0615MLV_1_2026-08-29_0001_C");     /* no digits after C */
    expect_no_match("/x/M29-0615Mlv_1_2026-08-29_0001_C0000"); /* mixed-case extension */
    expect_no_match("/x/M29-0615MLV_1_2026-aa-29_0001_C0000"); /* non-digit date */

    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
