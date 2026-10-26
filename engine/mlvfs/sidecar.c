/*
 * mlv2Resolve sidecar files: name rules, path policy and the per-folder index. See sidecar.h.
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
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#endif
#include "sidecar.h"

static int ends_with_ci(const char *s, const char *end)
{
    size_t n = strlen(s), m = strlen(end);
    return n >= m && strcasecmp(s + n - m, end) == 0;
}

int sidecar_name_protected(const char *name)
{
    if (!name) return 1;
    if (strncasecmp(name, SIDECAR_INDEX_PREFIX, strlen(SIDECAR_INDEX_PREFIX)) == 0) return 1;
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
    return strcmp(name, ".") == 0 || strcmp(name, "..") == 0
        || strncasecmp(name, SIDECAR_INDEX_PREFIX, strlen(SIDECAR_INDEX_PREFIX)) == 0
        || strcasecmp(name, ".DS_Store") == 0 || strncmp(name, "._", 2) == 0;
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

int sidecar_ext_modifiable(const char *name)
{
    static const char *exts[] = SIDECAR_MODIFIABLE_EXTS;
    const char *dot = name ? strrchr(name, '.') : NULL;
    if (!dot || dot == name) return 0;
    for (size_t i = 0; i < sizeof(exts) / sizeof(*exts); i++)
        if (strcasecmp(dot + 1, exts[i]) == 0) return 1;
    return 0;
}

int sidecar_name_equal(const char *a, const char *b)
{
    if (!a || !b) return 0;
    if (strcmp(a, b) == 0) return 1;
#ifdef __APPLE__
    CFStringRef sa = CFStringCreateWithCString(NULL, a, kCFStringEncodingUTF8);
    CFStringRef sb = CFStringCreateWithCString(NULL, b, kCFStringEncodingUTF8);
    int eq = 0;
    if (sa && sb)
        eq = CFStringCompare(sa, sb, kCFCompareNonliteral | kCFCompareCaseInsensitive) == kCFCompareEqualTo;
    if (sa) CFRelease(sa);
    if (sb) CFRelease(sb);
    return eq;
#else
    return strcasecmp(a, b) == 0;
#endif
}

char *sidecar_appledouble_subject(const char *path)
{
    if (!path) return NULL;
    const char *slash = strrchr(path, '/');
    const char *name = slash ? slash + 1 : path;
    if (strncmp(name, "._", 2) != 0 || name[2] == 0 || strncmp(name + 2, "._", 2) == 0) return NULL;
    size_t dir_len = (size_t)(name - path);
    char *subject = malloc(strlen(path));
    if (!subject) return NULL;
    memcpy(subject, path, dir_len);
    strcpy(subject + dir_len, name + 2);
    return subject;
}

int sidecar_path_check(const char *path)
{
    if (!path) return -EACCES;
    char *subject = sidecar_appledouble_subject(path);
    if (subject)
    {
        int r = sidecar_path_check(subject);
        free(subject);
        return r;
    }
    const char *slash = strrchr(path, '/');
    const char *name = slash ? slash + 1 : path;
    if (*name == 0 || sidecar_name_hidden(name) || sidecar_name_protected(name)) return -EACCES;

    /* every intermediate component: not ".", "..", empty-after-root, hidden, or a .MLD/.IDX folder */
    const char *p = path;
    while (*p == '/') p++;
    while (p < name)
    {
        const char *end = strchr(p, '/');
        if (!end || end > name) end = name;
        size_t len = (size_t)(end - p);
        if (len > 0)
        {
            char comp[1024];
            if (len >= sizeof(comp)) return -EACCES;
            memcpy(comp, p, len);
            comp[len] = 0;
            if (sidecar_name_hidden(comp) || ends_with_ci(comp, ".MLD") || ends_with_ci(comp, ".IDX")) return -EACCES;
        }
        p = end + 1;
    }
    return 0;
}

/* ---- in-memory index ---- */

