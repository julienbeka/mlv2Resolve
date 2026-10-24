# Engine tests

`python3 engine/tests/mount_test.py <clip.MLV> [--expect-frames N] [--min-fps F] [--backend nfs|smb]`

Mounts the clip's parent folder with `build/engine/mlvfs ... --resolve-naming --bad-pix -f`, waits up to 10 s for
the clip folder, asserts DNG count, first-DNG TIFF header and size (1600x2040 by default, `--width/--height`),
sequential read fps (default >= 25), and clean unmount. Exit 0 = pass. Python 3 stdlib only.

Notes:
- With `--resolve-naming` the clip folder is named `<clip>MLV_1_<date>_0001_C0000`, not `<clip>`; the test matches on the `<clip>MLV` prefix.
- `--backend` passes `-o backend=smb|nfs` (FUSE-T default is NFS).
- Mount point is a temp dir; unmount uses `umount` then `diskutil unmount force`; mlvfs is killed if still alive.

Pixel checks:
- `--expect-sane` (stdlib only): on frame 0, asserts black < median < white and that the median absolute difference
  between same-colour horizontal neighbours is <= 1% of (white - black). Correct test clips give ~0.001; the old
  noisy LJ92 output gave ~1.3.
- `--expect-raw build/ref`: exact comparison of DNG frames 0 and 160 against references written by
  `make_reference.py <clip.MLV> build/ref 0 160` (dev-only, needs numpy + imagecodecs). Implies `--no-bad-pix` and
  `--no-focus-pixels`. `--no-bad-pix` alone mounts without `--bad-pix`.

Robustness (truncated / corrupt frames):
- `make -C engine -f Makefile.arm64 lj92-test && build/engine/lj92_truncation_test <clip.MLV> [build/ref/<clip>_0.u16]`:
  no FUSE; decodes frame 0's payload from a buffer ending at a PROT_NONE guard page (built with UBSan). Intact must
  decode (and match the reference); 98%, 50%, every cut in the first 2048 bytes and every 1/64 must return an error;
  corrupted DHT/SOF/SOS fields must not crash.
- `python3 engine/tests/truncated_clip_test.py <clip.MLV> [--cut-frame 5]`: mounts a copy cut mid-frame; earlier
  frames read and pass the sanity check, the cut frame returns EIO, mlvfs survives and unmounts.

Sidecars (`--expect-sidecars`): mounts an APFS clone (`cp -c`, in a temp dir) of the clip plus a second clone
`<clip>B.MLV`, a user file `lens.json` and a sub-folder `Audio/`, never the real folder. Through the mount it writes
`<clip>.gyroflow` (stored next to the MLV, listed in the clip folder only), overwrites/appends it, writes a non-prefix
name (`odd-name.txt`, remembered by `.mlv2dng-sidecars.json`, which is hidden and never served), `cp -p`s a file with
an extended attribute (AppleDouble `._x` stored next to it, moved/deleted with it), renames and deletes sidecars
(index removed when empty), and checks that the MLV (SHA-256), DNGs, clip folders, folders, `.DS_Store` and
MLV-family names refuse every change, that the other clip lists none of them, and that root writes land in the
source root. Implies a temporary `--index-dir` (as the app). `--expect-readonly` now runs only the protected-entry
part on the real folder.

Unit tests (no FUSE needed):
- `make -C engine -f Makefile.arm64 sidecar-test`: sidecar name rules (protected MLV family/.IDX/.MLD/index,
  hidden Finder metadata, virtual names, clip prefix rule) and the `.mlv2dng-sidecars.json` index (JSON round trip
  with awkward names, malformed input, removal deleting the empty index, nothing created just to remove).
- `make -C engine -f Makefile.arm64 resolve-name-test`: `--resolve-naming` folder name -> MLV base path matching
  (POSIX `<regex.h>`, replaces SLRE): canonical names, lowercase `mlv`/`c`, spaces and accents, non-matching names.
- `make -C engine -f Makefile.arm64 dual-iso-cache-test`: live dual ISO switching by signals (SIGUSR1 -> mode 1,
  SIGUSR2 -> mode 2, log line `dual iso mode: N`) and the image buffer cache generation: a frame decoded before a
  switch is decoded again in the new mode; a buffer still held across a switch is not freed.

Live switch on a mount: `kill -USR2 <mlvfs pid>` (high quality) / `kill -USR1 <pid>` (preview). The DNG
mtime/ctime shift by the switch generation (in microseconds) so the FUSE-T NFS client refetches frames it had
cached; it does so once its attribute cache expires (a few seconds).
