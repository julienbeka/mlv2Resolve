/*
 * mlv2dng sidecar files: name rules and the per-folder index. See sidecar.h.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 */

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>
#include "sidecar.h"

static int ends_with_ci(const char *s, const char *end)
{
    size_t n = strlen(s), m = strlen(end);
    return n >= m && strcasecmp(s + n - m, end) == 0;
}

int sidecar_name_protected(const char *name)
{
    if (!name) return 1;
    if (strcmp(name, SIDECAR_INDEX_NAME) == 0) return 1;
    if (ends_with_ci(name, ".MLV") || ends_with_ci(name, ".IDX") || ends_with_ci(name, ".MLD")) return 1;
    size_t n = strlen(name);
    /* spanned MLV chunks: .M00 - .M99 */
    if (n >= 4 && name[n - 4] == '.' && (name[n - 3] == 'M' || name[n - 3] == 'm')
        && isdigit((unsigned char)name[n - 2]) && isdigit((unsigned char)name[n - 1]))
        return 1;
    return 0;
}

int sidecar_name_hidden(const char *name)
{
    if (!name) return 1;
    return strcmp(name, ".") == 0 || strcmp(name, "..") == 0 || strcmp(name, SIDECAR_INDEX_NAME) == 0
        || strcmp(name, ".DS_Store") == 0 || strncmp(name, "._", 2) == 0;
}

int sidecar_name_virtual(const char *name)
{
    if (!name) return 0;
    return ends_with_ci(name, ".dng") || ends_with_ci(name, ".wav") || ends_with_ci(name, ".gif")
        || ends_with_ci(name, ".log");
}

int sidecar_prefix_match(const char *base, const char *name)
{
    if (!base || !name) return 0;
    size_t n = strlen(base);
    if (n == 0 || strncasecmp(name, base, n) != 0) return 0;
    const char *rest = name + n;
    if (*rest == 0) return 0;
    if (!isalnum((unsigned char)*rest)) return 1;
    return strncasecmp(rest, "MLV", 3) == 0;
}

/* ---- in-memory index ---- */

const char *sidecar_index_get(const struct sidecar_index *idx, const char *name)
{
    if (!idx) return NULL;
    for (size_t i = 0; i < idx->count; i++)
        if (strcmp(idx->names[i], name) == 0) return idx->clips[i];
    return NULL;
}

int sidecar_index_set(struct sidecar_index *idx, const char *name, const char *clip)
{
    for (size_t i = 0; i < idx->count; i++)
    {
        if (strcmp(idx->names[i], name) != 0) continue;
        if (clip && strcmp(idx->clips[i], clip) == 0) return 0;
        if (clip)
        {
            char *c = strdup(clip);
            if (!c) return 0;
            free(idx->clips[i]);
            idx->clips[i] = c;
            return 1;
        }
        free(idx->names[i]);
        free(idx->clips[i]);
        idx->names[i] = idx->names[idx->count - 1];
        idx->clips[i] = idx->clips[idx->count - 1];
        idx->count--;
        return 1;
    }
    if (!clip) return 0;
    char **names = realloc(idx->names, (idx->count + 1) * sizeof(char *));
    if (!names) return 0;
    idx->names = names;
    char **clips = realloc(idx->clips, (idx->count + 1) * sizeof(char *));
    if (!clips) return 0;
    idx->clips = clips;
    char *n = strdup(name), *c = strdup(clip);
    if (!n || !c) { free(n); free(c); return 0; }
    idx->names[idx->count] = n;
    idx->clips[idx->count] = c;
    idx->count++;
    return 1;
}

void sidecar_index_free(struct sidecar_index *idx)
{
    if (!idx) return;
    for (size_t i = 0; i < idx->count; i++)
    {
        free(idx->names[i]);
        free(idx->clips[i]);
    }
    free(idx->names);
    free(idx->clips);
    idx->names = idx->clips = NULL;
    idx->count = 0;
}

