/*
 * Live dual ISO mode switching by signals (replaces the web GUI's set_value).
 *
 *   SIGUSR1 -> dual ISO mode 1 (--dual-iso-preview, fast)
 *   SIGUSR2 -> dual ISO mode 2 (--dual-iso, high quality)
 *
 * The signal handler only stores the requested mode into a lock-free
 * _Atomic int (relaxed store). Normal threads apply it (dual_iso_poll / dual_iso_mode /
 * dual_iso_generation): the mode changes, a generation counter is bumped and
 * "dual iso mode: N" is logged. The image buffer cache drops buffers whose
 * generation is not the current one, so frames decoded in the old mode are
 * never served after a switch.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 */

#ifndef mlvfs_dual_iso_switch_h
#define mlvfs_dual_iso_switch_h

/* Sets the initial mode (0, 1 or 2) and installs the SIGUSR1/SIGUSR2 handlers. */
void dual_iso_switch_init(int initial_mode);

/* Applies a pending signal request; returns 1 if the mode changed. */
int dual_iso_poll(void);

/* Current mode and generation, read together (pending request applied first). */
void dual_iso_state(int *mode, unsigned *generation);
int dual_iso_mode(void);
unsigned dual_iso_generation(void);

/* Starts a detached thread that polls every 100 ms so the change is logged promptly. */
void dual_iso_start_watcher(void);

#endif
