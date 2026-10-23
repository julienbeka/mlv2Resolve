#!/usr/bin/env python3
"""Mount an MLV clip's folder via MLVFS/FUSE-T and assert on the virtual CinemaDNG sequence.

Usage: mount_test.py <clip.MLV> [--expect-frames N] [--min-fps F] [--backend nfs|smb]
                     [--expect-scale H,V] [--expect-fpm] [--fpm-dir DIR] [--no-focus-pixels]
                     [--no-bad-pix] [--expect-raw REF_DIR] [--expect-sane]
--expect-scale 3,1  asserts the first DNG's DefaultScale (tag 50718) is 3/1, 1/1.
--expect-fpm        asserts the mlvfs log contains "focus pixels: N corrected" with N > 0.
--expect-raw DIR    asserts DNG frames 0 and 160 equal DIR/<clip>_<frame>.u16 (from make_reference.py) exactly;
                    implies --no-bad-pix and --no-focus-pixels so MLVFS outputs the decoded sensor values untouched.
--expect-readonly   asserts the engine itself refuses writes (the harness never passes -o ro): touch, mkdir, mv of
                    the clip folder, rm of a DNG, rm of a real (non-virtual) file and an in-place DNG write all fail,
                    and nothing they targeted changed (the source folder snapshot is checked as usual).
--dual-iso-preview  pass --dual-iso-preview to mlvfs (forces the dual ISO code path, even on a normal clip).
--expect-sane       stdlib-only plausibility check on frame 0: black < median < white, and the median absolute
                    difference between same-colour horizontal neighbours is small relative to white - black.
mlvfs stdout and stderr both go to one log file (tail printed at the end).
Exit 0 = pass.
"""
import argparse, array, os, re, shutil, struct, subprocess, sys, tempfile, time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MLVFS = os.path.join(REPO, "build", "engine", "mlvfs")
FPM_DIR = os.path.join(REPO, "engine", "mlvfs", "fpm")
FPM_RE = re.compile(r"focus pixels: (\d+) corrected")


TYPE_FMT = {1: ("B", 1), 2: ("c", 1), 3: ("H", 2), 4: ("I", 4), 5: ("II", 8),
            7: ("B", 1), 8: ("h", 2), 9: ("i", 4), 10: ("ii", 8)}


def read_ifd0(path):
    """Return {tag: [decoded values]} for IFD0. Values larger than 4 bytes are read from their offset;
    RATIONAL/SRATIONAL entries decode to (num, den) tuples."""
    with open(path, "rb") as f:
        data = f.read(65536)
    if data[:4] != b"II*\x00":
        raise AssertionError("bad TIFF magic: %r" % data[:4])
    off = struct.unpack_from("<I", data, 4)[0]
    n = struct.unpack_from("<H", data, off)[0]
    tags = {}
    for k in range(n):
        tag, typ, cnt, raw = struct.unpack_from("<HHI4s", data, off + 2 + 12 * k)
        if typ not in TYPE_FMT:
            tags[tag] = [raw]
            continue
        fmt, size = TYPE_FMT[typ]
        total = size * cnt
        if total <= 4:
            buf = raw[:total]
        else:
            voff = struct.unpack("<I", raw)[0]
            buf = data[voff:voff + total]
            if len(buf) < total:
                raise AssertionError("tag %d value at %d beyond first 64 KiB" % (tag, voff))
        if typ == 2:
            tags[tag] = [buf.rstrip(b"\x00").decode("latin-1")]
        elif typ in (5, 10):
            vals = struct.unpack("<" + fmt[0] * (2 * cnt), buf)
            tags[tag] = [(vals[2 * i], vals[2 * i + 1]) for i in range(cnt)]
        else:
            tags[tag] = list(struct.unpack("<" + fmt * cnt, buf))
    return tags


def read_raw(path):
    """Return (tags, pixels as array('H'), width, height) for an uncompressed single-strip DNG."""
    tags = read_ifd0(path)
    width, height = tags[256][0], tags[257][0]
    bps, comp = tags[258][0], tags.get(259, [1])[0]
    assert comp == 1, "DNG Compression=%s, expected 1 (uncompressed)" % comp
    assert bps == 16, "BitsPerSample=%s; only 16-bit little-endian strips are supported" % bps
    offsets, counts = tags[273], tags[279]
    pix = array.array("H")
    with open(path, "rb") as f:
        for off, cnt in zip(offsets, counts):
            f.seek(off)
            pix.frombytes(f.read(cnt))
    if sys.byteorder != "little":
        pix.byteswap()
    assert len(pix) == width * height, "strip holds %d samples, expected %d" % (len(pix), width * height)
    return tags, pix, width, height


