/*
 * Copyright (C) 2014 David Milligan
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the
 * Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor,
 * Boston, MA  02110-1301, USA.
 */

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <fuse.h>
#include "index.h"
#include "mlvfs.h"
#include "resource_manager.h"
#include "dual_iso_switch.h"
#include "sys/stat.h"

//some macros for simple thread synchronization
#define CREATE_MUTEX(x) static pthread_mutex_t x = PTHREAD_MUTEX_INITIALIZER;
#define LOCK(x) static pthread_mutex_t x = PTHREAD_MUTEX_INITIALIZER; pthread_mutex_lock(&x);
#define RELOCK(x) pthread_mutex_lock(&(x));
#define UNLOCK(x) pthread_mutex_unlock(&(x));
#define CURRENT_THREAD (pthread_self())
#define INIT_LOCK(x) pthread_mutex_init(&(x), NULL)
#define DESTROY_LOCK(x) pthread_mutex_destroy(&(x))

#define MAX_UNUSED_IMAGE_BUFFER_COUNT 4
#define MAX_TOTAL_IMAGE_BUFFER_COUNT 16

CREATE_MUTEX(image_buffer_mutex)

static void image_buffer_cleanup();

static struct image_buffer * image_buffers = NULL;

static int image_buffer_count = 0;

/* Only buffers decoded in the current dual ISO mode generation are returned. */
static struct image_buffer * get_image_buffer(const char * dng_filename, unsigned generation)
{
    for(struct image_buffer * current = image_buffers; current != NULL; current = current->next)
    {
        if(current->generation == generation && !strcmp(current->dng_filename, dng_filename)) return current;
    }
    return NULL;
}

static void free_image_buffer(struct image_buffer * image_buffer);

/* Frees buffers of an older dual ISO mode generation that no handle references.
   Caller holds image_buffer_mutex, which guards every ref_count. */
static void purge_stale_image_buffers(unsigned generation)
{
    struct image_buffer * current = image_buffers;
    while(current != NULL)
    {
        struct image_buffer * next = current->next;
        if(current->generation != generation && current->ref_count == 0) free_image_buffer(current);
        current = next;
    }
}

static struct image_buffer * new_image_buffer(const char * dng_filename, unsigned generation)
{
    image_buffer_cleanup();
    struct image_buffer * new_buffer = malloc(sizeof(struct image_buffer));
    if(new_buffer == NULL) return NULL;
    
    image_buffer_count++;
    memset(new_buffer, 0, sizeof(struct image_buffer));
    
    if(image_buffers == NULL)
    {
        image_buffers = new_buffer;
    }
    else
    {
        struct image_buffer * current = image_buffers;
        while(current->next != NULL)
        {
            current = current->next;
        }
        current->next = new_buffer;
    }
    new_buffer->dng_filename = malloc((sizeof(char) * (strlen(dng_filename) + 2)));
    if (!new_buffer->dng_filename)
    {
        free(new_buffer);
        return NULL;
    }
    strcpy(new_buffer->dng_filename, dng_filename);
    new_buffer->generation = generation;
    INIT_LOCK(new_buffer->mutex);
    return new_buffer;
}

struct image_buffer * get_or_create_image_buffer(const char * path, int(*new_buffer_cbr)(struct image_buffer *), int * was_created)
{
    struct image_buffer * image_buffer = NULL;
    *was_created = 0;
    
    /* read before the frame callback reads the mode: a buffer is never tagged newer than the mode it was decoded in */
    unsigned generation = dual_iso_generation();

    RELOCK(image_buffer_mutex)
    {
        /* only when the generation is still current: never purge on behalf of a lookup that is already stale */
        if(generation == dual_iso_generation()) purge_stale_image_buffers(generation);
        image_buffer = get_image_buffer(path, generation);
        if(!image_buffer)
        {
            image_buffer = new_image_buffer(path, generation);
            if(image_buffer) *was_created = 1;
        }
        /* the caller's reference: nothing frees the buffer until release_image_buffer() */
        if(image_buffer) image_buffer->ref_count++;
    }
    UNLOCK(image_buffer_mutex)
    
