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