static struct sidecar_entry *find_entry(const struct sidecar_index *idx, const char *name)
{
    if (!idx || !name) return NULL;
    for (size_t i = 0; i < idx->count; i++)
        if (strcmp(idx->entries[i].name, name) == 0) return &idx->entries[i];
    for (size_t i = 0; i < idx->count; i++)
        if (sidecar_name_equal(idx->entries[i].name, name)) return &idx->entries[i];
    return NULL;
}

const char *sidecar_index_get(const struct sidecar_index *idx, const char *name)
{
    struct sidecar_entry *e = find_entry(idx, name);
    return e ? e->clip : NULL;
}

int sidecar_index_created(const struct sidecar_index *idx, const char *name)
{
    struct sidecar_entry *e = find_entry(idx, name);
    return e ? e->created : 0;
}

static struct sidecar_entry *add_entry(struct sidecar_index *idx, const char *name)
{
    struct sidecar_entry *entries = realloc(idx->entries, (idx->count + 1) * sizeof(*entries));
    if (!entries) return NULL;
    idx->entries = entries;
    char *n = strdup(name);
    if (!n) return NULL;
    struct sidecar_entry *e = &idx->entries[idx->count++];
    e->name = n;
    e->clip = NULL;
    e->created = 0;
    return e;
}

static void drop_if_empty(struct sidecar_index *idx, struct sidecar_entry *e)
{
    if (e->clip || e->created) return;
    free(e->name);
    *e = idx->entries[idx->count - 1];
    idx->count--;
}

int sidecar_index_set(struct sidecar_index *idx, const char *name, const char *clip)
{
    struct sidecar_entry *e = find_entry(idx, name);
    if (!e)
    {
        if (!clip) return 0;
        e = add_entry(idx, name);
        if (!e) return 0;
    }
    if (clip && e->clip && strcmp(e->clip, clip) == 0) return 0;
    if (!clip && !e->clip) return 0;
    char *c = clip ? strdup(clip) : NULL;
    if (clip && !c) return 0;
    free(e->clip);
    e->clip = c;
    drop_if_empty(idx, e);
    return 1;
}

int sidecar_index_set_created(struct sidecar_index *idx, const char *name, int created)
{
    struct sidecar_entry *e = find_entry(idx, name);
    if (!e)
    {
        if (!created) return 0;
        e = add_entry(idx, name);
        if (!e) return 0;
    }
    if (!!e->created == !!created) return 0;
    e->created = !!created;
    drop_if_empty(idx, e);
    return 1;
}

