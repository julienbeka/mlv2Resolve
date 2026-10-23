#!/usr/bin/env python3
"""Regression test: a clip cut off mid-frame (e.g. full card) must not crash MLVFS or serve garbage.

Usage: truncated_clip_test.py <clip.MLV> [--cut-frame N]
Copies the clip up to the middle of VIDF block N's payload (default 5) into a temp folder, mounts it
(--resolve-naming, no --bad-pix), then asserts:
  - frames before N read fine and pass the --expect-sane pixel check (frame 0),
  - reading frame N either fails with EIO or the frame is not listed (never uninitialised data),
  - mlvfs is still running afterwards and unmounts cleanly.
Python 3 stdlib only. Exit 0 = pass.
SPDX-License-Identifier: GPL-3.0-or-later
"""
import argparse, errno, os, shutil, struct, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mount_test import MLVFS, check_sane, unmount  # noqa: E402


def cut_offset(path, cut_frame):
    """Byte offset in the middle of the payload of the cut_frame-th VIDF block (0-based, file order)."""
    seen = 0
    with open(path, "rb") as f:
        pos = 0
        while True:
            f.seek(pos)
            hdr = f.read(32)
            if len(hdr) < 32:
                raise SystemExit("clip has fewer than %d VIDF blocks" % (cut_frame + 1))
            size = struct.unpack_from("<I", hdr, 4)[0]
            if hdr[:4] == b"VIDF":
                if seen == cut_frame:
                    space = struct.unpack_from("<I", hdr, 28)[0]
                    return pos + 32 + space + (size - 32 - space) // 2, struct.unpack_from("<I", hdr, 16)[0]
                seen += 1
            pos += size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clip")
    ap.add_argument("--cut-frame", type=int, default=5)
    a = ap.parse_args()

    clip = os.path.abspath(a.clip)
    name = os.path.splitext(os.path.basename(clip))[0]
    cut, frame_number = cut_offset(clip, a.cut_frame)
    work = tempfile.mkdtemp(prefix="mlvtrunc_")
    mnt = tempfile.mkdtemp(prefix="mlvmnt_")
    with open(clip, "rb") as src, open(os.path.join(work, name + ".MLV"), "wb") as dst:
        remaining = cut
        while remaining:
            buf = src.read(min(remaining, 1 << 24))
            dst.write(buf)
            remaining -= len(buf)
    print("truncated copy: %d bytes, cut inside VIDF frameNumber %d" % (cut, frame_number))

    log = open(os.path.join(work, "mlvfs.log"), "w")
    proc = subprocess.Popen([MLVFS, mnt, "--mlv-dir=" + work, "--resolve-naming", "-f"], stdout=log, stderr=subprocess.STDOUT)
    ok = False
    try:
        cdir = None
        t0 = time.time()
        while time.time() - t0 < 10 and cdir is None:
            if proc.poll() is not None:
                raise AssertionError("mlvfs exited early (rc=%s)" % proc.returncode)
            try:
                cands = [d for d in os.listdir(mnt) if d.startswith(name + "MLV")]
                if cands and os.listdir(os.path.join(mnt, cands[0])):
                    cdir = os.path.join(mnt, cands[0])
            except OSError:
                pass
            time.sleep(0.2)
        assert cdir, "clip folder did not appear within 10s"
        dngs = sorted(f for f in os.listdir(cdir) if f.lower().endswith(".dng"))
        print("dng count:", len(dngs))
        assert len(dngs) >= a.cut_frame, "expected at least %d frames" % a.cut_frame

        for d in dngs[:a.cut_frame]:
            with open(os.path.join(cdir, d), "rb") as f:
                f.read()
        check_sane(cdir, dngs)
        if len(dngs) > a.cut_frame:
            try:
                with open(os.path.join(cdir, dngs[a.cut_frame]), "rb") as f:
                    f.read()
            except OSError as e:
                assert e.errno == errno.EIO, "frame %d: expected EIO, got %s" % (a.cut_frame, e)
                print("frame %d (cut): read failed with EIO as expected" % a.cut_frame)
            else:
                raise AssertionError("frame %d (cut) was served without error" % a.cut_frame)
        else:
            print("frame %d (cut) not listed" % a.cut_frame)
        assert proc.poll() is None, "mlvfs died (rc=%s)" % proc.returncode
        ok = True
    except AssertionError as e:
        print("FAIL:", e)
    finally:
        unmount(mnt, proc)
        log.close()
        if proc.returncode not in (0, None):
            print("FAIL: mlvfs exit status %s" % proc.returncode)
            ok = False
        tail = [l for l in open(log.name, errors="replace").read().splitlines() if l.strip()][-5:]
        if tail:
            print("--- mlvfs log (tail) ---\n" + "\n".join(tail))
        shutil.rmtree(work, ignore_errors=True)
        try:
            os.rmdir(mnt)  # only succeeds if the mount point is empty (i.e. really unmounted)
        except OSError as e:
            print("FAIL: mount point not removable after umount:", e)
            ok = False
    print("PASS" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