def check_raw(cdir, dngs, ref_dir, name, frames=(0, 160)):
    for n in frames:
        ref_path = os.path.join(ref_dir, "%s_%d.u16" % (name, n))
        ref = array.array("H")
        with open(ref_path, "rb") as f:
            ref.frombytes(f.read())
        if sys.byteorder != "little":
            ref.byteswap()
        _, pix, w, h = read_raw(os.path.join(cdir, dngs[n]))
        assert len(ref) == len(pix), "frame %d: ref has %d samples, DNG %d" % (n, len(ref), len(pix))
        if pix != ref:
            bad = [i for i in range(len(pix)) if pix[i] != ref[i]]
            i = bad[0]
            raise AssertionError("frame %d: %d of %d pixels differ; first at x=%d y=%d: dng=%d ref=%d" % (
                n, len(bad), len(pix), i % w, i // w, pix[i], ref[i]))
        print("raw frame %d (%s): exact match with %s (%dx%d)" % (n, dngs[n], os.path.basename(ref_path), w, h))


def sanity_numbers(pix, w, h, black, white):
    """Return (median, neighbour MAD / (white - black)) over every 4th row."""
    vals, diffs = [], []
    for y in range(0, h, 4):
        row = pix[y * w:(y + 1) * w]
        vals.extend(row)
        diffs.extend(abs(row[x] - row[x + 2]) for x in range(w - 2))
    vals.sort()
    diffs.sort()
    return vals[len(vals) // 2], diffs[len(diffs) // 2] / float(white - black)


SANE_MAX_REL_MAD = 0.01


def check_sane(cdir, dngs):
    tags, pix, w, h = read_raw(os.path.join(cdir, dngs[0]))
    black, white = tags[50714][0], tags[50717][0]
    med, rel = sanity_numbers(pix, w, h, black, white)
    print("sanity frame 0: black=%d white=%d median=%d neighbour_mad/range=%.5f (max %.3f)" % (
        black, white, med, rel, SANE_MAX_REL_MAD))
    assert black < med < white, "median %d not between black %d and white %d" % (med, black, white)
    assert rel <= SANE_MAX_REL_MAD, "same-colour neighbour MAD %.5f of range > %.3f (noise?)" % (rel, SANE_MAX_REL_MAD)


def check_readonly(mnt, cdir, dngs, src_folder):
    """Every mutating operation through the mount must fail; return the list of failures."""
    # a real (non-virtual) sub-folder of the rushes folder, passed through by MLVFS, with a real file in it
    real_dir = next((d for d in sorted(os.listdir(mnt)) if not d.startswith(".") and d not in (os.path.basename(cdir),)
                     and os.path.isdir(os.path.join(mnt, d)) and "MLV_" not in d), None)
    real = []
    if real_dir:
        real = sorted(f for f in os.listdir(os.path.join(mnt, real_dir))
                      if not f.startswith(".") and os.path.isfile(os.path.join(mnt, real_dir, f)))[:1]
    print("mount root:", sorted(os.listdir(mnt))[:8], "real probe:", real_dir, real)
    dng = os.path.join(cdir, dngs[0])
    size_before = os.path.getsize(dng)
    attempts = [
        ("touch new file at root", ["touch", os.path.join(mnt, "mlvswitch_ro_probe.txt")]),
        ("touch new file in clip folder", ["touch", os.path.join(cdir, "mlvswitch_ro_probe.txt")]),
        ("mkdir at root", ["mkdir", os.path.join(mnt, "mlvswitch_ro_dir")]),
        ("mkdir in clip folder", ["mkdir", os.path.join(cdir, "mlvswitch_ro_dir")]),
        ("mv clip folder", ["mv", cdir, os.path.join(mnt, "mlvswitch_ro_renamed")]),
        ("rm DNG", ["rm", "-f", dng]),
    ]
    probes = [os.path.join(mnt, "mlvswitch_ro_probe.txt"), os.path.join(cdir, "mlvswitch_ro_probe.txt"),
              os.path.join(mnt, "mlvswitch_ro_dir"), os.path.join(cdir, "mlvswitch_ro_dir"),
              os.path.join(mnt, "mlvswitch_ro_renamed")]
    if real_dir:
        rd = os.path.join(mnt, real_dir)
        attempts.append(("touch in real folder " + real_dir, ["touch", os.path.join(rd, "mlvswitch_ro_probe.txt")]))
        attempts.append(("mkdir in real folder " + real_dir, ["mkdir", os.path.join(rd, "mlvswitch_ro_dir")]))
        attempts.append(("mv real folder " + real_dir, ["mv", rd, rd + ".mlvswitch_ro"]))
        probes += [os.path.join(rd, "mlvswitch_ro_probe.txt"), os.path.join(rd, "mlvswitch_ro_dir"), rd + ".mlvswitch_ro"]
    if real:
        # reversible (rename within the same folder) rather than rm, so a broken engine cannot destroy a real file
        rf = os.path.join(mnt, real_dir, real[0])
        attempts.append(("mv real file " + real[0], ["mv", rf, rf + ".mlvswitch_ro"]))
        probes.append(rf + ".mlvswitch_ro")
    failures = []
    src_real_dir = os.path.join(src_folder, real_dir) if real_dir else None
    for label, cmd in attempts:
        r = subprocess.run(cmd, capture_output=True, text=True)
        err = (r.stderr.strip().splitlines() or [""])[-1]
        print("readonly: %-34s rc=%d %s" % (label, r.returncode, err))
        if r.returncode == 0:
            failures.append(label)
    try:
        with open(dng, "r+b") as f:
            f.write(b"\0")
        failures.append("open DNG for writing")
        print("readonly: open DNG r+b                  SUCCEEDED")
    except OSError as e:
        print("readonly: open DNG r+b                  refused: %s" % e.strerror)
    for p in probes:
        if os.path.exists(p):
            failures.append("exists after refusal: " + p)
    if not os.path.exists(dng) or os.path.getsize(dng) != size_before:
        failures.append("DNG missing or resized")
    if src_real_dir and not os.path.isdir(src_real_dir):
        failures.append("real folder gone from source: " + src_real_dir)
        if os.path.isdir(src_real_dir + ".mlvswitch_ro"):
            os.rename(src_real_dir + ".mlvswitch_ro", src_real_dir)  # undo
    if real and not os.path.exists(os.path.join(mnt, real_dir, real[0])):
        failures.append("real file gone: " + real[0])
    return failures


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


def snapshot(folder):
    snap = {}
    for n in sorted(os.listdir(folder)):
        st = os.lstat(os.path.join(folder, n))
        snap[n] = (st.st_size, st.st_mtime_ns)
    return snap


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clip")
    ap.add_argument("--expect-frames", type=int)
    ap.add_argument("--min-fps", type=float, default=25.0)
    ap.add_argument("--backend", choices=["nfs", "smb"])
    ap.add_argument("--width", type=int, default=1600)
    ap.add_argument("--height", type=int, default=2040)
    ap.add_argument("--expect-scale", help="H,V expected DefaultScale, e.g. 3,1")
    ap.add_argument("--expect-fpm", action="store_true")
    ap.add_argument("--fpm-dir", default=FPM_DIR)
    ap.add_argument("--no-focus-pixels", action="store_true")
    ap.add_argument("--no-bad-pix", action="store_true", help="mount without --bad-pix")
    ap.add_argument("--expect-raw", metavar="REF_DIR")
    ap.add_argument("--expect-sane", action="store_true")
    ap.add_argument("--expect-readonly", action="store_true")
    ap.add_argument("--dual-iso-preview", action="store_true")
    ap.add_argument("--index-dir", help="pass --index-dir to mlvfs; asserts .IDX files land there")
    ap.add_argument("--assert-source-untouched", action=argparse.BooleanOptionalAction, default=True,
                    help="assert the source folder is identical (names, sizes, mtimes) after unmount")
    a = ap.parse_args()
    if a.expect_raw:
        if a.expect_fpm:
            ap.error("--expect-raw disables focus pixel correction; run --expect-fpm separately")
        a.no_bad_pix = a.no_focus_pixels = True

    clip = os.path.abspath(a.clip)
    folder, name = os.path.dirname(clip), os.path.splitext(os.path.basename(clip))[0]
    before = snapshot(folder)
    mnt = tempfile.mkdtemp(prefix="mlvmnt_")
    log = tempfile.NamedTemporaryFile(prefix="mlvfs_log_", delete=False)
    cmd = [MLVFS, mnt, "--mlv-dir=" + folder, "--resolve-naming", "-f"]
    if not a.no_bad_pix:
        cmd += ["--bad-pix"]
    if a.fpm_dir:
        cmd += ["--fpm-dir=" + a.fpm_dir]
    if a.no_focus_pixels:
        cmd += ["--no-focus-pixels"]
    if a.index_dir:
        cmd += ["--index-dir=" + a.index_dir]
    if a.dual_iso_preview:
        cmd += ["--dual-iso-preview"]
    if a.backend:
        cmd += ["-o", "backend=" + a.backend]
    proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
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
        width, height = tags.get(256, [None])[0], tags.get(257, [None])[0]
        scale = tags.get(50718)
        print("IFD0 width=%s length=%s DefaultScale=%s" % (width, height, scale))
        assert width == a.width and height == a.height, "bad dimensions %s x %s" % (width, height)
        if a.expect_scale:
            h, v = (int(x) for x in a.expect_scale.split(","))
            got = [num / den if den else None for num, den in (scale or [])]
            assert got == [h, v], "DefaultScale expected %s/1, %s/1, got %s" % (h, v, scale)

        total = 0
        t1 = time.time()
        for d in dngs:
            with open(os.path.join(cdir, d), "rb") as f:
                total += len(f.read())
        dt = time.time() - t1
        fps, mbs = len(dngs) / dt, total / dt / 1e6
        print("read %d frames, %.1f MB in %.2fs: %.1f fps, %.1f MB/s" % (len(dngs), total / 1e6, dt, fps, mbs))
        assert fps >= a.min_fps, "fps %.1f < min %.1f" % (fps, a.min_fps)
        if a.expect_fpm:
            log.flush()
            hits = FPM_RE.findall(open(log.name, errors="replace").read())
            print("focus pixel log lines:", len(hits), "N =", hits[:3])
            assert hits, "no 'focus pixels: N corrected' line in mlvfs log"
            assert all(int(n) > 0 for n in hits), "focus pixel count not > 0: %s" % hits
        if a.expect_sane:
            check_sane(cdir, dngs)
        if a.expect_raw:
            check_raw(cdir, dngs, os.path.abspath(a.expect_raw), name)
        if a.expect_readonly:
            failures = check_readonly(mnt, cdir, dngs, folder)
            assert not failures, "mount accepted mutating operations: %s" % failures
            print("readonly: all mutating operations refused")
        ok = True
    except AssertionError as e:
        print("FAIL:", e)
    finally:
        unmount(mnt, proc)
        time.sleep(0.5)
        if a.assert_source_untouched:
            after = snapshot(folder)
            if after != before:
                changed = sorted(n for n in set(before) | set(after) if before.get(n) != after.get(n))
                print("FAIL: source folder modified:", changed)
                ok = False
            else:
                print("source folder untouched")
        if a.index_dir:
            idx = [f for f in os.listdir(a.index_dir) if f.endswith(".IDX")] if os.path.isdir(a.index_dir) else []
            print("index dir .IDX files:", idx)
            if not idx:
                print("FAIL: no .IDX file in", a.index_dir)
                ok = False
        try:
            leftover = os.listdir(mnt)
        except OSError as e:
            leftover = ["<%s>" % e]
        if leftover:
            print("FAIL: mount point not empty after umount:", leftover[:5])
            ok = False
        else:
            shutil.rmtree(mnt, ignore_errors=True)
        log.close()
        # skip the bare "x y" coordinate lines MLVFS prints for detected bad pixels
        lines = [l for l in open(log.name, errors="replace").read().splitlines()
                 if l.strip() and not re.fullmatch(r"\s*\d+\s+\d+\s*", l)]
        if lines:
            print("--- mlvfs log (tail, bad-pixel coordinate lines omitted) ---\n" + "\n".join(lines[-15:]))
        os.unlink(log.name)
    print("PASS" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