void sidecar_index_free(struct sidecar_index *idx)
{
    if (!idx) return;
    for (size_t i = 0; i < idx->count; i++)
    {
        free(idx->entries[i].name);
        free(idx->entries[i].clip);
    }
    free(idx->entries);
    idx->entries = NULL;
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

/* a name with a separator can never be a sidecar of a flat folder */
static int usable_name(const char *name)
{
    return name && *name && !strchr(name, '/');
}

static int parse_files(const char **pp, struct sidecar_index *idx)
{
    const char *p = skip_ws(*pp);
    if (*p != '{') return 0;
    p = skip_ws(p + 1);
    while (*p != '}')
    {
        char *name = parse_string(&p);
        if (!name) return 0;
        p = skip_ws(p);
        if (*p != ':') { free(name); return 0; }
        p = skip_ws(p + 1);
        char *clip = parse_string(&p);
        if (!clip) { free(name); return 0; }
        if (usable_name(name) && *clip) sidecar_index_set(idx, name, clip);
        free(name);
        free(clip);
        p = skip_ws(p);
        if (*p == ',') p = skip_ws(p + 1);
        else if (*p != '}') return 0;
    }
    *pp = p + 1;
    return 1;
}

static int parse_created(const char **pp, struct sidecar_index *idx)
{
    const char *p = skip_ws(*pp);
    if (*p != '[') return 0;
    p = skip_ws(p + 1);
    while (*p != ']')
    {
        char *name = parse_string(&p);
        if (!name) return 0;
        if (usable_name(name)) sidecar_index_set_created(idx, name, 1);
        free(name);
        p = skip_ws(p);
        if (*p == ',') p = skip_ws(p + 1);
        else if (*p != ']') return 0;
    }
    *pp = p + 1;
    return 1;
}

/* skips any JSON scalar or string value (for the "about"/"version" keys) */
static int skip_value(const char **pp)
{
    const char *p = skip_ws(*pp);
    if (*p == '"')
    {
        char *s = parse_string(&p);
        if (!s) return 0;
        free(s);
    }
    else
    {
        const char *start = p;
        while (*p && (isalnum((unsigned char)*p) || *p == '-' || *p == '.' || *p == '+')) p++;
        if (p == start) return 0;
    }
    *pp = p;
    return 1;
}

int sidecar_index_parse(const char *json, struct sidecar_index *idx)
{
    idx->count = 0;
    idx->entries = NULL;
    if (!json) return 0;
    const char *p = skip_ws(json);
    if (*p != '{') return 0;
    p = skip_ws(p + 1);
    int seen_files = 0;
    while (*p != '}')
    {
        char *key = parse_string(&p);
        if (!key) goto bad;
        p = skip_ws(p);
        if (*p != ':') { free(key); goto bad; }
        p++;
        int ok;
        if (strcmp(key, "files") == 0) { ok = parse_files(&p, idx); seen_files = 1; }
        else if (strcmp(key, "created") == 0) ok = parse_created(&p, idx);
        else ok = skip_value(&p);
        free(key);
        if (!ok) goto bad;
        p = skip_ws(p);
        if (*p == ',') p = skip_ws(p + 1);
        else if (*p != '}') goto bad;
    }
    if (*skip_ws(p + 1) != 0) goto bad;
    if (!seen_files) goto bad;
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
        "  \"about\": \"mlv2Resolve: files saved through the mount. files: name -> clip folder showing it (MLV name without extension); created: names created through the mount\",\n"
        "  \"version\": 2,\n"
        "  \"files\": {";
    size_t cap = sizeof(head) + 64;
    for (size_t i = 0; i < idx->count; i++)
        cap += 12 * (strlen(idx->entries[i].name) + (idx->entries[i].clip ? strlen(idx->entries[i].clip) : 0)) + 32;
    char *out = malloc(cap);
    if (!out) return NULL;
    size_t len = sizeof(head) - 1;
    memcpy(out, head, len);
    int n = 0;
    for (size_t i = 0; i < idx->count; i++)
    {
        if (!idx->entries[i].clip) continue;
        len += (size_t)sprintf(out + len, "%s\n    ", n++ ? "," : "");
        put_json_string(out, &len, idx->entries[i].name);
        out[len++] = ':';
        out[len++] = ' ';
        put_json_string(out, &len, idx->entries[i].clip);
    }
    len += (size_t)sprintf(out + len, "%s},\n  \"created\": [", n ? "\n  " : "");
    n = 0;
    for (size_t i = 0; i < idx->count; i++)
    {
        if (!idx->entries[i].created) continue;
        len += (size_t)sprintf(out + len, "%s\n    ", n++ ? "," : "");
        put_json_string(out, &len, idx->entries[i].name);
    }
    len += (size_t)sprintf(out + len, "%s]\n}\n", n ? "\n  " : "");
    return out;
}

/* ---- disk ---- */

/* FUSE is multithreaded: every load and update of any index goes through this lock */
static pthread_mutex_t index_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned long temp_counter = 0;

static char *dir_file(const char *dir, const char *name)
{
    size_t n = strlen(dir) + strlen(name) + 2;
    char *p = malloc(n);
    if (p) snprintf(p, n, "%s/%s", dir, name);
    return p;
}

/* 0 loaded or missing, -EIO malformed/unreadable, -EACCES not a regular file */
static int load_unlocked(const char *dir, struct sidecar_index *idx)
{
    idx->count = 0;
    idx->entries = NULL;
    char *path = dir_file(dir, SIDECAR_INDEX_NAME);
    if (!path) return -ENOMEM;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    int err = errno;
    free(path);
    if (fd < 0) return err == ENOENT ? 0 : (err == ELOOP ? -EACCES : -EIO);
    int result = -EIO;
    struct stat st;
    if (fstat(fd, &st) != 0) result = -EIO;
    else if (!S_ISREG(st.st_mode) || st.st_nlink > 1) result = -EACCES;
    else if (st.st_size == 0) result = 0;
    else if (st.st_size < (16 << 20))
    {
        char *buf = malloc((size_t)st.st_size + 1);
        if (buf)
        {
            ssize_t got = pread(fd, buf, (size_t)st.st_size, 0);
            if (got == st.st_size)
            {
                buf[got] = 0;
                if (sidecar_index_parse(buf, idx)) result = 0;
            }
            free(buf);
        }
    }
    close(fd);
    if (result != 0)
    {
        sidecar_index_free(idx);
        fprintf(stderr, "mlv2Resolve: sidecar index in %s is %s; it is kept as is and not updated\n", dir,
                result == -EACCES ? "not a regular file" : "unreadable or malformed");
    }
    return result;
}

int sidecar_index_load(const char *dir, struct sidecar_index *idx)
{
    pthread_mutex_lock(&index_lock);
    int r = load_unlocked(dir, idx);
    pthread_mutex_unlock(&index_lock);
    return r;
}

int sidecar_index_writable(const char *dir)
{
    struct sidecar_index idx;
    int r = sidecar_index_load(dir, &idx);
    sidecar_index_free(&idx);
    return r;
}

static int write_all(int fd, const char *data, size_t len)
{
    size_t done = 0;
    while (done < len)
    {
        ssize_t w = write(fd, data + done, len - done);
        if (w < 0) { if (errno == EINTR) continue; return -errno; }
        done += (size_t)w;
    }
    return 0;
}

static int store_unlocked(const char *dir, const struct sidecar_index *idx)
{
    char *path = dir_file(dir, SIDECAR_INDEX_NAME);
    if (!path) return -ENOMEM;
    int result = 0;
    if (idx->count == 0)
    {
        if (unlink(path) != 0 && errno != ENOENT) result = -errno;
        free(path);
        return result;
    }
    char *json = sidecar_index_serialize(idx);
    char tmpname[128];
    snprintf(tmpname, sizeof(tmpname), "%s.tmp.%d.%lu", SIDECAR_INDEX_NAME, (int)getpid(), ++temp_counter);
    char *tmp = dir_file(dir, tmpname);
    if (!json || !tmp) result = -ENOMEM;
    else
    {
        int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
        if (fd < 0) result = -errno;
        else
        {
            result = write_all(fd, json, strlen(json));
            if (result == 0 && fsync(fd) != 0) result = -errno;
            if (close(fd) != 0 && result == 0) result = -errno;
            if (result == 0 && rename(tmp, path) != 0) result = -errno;
            if (result != 0) unlink(tmp);
        }
    }
    free(json);
    free(tmp);
    free(path);
    return result;
}

int sidecar_index_apply(const char *dir, const struct sidecar_change *changes, size_t count)
{
    pthread_mutex_lock(&index_lock);
    struct sidecar_index idx;
    int result = load_unlocked(dir, &idx);
    if (result == 0)
    {
        int changed = 0;
        for (size_t i = 0; i < count; i++)
        {
            const struct sidecar_change *c = &changes[i];
            if (!usable_name(c->name)) continue;
            if (c->clip_op == SIDECAR_SET) changed |= sidecar_index_set(&idx, c->name, c->clip);
            else if (c->clip_op == SIDECAR_CLEAR) changed |= sidecar_index_set(&idx, c->name, NULL);
            if (c->created_op == SIDECAR_SET) changed |= sidecar_index_set_created(&idx, c->name, 1);
            else if (c->created_op == SIDECAR_CLEAR) changed |= sidecar_index_set_created(&idx, c->name, 0);
        }
        if (changed) result = store_unlocked(dir, &idx);
    }
    sidecar_index_free(&idx);
    pthread_mutex_unlock(&index_lock);
    return result;
}