    if(!image_buffer) return NULL;
    
    if(new_buffer_cbr) ensure_image_buffer_data(image_buffer, new_buffer_cbr);
    
    return image_buffer;
}

void ensure_image_buffer_data(struct image_buffer * image_buffer, int(*new_buffer_cbr)(struct image_buffer *))
{
    RELOCK(image_buffer->mutex)
    {
        if(!image_buffer->data)
        {
            new_buffer_cbr(image_buffer);
        }
    }
    UNLOCK(image_buffer->mutex)
}

static void free_image_buffer(struct image_buffer * image_buffer)
{
    if(!image_buffer) return;
    
    if(image_buffer == image_buffers)
    {
        image_buffers = image_buffer->next;
    }
    else
    {
        struct image_buffer * current = image_buffers;
        while(current->next != NULL)
        {
            if(current->next == image_buffer) break;
            current = current->next;
        }
        current->next = image_buffer->next;
    }
    
    DESTROY_LOCK(image_buffer->mutex);
    free(image_buffer->dng_filename);
    free(image_buffer->data);
    free(image_buffer->header);
    free(image_buffer);
    image_buffer_count--;
}

void release_image_buffer(struct image_buffer * image_buffer)
{
    if(!image_buffer) return;
    RELOCK(image_buffer_mutex)
    {
        if(image_buffer->ref_count > 0) image_buffer->ref_count--;
        else err_printf("image buffer %s released more often than acquired\n", image_buffer->dng_filename);
    }
    UNLOCK(image_buffer_mutex)
}

int get_image_buffer_ref_count(struct image_buffer * image_buffer)
{
    int n = 0;
    RELOCK(image_buffer_mutex)
    {
        n = image_buffer->ref_count;
    }
    UNLOCK(image_buffer_mutex)
    return n;
}

void free_all_image_buffers()
{
    struct image_buffer * next = NULL;
    struct image_buffer * current = image_buffers;
    while(current != NULL)
    {
        next = current->next;
        free(current->dng_filename);
        free(current->data);
        free(current->header);
        free(current);
        current = next;
    }
}

int get_image_buffer_count()
{
    return image_buffer_count;
}

/*
 * Frees unreferenced image_buffers, oldest first (appearing first in the linked list), down to
 * MAX_UNUSED_IMAGE_BUFFER_COUNT. A referenced buffer is never freed: a handle may be reading it.
 * Caller holds image_buffer_mutex.
 */
static void image_buffer_cleanup()
{
    while (get_image_buffer_count() > MAX_UNUSED_IMAGE_BUFFER_COUNT)
    {
        struct image_buffer * victim = NULL;
        for(struct image_buffer * current = image_buffers; current != NULL; current = current->next)
        {
            if(current->ref_count == 0) { victim = current; break; }
        }
        if(!victim) break;
        free_image_buffer(victim);
    }
    if (get_image_buffer_count() > MAX_TOTAL_IMAGE_BUFFER_COUNT)
    {
        err_printf("%d image buffers still referenced (open handles)\n", get_image_buffer_count());
    }
}

#ifdef KEEP_FILES_OPEN
static struct mlv_chunks * loaded_chunks = NULL;

static struct mlv_chunks * get_chunks(const char * path)
{
    for(struct mlv_chunks * current = loaded_chunks; current != NULL; current = current->next)
    {
        if(current->thread_id == CURRENT_THREAD && !filename_strcmp(current->path, path)) return current;
    }
    return NULL;
}

static struct mlv_chunks * new_chunks(const char * path, FILE** files, uint32_t chunk_count)
{
    struct mlv_chunks * new_buffer = (struct mlv_chunks *)malloc(sizeof(struct mlv_chunks));
    if(new_buffer == NULL) return NULL;
    
