# Engine tests

`python3 engine/tests/mount_test.py <clip.MLV> [--expect-frames N] [--min-fps F] [--backend nfs|smb]`

Mounts the clip's parent folder with `build/engine/mlvfs ... --resolve-naming --bad-pix -f`, waits up to 10 s for
the clip folder, asserts DNG count, first-DNG TIFF header and size (1600x2040 by default, `--width/--height`),
sequential read fps (default >= 25), and clean unmount. Exit 0 = pass. Python 3 stdlib only.

Notes:
- With `--resolve-naming` the clip folder is named `<clip>MLV_1_<date>_0001_C0000`, not `<clip>`; the test matches on the `<clip>MLV` prefix.
- `--backend` passes `-o backend=smb|nfs` (FUSE-T default is NFS).
- Mount point is a temp dir; unmount uses `umount` then `diskutil unmount force`; mlvfs is killed if still alive.
