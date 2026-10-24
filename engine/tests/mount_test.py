#!/usr/bin/env python3
"""Mount an MLV clip's folder via MLVFS/FUSE-T and assert on the virtual CinemaDNG sequence.

Usage: mount_test.py <clip.MLV> [--expect-frames N] [--min-fps F] [--backend nfs|smb]
                     [--expect-scale H,V] [--expect-fpm] [--fpm-dir DIR] [--no-focus-pixels]
                     [--no-bad-pix] [--expect-raw REF_DIR] [--expect-sane]
                     [--expect-readonly] [--expect-sidecars] [--index-dir DIR]
--expect-scale 3,1  asserts the first DNG's DefaultScale (tag 50718) is 3/1, 1/1.
--expect-fpm        asserts the mlvfs log contains "focus pixels: N corrected" with N > 0.
--expect-raw DIR    asserts DNG frames 0 and 160 equal DIR/<clip>_<frame>.u16 (from make_reference.py) exactly;
                    implies --no-bad-pix and --no-focus-pixels so MLVFS outputs the decoded sensor values untouched.
--expect-readonly   asserts the engine itself refuses writes to protected entries (the harness never passes -o ro):
                    mkdir, mv/rmdir of the clip folder, rm/touch/truncate of a DNG, an in-place DNG write, Finder
                    metadata and mv of a real folder all fail, and nothing they targeted changed (the source folder
                    snapshot is checked as usual).
--expect-sidecars   mounts an APFS clone (cp -c) of the clip (plus a second clone <clip>B.MLV and a user file
                    lens.json, a sub-folder Audio/) instead of the clip's folder, then checks sidecar files: files written in the clip
                    folder land next to the MLV and are listed there (prefix rule or .mlv2dng-sidecars.json index),
                    overwrite/rename/delete work, protected entries (MLV, DNG, clip folder, index) refuse every
                    change, the other clip does not list them, root writes land in the source root, and the
                    MLV's SHA-256 is unchanged. The original folder must stay untouched.
--dual-iso-preview  pass --dual-iso-preview to mlvfs (forces the dual ISO code path, even on a normal clip).
--expect-sane       stdlib-only plausibility check on frame 0: black < median < white, and the median absolute
                    difference between same-colour horizontal neighbours is small relative to white - black.
mlvfs stdout and stderr both go to one log file (tail printed at the end).
Exit 0 = pass.
"""
import argparse, array, hashlib, os, re, shutil, struct, subprocess, sys, tempfile, time

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


def try_op(label, fn, failures, expect_ok=False):
    """Run fn(); record a failure if it succeeds while it should fail (or the reverse)."""
    try:
        fn()
        ok, msg = True, "ok"
    except OSError as e:
        ok, msg = False, "refused: %s" % (e.strerror or e)
    print("%s: %-44s %s" % ("write" if expect_ok else "protect", label, msg))
    if ok != expect_ok:
        failures.append(("refused: " if expect_ok else "accepted: ") + label)
    return ok


def write_file(path, data, mode="wb"):
    with open(path, mode) as f:
        f.write(data)


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def check_protected(mnt, cdir, dngs, failures):
    """Mutations of protected entries (virtual files, clip folder, directories, Finder metadata) all fail."""
    dng = os.path.join(cdir, dngs[0])
    size_before = os.path.getsize(dng)
    probes = [os.path.join(mnt, "mlvswitch_ro_dir"), os.path.join(cdir, "mlvswitch_ro_dir"),
              os.path.join(mnt, "mlvswitch_ro_renamed"), os.path.join(cdir, "renamed.dng"),
              os.path.join(cdir, "new_probe.dng"), os.path.join(cdir, ".DS_Store"), os.path.join(mnt, ".DS_Store"),
              os.path.join(cdir, "._probe")]
    try_op("mkdir at root", lambda: os.mkdir(probes[0]), failures)
    try_op("mkdir in clip folder", lambda: os.mkdir(probes[1]), failures)
    try_op("mv clip folder", lambda: os.rename(cdir, probes[2]), failures)
    try_op("rmdir clip folder", lambda: os.rmdir(cdir), failures)
    try_op("rm DNG", lambda: os.unlink(dng), failures)
    try_op("mv DNG", lambda: os.rename(dng, probes[3]), failures)
    try_op("open DNG r+b and write", lambda: write_file(dng, b"\0", "r+b"), failures)
    try_op("truncate DNG", lambda: os.truncate(dng, 0), failures)
    try_op("touch (utimes) DNG", lambda: os.utime(dng, (0, 0)), failures)
    try_op("create new .dng in clip folder", lambda: write_file(probes[4], b"x"), failures)
    try_op("create .DS_Store in clip folder", lambda: write_file(probes[5], b"x"), failures)
    try_op("create .DS_Store at root", lambda: write_file(probes[6], b"x"), failures)
    try_op("create ._ AppleDouble in clip folder", lambda: write_file(probes[7], b"x"), failures)
    for p in probes:
        # any *.dng name in a clip folder resolves to a virtual frame, so check those by listing
        if (os.path.basename(p) in os.listdir(os.path.dirname(p)) if p.endswith(".dng") else os.path.lexists(p)):
            failures.append("exists after refusal: " + p)
    if not os.path.exists(dng) or os.path.getsize(dng) != size_before:
        failures.append("DNG missing or resized")