    if(loaded_chunks == NULL)
    {
        loaded_chunks = new_buffer;
    }
    else
    {
        struct mlv_chunks * current = loaded_chunks;
        while(current->next != NULL)
        {
            current = current->next;
        }
        current->next = new_buffer;
    }
    new_buffer->path = (char*)malloc((sizeof(char) * (strlen(path) + 2)));
    strcpy(new_buffer->path, path);
    new_buffer->next = NULL;
    new_buffer->chunks = files;
    new_buffer->chunk_count = chunk_count;
    new_buffer->thread_id = CURRENT_THREAD;
    return new_buffer;
}
#endif

void close_all_chunks()
{
#ifdef KEEP_FILES_OPEN
    struct mlv_chunks * next = NULL;
    struct mlv_chunks * current = loaded_chunks;
    while(current != NULL)
    {
        next = current->next;
        free(current->path);
        close_chunks(current->chunks, current->chunk_count);
        free(current);
        current = next;
    }
#endif
}

FILE** mlvfs_load_chunks(const char * path, uint32_t * chunk_count)
{
#ifdef KEEP_FILES_OPEN
    FILE **chunk_files = NULL;
    *chunk_count = 0;
    
    LOCK(chunk_load_mutex)
    {
        struct mlv_chunks * mlv_chunks = get_chunks(path);
        if(!mlv_chunks)
        {
            chunk_files = load_chunks(path, chunk_count);
            new_chunks(path, chunk_files, *chunk_count);
        }
        else
        {
            chunk_files = mlv_chunks->chunks;
            *chunk_count = mlv_chunks->chunk_count;
        }
    }
    UNLOCK(chunk_load_mutex)
    return chunk_files;
#else
    return load_chunks(path, chunk_count);
#endif
}

void mlvfs_close_chunks(FILE **chunk_files, uint32_t chunk_count)
{
#ifndef KEEP_FILES_OPEN
    close_chunks(chunk_files, chunk_count);
#endif
}

CREATE_MUTEX(dng_attr_mapping_mutex)

static struct dng_attr_mapping * dng_attr_mappings = NULL;

static struct FUSE_STAT * lookup_dng_attr_internal(const char * path)
{
    for(struct dng_attr_mapping * current = dng_attr_mappings; current != NULL; current = current->next)
    {
        if(!filename_strcmp(current->path, path)) return current->attr;
    }
    return NULL;
}

struct FUSE_STAT * lookup_dng_attr(const char * path)
{
    struct FUSE_STAT * result = NULL;
    RELOCK(dng_attr_mapping_mutex)
    {
        result = lookup_dng_attr_internal(path);
    }
    UNLOCK(dng_attr_mapping_mutex)
    return result;
}

void register_dng_attr(const char * path, struct FUSE_STAT *attr)
{
    RELOCK(dng_attr_mapping_mutex)
    {
        if(!lookup_dng_attr_internal(path))
        {
            struct dng_attr_mapping * new_buffer = (struct dng_attr_mapping *)malloc(sizeof(struct dng_attr_mapping));
            if(new_buffer)
            {
                new_buffer->path = (char*)malloc((sizeof(char) * (strlen(path) + 2)));
                if (!new_buffer->path)
                {
                    UNLOCK(dng_attr_mapping_mutex)
                    return;
                }
                strcpy(new_buffer->path, path);
                new_buffer->attr = (struct FUSE_STAT*)malloc(sizeof(struct FUSE_STAT));
                if (!new_buffer->attr)
                {
                    free(new_buffer->path);
                    UNLOCK(dng_attr_mapping_mutex)
                    return;
                }
                memcpy(new_buffer->attr, attr, sizeof(struct FUSE_STAT));
                new_buffer->next = dng_attr_mappings;
                dng_attr_mappings = new_buffer;
            }
        }
    }
    UNLOCK(dng_attr_mapping_mutex)
}

void free_dng_attr_mappings()
{
    RELOCK(dng_attr_mapping_mutex)
    {
        struct dng_attr_mapping * next = NULL;
        struct dng_attr_mapping * current = dng_attr_mappings;
        while(current != NULL)
        {
            next = current->next;
            free(current->path);
            free(current->attr);
            free(current);
            current = next;
        }
    }
    UNLOCK(dng_attr_mapping_mutex)
}