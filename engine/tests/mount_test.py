#!/usr/bin/env python3
"""Mount an MLV clip's folder via MLVFS/FUSE-T and assert on the virtual CinemaDNG sequence.

Usage: mount_test.py <clip.MLV> [--expect-frames N] [--min-fps F] [--backend nfs|smb]
Exit 0 = pass.
"""
import argparse, os, shutil, struct, subprocess, sys, tempfile, time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MLVFS = os.path.join(REPO, "build", "engine", "mlvfs")


def read_ifd0(path):
    with open(path, "rb") as f:
        head = f.read(8)
        if head[:4] != b"II*\x00":
            raise AssertionError("bad TIFF magic: %r" % head[:4])
        off = struct.unpack("<I", head[4:8])[0]
        f.seek(off)
        n = struct.unpack("<H", f.read(2))[0]
        tags = {}
        for _ in range(n):
            tag, typ, cnt, val = struct.unpack("<HHII", f.read(12))
            if typ == 3:
                val &= 0xFFFF
            tags[tag] = val
        return tags


def unmount(mnt, proc):
    r = subprocess.run(["umount", mnt], capture_output=True)
    if r.returncode != 0:
        subprocess.run(["diskutil", "unmount", "force", mnt], capture_output=True)
    if proc.poll() is None:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clip")
    ap.add_argument("--expect-frames", type=int)
    ap.add_argument("--min-fps", type=float, default=25.0)
    ap.add_argument("--backend", choices=["nfs", "smb"])
    ap.add_argument("--width", type=int, default=1600)
    ap.add_argument("--height", type=int, default=2040)
    a = ap.parse_args()

    clip = os.path.abspath(a.clip)
    folder, name = os.path.dirname(clip), os.path.splitext(os.path.basename(clip))[0]
    mnt = tempfile.mkdtemp(prefix="mlvmnt_")
    errlog = tempfile.NamedTemporaryFile(prefix="mlvfs_err_", delete=False)
    cmd = [MLVFS, mnt, "--mlv-dir=" + folder, "--resolve-naming", "--bad-pix", "-f"]
    if a.backend:
        cmd += ["-o", "backend=" + a.backend]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=errlog)
    ok = False
    try:
        cdir = os.path.join(mnt, name)  # resolved below (resolve-naming appends date/index suffix)
        t0 = time.time()
        while time.time() - t0 < 10:
            if proc.poll() is not None:
                raise AssertionError("mlvfs exited early (rc=%s)" % proc.returncode)
            try:
                cands = [d for d in os.listdir(mnt) if d == name or d.startswith(name + "MLV")]
                if cands:
                    cdir = os.path.join(mnt, cands[0])
                    if os.listdir(cdir):
                        break
            except OSError:
                pass
            time.sleep(0.2)
        else:
            raise AssertionError("clip folder %s did not appear within 10s" % cdir)
        print("mount ready in %.1fs (backend=%s)" % (time.time() - t0, a.backend or "default"))

        dngs = sorted(f for f in os.listdir(cdir) if f.lower().endswith(".dng"))
        print("dng count:", len(dngs), "first:", dngs[0], "last:", dngs[-1])
        if a.expect_frames is not None:
            assert len(dngs) == a.expect_frames, "expected %d frames, got %d" % (a.expect_frames, len(dngs))

        tags = read_ifd0(os.path.join(cdir, dngs[0]))
        print("IFD0 width=%s length=%s" % (tags.get(256), tags.get(257)))
        assert tags.get(256) == a.width and tags.get(257) == a.height, "bad dimensions %s x %s" % (tags.get(256), tags.get(257))

        total = 0
        t1 = time.time()
        for d in dngs:
            with open(os.path.join(cdir, d), "rb") as f:
                total += len(f.read())
        dt = time.time() - t1
        fps, mbs = len(dngs) / dt, total / dt / 1e6
        print("read %d frames, %.1f MB in %.2fs: %.1f fps, %.1f MB/s" % (len(dngs), total / 1e6, dt, fps, mbs))
        assert fps >= a.min_fps, "fps %.1f < min %.1f" % (fps, a.min_fps)
        ok = True
    except AssertionError as e:
        print("FAIL:", e)
    finally:
        unmount(mnt, proc)
        time.sleep(0.5)
        try:
            leftover = os.listdir(mnt)
        except OSError as e:
            leftover = ["<%s>" % e]
        if leftover:
            print("FAIL: mount point not empty after umount:", leftover[:5])
            ok = False
        else:
            shutil.rmtree(mnt, ignore_errors=True)
        errlog.close()
        err = open(errlog.name).read().strip()
        if err:
            print("--- mlvfs stderr (tail) ---\n" + "\n".join(err.splitlines()[-15:]))
        os.unlink(errlog.name)
    print("PASS" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