def check_readonly(mnt, cdir, dngs, src_folder):
    """Protected entries refuse every mutation (on the real source folder: only refused operations are tried)."""
    failures = []
    check_protected(mnt, cdir, dngs, failures)
    # a real (non-virtual) sub-folder of the rushes folder, passed through by MLVFS: directories stay read-only
    real_dir = next((d for d in sorted(os.listdir(mnt)) if not d.startswith(".") and d != os.path.basename(cdir)
                     and os.path.isdir(os.path.join(mnt, d)) and "MLV_" not in d), None)
    print("mount root:", sorted(os.listdir(mnt))[:8], "real folder probe:", real_dir)
    if real_dir:
        rd = os.path.join(mnt, real_dir)
        try_op("mkdir in real folder " + real_dir, lambda: os.mkdir(os.path.join(rd, "mlvswitch_ro_dir")), failures)
        try_op("mv real folder " + real_dir, lambda: os.rename(rd, rd + ".mlvswitch_ro"), failures)
        for p in (os.path.join(rd, "mlvswitch_ro_dir"), rd + ".mlvswitch_ro"):
            if os.path.lexists(p):
                failures.append("exists after refusal: " + p)
        src_real_dir = os.path.join(src_folder, real_dir)
        if not os.path.isdir(src_real_dir):
            failures.append("real folder gone from source: " + src_real_dir)
            if os.path.isdir(src_real_dir + ".mlvswitch_ro"):
                os.rename(src_real_dir + ".mlvswitch_ro", src_real_dir)  # undo
    return failures


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 22), b""):
            h.update(block)
    return h.hexdigest()


INDEX_NAME = ".mlv2dng-sidecars.json"