int sidecar_owned_by(const struct sidecar_index *idx, const char *base, const char *name)
{
    const char *owner = sidecar_index_get(idx, name);
    if (owner) return strcmp(owner, base) == 0;
    return sidecar_prefix_match(base, name);
}

/* ---- JSON (only the subset written by sidecar_index_serialize, plus standard escapes) ---- */

static const char *skip_ws(const char *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

static void put_utf8(char *out, size_t *len, unsigned cp)
{
    if (cp < 0x80) out[(*len)++] = (char)cp;
    else if (cp < 0x800) { out[(*len)++] = (char)(0xC0 | (cp >> 6)); out[(*len)++] = (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000)
    {
        out[(*len)++] = (char)(0xE0 | (cp >> 12));
        out[(*len)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[(*len)++] = (char)(0x80 | (cp & 0x3F));
    }
    else
    {
        out[(*len)++] = (char)(0xF0 | (cp >> 18));
        out[(*len)++] = (char)(0x80 | ((cp >> 12) & 0x3F));
        out[(*len)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[(*len)++] = (char)(0x80 | (cp & 0x3F));
    }
}

static int hex4(const char *p, unsigned *v)
{
    *v = 0;
    for (int i = 0; i < 4; i++)
    {
        int c = p[i], d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else return 0;
        *v = *v * 16 + (unsigned)d;
    }
    return 1;
}

/* parses a JSON string at *pp (which points at '"'); returns malloc'ed UTF-8 or NULL */
static char *parse_string(const char **pp)
{
    const char *p = *pp;
    if (*p != '"') return NULL;
    p++;
    char *out = malloc(strlen(p) * 4 + 1);
    if (!out) return NULL;
    size_t len = 0;
    while (*p && *p != '"')
    {
        if ((unsigned char)*p < 0x20) { free(out); return NULL; }
        if (*p != '\\') { out[len++] = *p++; continue; }
        p++;
        unsigned cp;
        switch (*p)
        {
            case '"': out[len++] = '"'; break;
            case '\\': out[len++] = '\\'; break;
            case '/': out[len++] = '/'; break;
            case 'b': out[len++] = '\b'; break;
            case 'f': out[len++] = '\f'; break;
            case 'n': out[len++] = '\n'; break;
            case 'r': out[len++] = '\r'; break;
            case 't': out[len++] = '\t'; break;
            case 'u':
                if (!hex4(p + 1, &cp)) { free(out); return NULL; }
                p += 4;
                if (cp >= 0xD800 && cp < 0xDC00 && p[1] == '\\' && p[2] == 'u')
                {
                    unsigned lo;
                    if (hex4(p + 3, &lo) && lo >= 0xDC00 && lo < 0xE000)
                    {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        p += 6;
                    }
                }
                if (cp == 0) { free(out); return NULL; }
                put_utf8(out, &len, cp);
                break;
            default: free(out); return NULL;
        }
        p++;
    }
    if (*p != '"') { free(out); return NULL; }
    out[len] = 0;
    *pp = p + 1;
    return out;
}

int sidecar_index_parse(const char *json, struct sidecar_index *idx)
{
    idx->count = 0;
    idx->names = idx->clips = NULL;
    if (!json) return 0;
    const char *p = strstr(json, "\"files\"");
    if (!p) return 0;
    p = skip_ws(p + 7);
    if (*p != ':') return 0;
    p = skip_ws(p + 1);
    if (*p != '{') return 0;
    p = skip_ws(p + 1);
    while (*p != '}')
    {
        char *name = parse_string(&p);
        if (!name) goto bad;
        p = skip_ws(p);
        if (*p != ':') { free(name); goto bad; }
        p = skip_ws(p + 1);
        char *clip = parse_string(&p);
        if (!clip) { free(name); goto bad; }
        /* a name with a separator can never be a sidecar of a flat folder: ignore it */
        if (*name && *clip && !strchr(name, '/')) sidecar_index_set(idx, name, clip);
        free(name);
        free(clip);
        p = skip_ws(p);
        if (*p == ',') p = skip_ws(p + 1);
        else if (*p != '}') goto bad;
    }
    return 1;
bad:
    sidecar_index_free(idx);
    return 0;
}

static void put_json_string(char *out, size_t *len, const char *s)
{
    out[(*len)++] = '"';
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
    {
        if (*p == '"' || *p == '\\') { out[(*len)++] = '\\'; out[(*len)++] = (char)*p; }
        else if (*p < 0x20) *len += (size_t)sprintf(out + *len, "\\u%04x", *p);
        else out[(*len)++] = (char)*p;
    }
    out[(*len)++] = '"';
}

char *sidecar_index_serialize(const struct sidecar_index *idx)
{
    static const char head[] =
        "{\n"
        "  \"about\": \"mlv2dng: files saved through a clip folder of the mount, by file name -> clip (MLV name without extension)\",\n"
        "  \"version\": 1,\n"
        "  \"files\": {";
    size_t cap = sizeof(head) + 16;
    for (size_t i = 0; i < idx->count; i++) cap += 6 * (strlen(idx->names[i]) + strlen(idx->clips[i])) + 16;
    char *out = malloc(cap);
    if (!out) return NULL;
    size_t len = 0;
    memcpy(out, head, sizeof(head) - 1);
    len = sizeof(head) - 1;
    for (size_t i = 0; i < idx->count; i++)
    {
        len += (size_t)sprintf(out + len, "%s\n    ", i ? "," : "");
        put_json_string(out, &len, idx->names[i]);
        out[len++] = ':';
        out[len++] = ' ';
        put_json_string(out, &len, idx->clips[i]);
    }
    len += (size_t)sprintf(out + len, "%s}\n}\n", idx->count ? "\n  " : "");
    return out;
}

/* ---- disk ---- */

static pthread_mutex_t index_lock = PTHREAD_MUTEX_INITIALIZER;

static char *index_path(const char *dir)
{
    size_t n = strlen(dir) + strlen(SIDECAR_INDEX_NAME) + 2;
    char *p = malloc(n);
    if (p) snprintf(p, n, "%s/%s", dir, SIDECAR_INDEX_NAME);
    return p;
}

static void load_unlocked(const char *dir, struct sidecar_index *idx)
{
    idx->count = 0;
    idx->names = idx->clips = NULL;
    char *path = index_path(dir);
    if (!path) return;
    int fd = open(path, O_RDONLY);
    free(path);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size < (16 << 20))
    {
        char *buf = malloc((size_t)st.st_size + 1);
        if (buf)
        {
            ssize_t got = pread(fd, buf, (size_t)st.st_size, 0);
            if (got > 0)
            {
                buf[got] = 0;
                sidecar_index_parse(buf, idx);
            }
            free(buf);
        }
    }
    close(fd);
}

void sidecar_index_load(const char *dir, struct sidecar_index *idx)
{
    pthread_mutex_lock(&index_lock);
    load_unlocked(dir, idx);
    pthread_mutex_unlock(&index_lock);
}

int sidecar_index_update(const char *dir, const char *name, const char *clip)
{
    int result = 0;
    pthread_mutex_lock(&index_lock);
    struct sidecar_index idx;
    load_unlocked(dir, &idx);
    if (sidecar_index_set(&idx, name, clip))
    {
        char *path = index_path(dir);
        if (!path) result = -ENOMEM;
        else if (idx.count == 0)
        {
            if (unlink(path) != 0 && errno != ENOENT) result = -errno;
        }
        else
        {
            char *json = sidecar_index_serialize(&idx);
            int fd = json ? open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644) : -1;
            if (!json) result = -ENOMEM;
            else if (fd < 0) result = -errno;
            else
            {
                size_t len = strlen(json), done = 0;
                while (done < len)
                {
                    ssize_t w = write(fd, json + done, len - done);
                    if (w < 0) { if (errno == EINTR) continue; result = -errno; break; }
                    done += (size_t)w;
                }
                if (close(fd) != 0 && result == 0) result = -errno;
            }
            free(json);
        }
        free(path);
    }
    sidecar_index_free(&idx);
    pthread_mutex_unlock(&index_lock);
    return result;
}
