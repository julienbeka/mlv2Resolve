/*
 * Resolve-style clip folder name matching with POSIX <regex.h>. See resolve_name.h.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 */

#include <regex.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "resolve_name.h"

/* Former SLRE pattern "(.+)(MLV|mlv)_1_\d+-\d+-\d+_\d+_[C|c]\d+" with \d -> [0-9];
   the SLRE set [C|c] also accepted a literal '|', which no generated name contains. */
#define RESOLVE_NAME_PATTERN "(.+)(MLV|mlv)_1_[0-9]+-[0-9]+-[0-9]+_[0-9]+_[Cc][0-9]+"

static regex_t resolve_name_regex;
static int resolve_name_regex_ok = 0;
static pthread_once_t resolve_name_once = PTHREAD_ONCE_INIT;

static void resolve_name_compile(void)
{
    int rc = regcomp(&resolve_name_regex, RESOLVE_NAME_PATTERN, REG_EXTENDED);
    if (rc == 0)
    {
        resolve_name_regex_ok = 1;
    }
    else
    {
        char msg[128];
        regerror(rc, &resolve_name_regex, msg, sizeof(msg));
        fprintf(stderr, "resolve naming: regcomp failed: %s\n", msg);
    }
}

static char *copy_group(const char *s, regmatch_t m)
{
    if (m.rm_so < 0 || m.rm_eo < m.rm_so) return NULL;
    size_t len = (size_t)(m.rm_eo - m.rm_so);
    char *r = malloc(len + 1);
    if (!r) return NULL;
    memcpy(r, s + m.rm_so, len);
    r[len] = 0;
    return r;
}

int resolve_name_match(const char *path, char **base, char **ext)
{
    if (!path) return 0;
    pthread_once(&resolve_name_once, resolve_name_compile);
    if (!resolve_name_regex_ok) return 0;

    regmatch_t m[3];
    if (regexec(&resolve_name_regex, path, 3, m, 0) != 0) return 0;

    char *b = copy_group(path, m[1]);
    char *e = copy_group(path, m[2]);
    if (!b || !e)
    {
        free(b);
        free(e);
        return 0;
    }
    *base = b;
    *ext = e;
    return 1;
}
