/*
 * Live dual ISO mode switching by signals. See dual_iso_switch.h.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 */

#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include "dual_iso_switch.h"

/* Written only by the signal handler (after init); -1 = no request. */
static volatile sig_atomic_t requested_mode = -1;

static pthread_mutex_t state_mutex = PTHREAD_MUTEX_INITIALIZER;
static int current_mode = 0;      /* guarded by state_mutex */
static unsigned generation = 0;   /* guarded by state_mutex */

static void dual_iso_signal_handler(int sig)
{
    /* async-signal-safe: a single store to a volatile sig_atomic_t */
    requested_mode = (sig == SIGUSR2) ? 2 : 1;
}

void dual_iso_switch_init(int initial_mode)
{
    pthread_mutex_lock(&state_mutex);
    current_mode = initial_mode;
    pthread_mutex_unlock(&state_mutex);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = dual_iso_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
}

/* Caller holds state_mutex. */
static int apply_pending_locked(void)
{
    int req = requested_mode;
    if (req < 0 || req == current_mode) return 0;
    current_mode = req;
    generation++;
    fprintf(stderr, "dual iso mode: %d\n", req);
    return 1;
}

int dual_iso_poll(void)
{
    pthread_mutex_lock(&state_mutex);
    int changed = apply_pending_locked();
    pthread_mutex_unlock(&state_mutex);
    return changed;
}

void dual_iso_state(int *mode, unsigned *gen)
{
    pthread_mutex_lock(&state_mutex);
    apply_pending_locked();
    if (mode) *mode = current_mode;
    if (gen) *gen = generation;
    pthread_mutex_unlock(&state_mutex);
}

int dual_iso_mode(void)
{
    int mode;
    dual_iso_state(&mode, NULL);
    return mode;
}

unsigned dual_iso_generation(void)
{
    unsigned gen;
    dual_iso_state(NULL, &gen);
    return gen;
}

static void *dual_iso_watcher(void *unused)
{
    (void)unused;
    for (;;)
    {
        usleep(100 * 1000);
        dual_iso_poll();
    }
    return NULL;
}

void dual_iso_start_watcher(void)
{
    static int started = 0;
    if (started) return;
    started = 1;
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attr, dual_iso_watcher, NULL) != 0)
    {
        fprintf(stderr, "dual iso: watcher thread not started (mode changes apply on the next frame)\n");
    }
    pthread_attr_destroy(&attr);
}