def check_sidecars(mnt, cdir, dngs, src, name, mlv_sha):
    """Sidecar files on a mounted clone `src` (see --expect-sidecars). Returns the list of failures."""
    failures = []

    def expect(cond, what):
        print("sidecar: %-60s %s" % (what, "ok" if cond else "FAILED"))
        if not cond:
            failures.append(what)

    other = next((d for d in os.listdir(mnt) if d.startswith(name + "BMLV")), None)
    expect(other is not None, "second clip folder %sBMLV_* listed" % name)
    odir = os.path.join(mnt, other) if other else None
    listing = lambda d: set(os.listdir(d))
    expect("lens.json" in listing(mnt) and "lens.json" not in listing(cdir), "user lens.json at root, not in clip")
    expect(INDEX_NAME not in listing(mnt), "no index listed at root initially")

    # 1. prefix-named sidecar written in the clip folder -> next to the MLV, listed in this clip only
    gyro = name + ".gyroflow"
    try_op("create " + gyro + " in clip folder", lambda: write_file(os.path.join(cdir, gyro), b"version X"),
           failures, expect_ok=True)
    expect(os.path.isfile(os.path.join(src, gyro)) and read_file(os.path.join(src, gyro)) == b"version X",
           "%s stored in source folder with content X" % gyro)
    expect(gyro in listing(cdir), gyro + " listed in clip folder")
    expect(read_file(os.path.join(cdir, gyro)) == b"version X", gyro + " reads back through the mount")
    expect(not os.path.exists(os.path.join(src, INDEX_NAME)), "prefix-named sidecar needs no index")
    # 2. overwrite (as a re-export does): shorter content, so truncation must happen
    try_op("overwrite " + gyro, lambda: write_file(os.path.join(cdir, gyro), b"Y"), failures, expect_ok=True)
    expect(read_file(os.path.join(src, gyro)) == b"Y", "overwrite truncated and rewrote the source file")
    try_op("append to " + gyro, lambda: write_file(os.path.join(cdir, gyro), b"Z", "ab"), failures, expect_ok=True)
    expect(read_file(os.path.join(src, gyro)) == b"YZ", "append landed in the source file")
    # Resolve-style long name also counts as this clip's sidecar
    long_name = os.path.basename(cdir) + ".gcsv"
    try_op("create " + long_name, lambda: write_file(os.path.join(cdir, long_name), b"t,x\n"), failures, expect_ok=True)
    expect(os.path.isfile(os.path.join(src, long_name)) and long_name in listing(cdir), long_name + " stored + listed")

    # 3. a name that does not start with the clip name -> stored in source, remembered by the index
    odd = "odd-name.txt"
    try_op("create " + odd + " in clip folder", lambda: write_file(os.path.join(cdir, odd), b"odd"), failures,
           expect_ok=True)
    expect(read_file(os.path.join(src, odd)) == b"odd", odd + " stored in source folder")
    expect(odd in listing(cdir), odd + " listed in clip folder (index)")
    expect(os.path.isfile(os.path.join(src, INDEX_NAME)), "index file written in source folder")
    expect(odd in read_file(os.path.join(src, INDEX_NAME)).decode(), "index names " + odd)
    expect(INDEX_NAME not in listing(cdir) and INDEX_NAME not in listing(mnt), "index hidden from listings")
    for where in (mnt, cdir):
        try_op("read index through " + ("root" if where == mnt else "clip folder"),
               lambda: read_file(os.path.join(where, INDEX_NAME)), failures)
        try_op("write index through " + ("root" if where == mnt else "clip folder"),
               lambda: write_file(os.path.join(where, INDEX_NAME), b"{}"), failures)
    expect(odd in read_file(os.path.join(src, INDEX_NAME)).decode(), "index intact after refused writes")

    # 3b. cp -p of a file carrying an extended attribute: the macOS NFS client stores it as an AppleDouble
    # "._<name>" next to the sidecar; that companion is accepted, hidden, and removed with the file
    xsrc = os.path.join(os.path.dirname(src), os.path.basename(src) + "_xattr_src.json")
    write_file(xsrc, b'{"x": 1}')
    subprocess.run(["xattr", "-w", "com.mlv2dng.test", "1", xsrc], check=True)
    copied = name + "_copied.json"
    r = subprocess.run(["cp", "-p", xsrc, os.path.join(cdir, copied)], capture_output=True, text=True)
    os.unlink(xsrc)
    expect(r.returncode == 0, "cp -p with an xattr into the clip folder (%s)" % (r.stderr.strip() or "rc 0"))
    expect(read_file(os.path.join(src, copied)) == b'{"x": 1}' and copied in listing(cdir), copied + " stored + listed")
    # best effort only: the FUSE-T NFS client caches attributes, so a read-back is informative, not asserted
    xr = subprocess.run(["xattr", "-p", "com.mlv2dng.test", os.path.join(cdir, copied)], capture_output=True, text=True)
    print("sidecar: xattr read back through the mount (info): %s" % (xr.stdout.strip() or xr.stderr.strip()))
    expect(not any(n.startswith("._") for n in listing(cdir) | listing(mnt)), "AppleDouble files hidden")
    try_op("create ._ for a DNG", lambda: write_file(os.path.join(cdir, "._" + dngs[0]), b"x"), failures)

    # 4. the other clip does not list the first clip's sidecars, and vice versa (prefix M29-0615 vs M29-0615B)
    if odir:
        ol = listing(odir)
        expect(not ({gyro, odd, long_name} & ol), "other clip folder does not list them")
        gyro_b = name + "B.gyroflow"
        try_op("create " + gyro_b + " in other clip", lambda: write_file(os.path.join(odir, gyro_b), b"B"),
               failures, expect_ok=True)
        expect(gyro_b in listing(odir) and gyro_b not in listing(cdir), gyro_b + " listed only in its clip")
        expect(gyro not in listing(odir), gyro + " still not in other clip")
    # sidecars show at the mount root too (mirror of the source folder), except names in the Resolve clip
    # folder format, which would collide with the clip folder itself
    expect({gyro, odd} <= listing(mnt) and long_name not in listing(mnt), "sidecars mirrored at the mount root")

    # 5. rename and delete sidecars
    renamed = "odd-renamed.txt"
    try_op("rename %s -> %s" % (odd, renamed), lambda: os.rename(os.path.join(cdir, odd), os.path.join(cdir, renamed)),
           failures, expect_ok=True)
    expect(not os.path.exists(os.path.join(src, odd)) and read_file(os.path.join(src, renamed)) == b"odd",
           "rename applied in source folder")
    expect(renamed in listing(cdir) and odd not in listing(cdir), "renamed sidecar listed under its new name")
    gyro2 = name + "_v2.gyroflow"
    try_op("rename %s -> %s" % (gyro, gyro2), lambda: os.rename(os.path.join(cdir, gyro), os.path.join(cdir, gyro2)),
           failures, expect_ok=True)
    expect(read_file(os.path.join(src, gyro2)) == b"YZ" and gyro2 in listing(cdir), gyro2 + " renamed + listed")
    # renames onto protected names or into the virtual namespace are refused
    try_op("rename sidecar onto <clip>.MLV", lambda: os.rename(os.path.join(cdir, gyro2), os.path.join(cdir, name + ".MLV")),
           failures)
    try_op("rename sidecar onto root <clip>.MLV", lambda: os.rename(os.path.join(cdir, gyro2), os.path.join(mnt, name + ".MLV")),
           failures)
    try_op("rename sidecar onto <clip>.M00", lambda: os.rename(os.path.join(cdir, gyro2), os.path.join(mnt, name + ".M00")),
           failures)
    try_op("rename sidecar onto a DNG", lambda: os.rename(os.path.join(cdir, gyro2), os.path.join(cdir, dngs[0])),
           failures)
    try_op("rename sidecar onto the index", lambda: os.rename(os.path.join(cdir, gyro2), os.path.join(mnt, INDEX_NAME)),
           failures)
    try_op("rename sidecar into a new folder", lambda: os.rename(os.path.join(cdir, gyro2), os.path.join(cdir, "sub", "x")),
           failures)
    expect(read_file(os.path.join(src, gyro2)) == b"YZ", "sidecar intact after refused renames")
    for n in (renamed, gyro2, long_name, copied):
        try_op("delete " + n, lambda: os.unlink(os.path.join(cdir, n)), failures, expect_ok=True)
        expect(not os.path.exists(os.path.join(src, n)) and n not in listing(cdir), n + " gone from source + clip")
    expect(not os.path.exists(os.path.join(src, INDEX_NAME)), "index removed once it is empty")

    # 6. protected entries: MLV (through the root), virtual DNG, clip folder, new MLV-family names
    mlv_at_root = os.path.join(mnt, name + ".MLV")
    try_op("truncate <clip>.MLV via root", lambda: os.truncate(mlv_at_root, 0), failures)
    try_op("open <clip>.MLV for writing", lambda: write_file(mlv_at_root, b"x", "r+b"), failures)
    try_op("rm <clip>.MLV via root", lambda: os.unlink(mlv_at_root), failures)
    try_op("rename <clip>.MLV via root", lambda: os.rename(mlv_at_root, os.path.join(mnt, "x.MLV")), failures)
    try_op("create new.MLV at root", lambda: write_file(os.path.join(mnt, "new.MLV"), b"x"), failures)
    try_op("create %s.M00 in clip folder" % name, lambda: write_file(os.path.join(cdir, name + ".M00"), b"x"), failures)
    try_op("create x.IDX at root", lambda: write_file(os.path.join(mnt, "x.IDX"), b"x"), failures)
    failures += check_readonly(mnt, cdir, dngs, src)  # protected entries + the real sub-folder "Audio"
    for n in ("new.MLV", "x.MLV", name + ".M00", "x.IDX"):
        if os.path.lexists(os.path.join(src, n)):
            failures.append("protected name created in source: " + n)

    # 7. the mount root mirrors the source root: new files, and existing user files may be overwritten
    note = "root-note.txt"
    try_op("create " + note + " at root", lambda: write_file(os.path.join(mnt, note), b"root"), failures, expect_ok=True)
    expect(read_file(os.path.join(src, note)) == b"root" and note in listing(mnt), note + " stored in source root + listed")
    expect(note not in listing(cdir), note + " not listed in the clip folder")
    try_op("overwrite lens.json at root", lambda: write_file(os.path.join(mnt, "lens.json"), b"{\"new\": 1}"),
           failures, expect_ok=True)
    expect(read_file(os.path.join(src, "lens.json")) == b'{"new": 1}', "lens.json overwritten in source")
    try_op("delete " + note, lambda: os.unlink(os.path.join(mnt, note)), failures, expect_ok=True)
    expect(not os.path.exists(os.path.join(src, note)), note + " deleted from source")

    expect(sha256(os.path.join(src, name + ".MLV")) == mlv_sha, "MLV SHA-256 unchanged")
    expect(read_file(os.path.join(mnt, "Audio", "take1.txt")) == b"take", "file in a real sub-folder readable")
    try_op("write a file in real sub-folder", lambda: write_file(os.path.join(mnt, "Audio", "take2.txt"), b"t2"),
           failures, expect_ok=True)
    expect(read_file(os.path.join(src, "Audio", "take2.txt")) == b"t2", "sub-folder file stored in source sub-folder")
    kept = {name + ".MLV", name + "B.MLV", "lens.json", name + "B.gyroflow", "Audio"}
    # "._x" attribute files may remain only for files that remain (renames and deletes carry them)
    left = sorted(n for n in os.listdir(src) if n not in kept and not (n.startswith("._") and n[2:] in kept))
    expect(not left, "source folder holds nothing else (extra: %s)" % left)
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
    ap.add_argument("--expect-sidecars", action="store_true")
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
    mount_folder, clone_dir, mlv_sha = folder, None, None
    if a.expect_sidecars:
        # never write to the real rushes: mount an APFS clone of the clip (+ a second clip and a user file)
        clone_dir = tempfile.mkdtemp(prefix="mlvsrc_")
        for n in sorted(os.listdir(folder)):
            stem, ext = os.path.splitext(n)
            if stem == name and re.fullmatch(r"\.(MLV|M\d\d)", ext, re.I):
                subprocess.run(["cp", "-c", os.path.join(folder, n), os.path.join(clone_dir, n)], check=True)
        subprocess.run(["cp", "-c", clip, os.path.join(clone_dir, name + "B.MLV")], check=True)
        write_file(os.path.join(clone_dir, "lens.json"), b'{"lens": "user file"}')
        os.mkdir(os.path.join(clone_dir, "Audio"))
        write_file(os.path.join(clone_dir, "Audio", "take1.txt"), b"take")
        mount_folder = clone_dir
        if not a.index_dir:  # as the app does: .IDX files go to an index dir, never into the source folder
            a.index_dir = tempfile.mkdtemp(prefix="mlvidx_")
        mlv_sha = sha256(os.path.join(clone_dir, name + ".MLV"))
        print("sidecar source clone:", clone_dir, "MLV sha256", mlv_sha[:16])
    mnt = tempfile.mkdtemp(prefix="mlvmnt_")
    log = tempfile.NamedTemporaryFile(prefix="mlvfs_log_", delete=False)
    cmd = [MLVFS, mnt, "--mlv-dir=" + mount_folder, "--resolve-naming", "-f"]
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
            print("readonly: all mutating operations on protected entries refused")
        if a.expect_sidecars:
            try:
                failures = check_sidecars(mnt, cdir, dngs, mount_folder, name, mlv_sha)
            except OSError as e:
                failures = ["unexpected OSError: %s" % e]
            assert not failures, "sidecar checks failed: %s" % failures
            print("sidecars: all checks passed")
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
        if clone_dir:
            shutil.rmtree(clone_dir, ignore_errors=True)
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
