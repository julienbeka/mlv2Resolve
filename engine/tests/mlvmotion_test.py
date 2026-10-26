#!/usr/bin/env python3
"""mlvmotion vs poc/mlv_motion.py on a real clip.

Error-path and synthetic checks always run. Real-clip checks need MLV2Resolve_GYRO_DIR (folder with M24-1845.MLV) and MLV2Resolve_PY (python with numpy + imagecodecs);
skips (exit 0) when either is unset. The reference writes its CSV next to the clip, so the clip is
symlinked into a temp dir first (the original folder is never written to).
"""
import math, os, struct, shutil, statistics, subprocess, sys, tempfile, time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BIN = os.path.join(REPO, "build", "engine", "mlvmotion")
POC = os.path.join(REPO, "poc", "mlv_motion.py")


def rows(text):
    out = []
    for line in text.strip().splitlines()[1:]:
        f, dx, dy, pk = line.split(",")
        out.append((int(f), float(dx), float(dy), float(pk)))
    return out


def pearson(a, b):
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    num = sum((x - ma) * (y - mb) for x, y in zip(a, b))
    den = math.sqrt(sum((x - ma) ** 2 for x in a) * sum((y - mb) ** 2 for y in b))
    return num / den


def run(*args):
    return subprocess.run([BIN, *args], capture_output=True, text=True)


def expect_fail(args, what):
    r = run(*args)
    assert r.returncode == 2, (what, r.returncode, r.stderr)
    assert r.stdout == "", (what, "stdout must be empty on failure")
    assert r.stderr.strip() and "\n" not in r.stderr.strip(), (what, r.stderr)


def error_paths(tmp):
    """No real data needed."""
    expect_fail([os.path.join(tmp, "nonexistent.MLV")], "missing file")
    junk = os.path.join(tmp, "junk.MLV")
    open(junk, "wb").write(b"not an mlv" * 20)
    expect_fail([junk], "non-MLV")
    # synthetic MLV: valid header (LJ92 raw), a VIDF whose payload is garbage, then a truncated block
    hdr = bytearray(52)
    hdr[0:4] = b"MLVI"; struct.pack_into("<I", hdr, 4, 52)
    struct.pack_into("<H", hdr, 24, 0); struct.pack_into("<H", hdr, 26, 1)
    struct.pack_into("<H", hdr, 32, 0x21)
    def vidf(n):
        payload = b"\xff\xd8garbage" * 20
        b = bytearray(32); b[0:4] = b"VIDF"; struct.pack_into("<I", b, 4, 32 + len(payload))
        struct.pack_into("<I", b, 16, n)
        return bytes(b) + payload
    syn = os.path.join(tmp, "syn.MLV")
    open(syn, "wb").write(bytes(hdr) + vidf(0) + vidf(1))
    expect_fail([syn], "garbage LJ92 frames")
    open(syn, "wb").write(bytes(hdr) + vidf(0)[:100])
    expect_fail([syn], "truncated synthetic file")
    expect_fail([syn, "--squeeze", "nan"], "nan squeeze")
    expect_fail([syn, "--squeeze", "inf"], "inf squeeze")
    # declared 2 files but no chunk next to it
    h2 = bytearray(hdr); struct.pack_into("<H", h2, 26, 2)
    open(syn, "wb").write(bytes(h2) + vidf(0) + vidf(1))
    r = run(syn)
    assert r.returncode == 2 and "chunk" in r.stderr and r.stdout == "", r


def blocks(path, max_vidf):
    """(header52, [non-VIDF blocks bytes], [VIDF blocks bytes]) reading only the file's start."""
    out_other, out_v = [], []
    with open(path, "rb") as f:
        head = f.read(52)
        while len(out_v) < max_vidf:
            h = f.read(16)
            if len(h) < 16:
                break
            size = struct.unpack_from("<I", h, 4)[0]
            body = f.read(size - 16)
            (out_v if h[:4] == b"VIDF" else out_other).append(h + body)
    return head, out_other, out_v


def chunk_test(clip, tmp):
    head, other, vid = blocks(clip, 40)
    assert len(vid) == 40
    def mk(fnum, fcount, blks):
        h = bytearray(head)
        struct.pack_into("<H", h, 24, fnum); struct.pack_into("<H", h, 26, fcount)
        return bytes(h) + b"".join(blks)
    d = os.path.join(tmp, "split"); os.makedirs(d)
    whole = os.path.join(tmp, "whole.MLV")
    open(whole, "wb").write(mk(0, 1, other + vid))
    open(os.path.join(d, "S.MLV"), "wb").write(mk(0, 2, other + vid[:20]))
    open(os.path.join(d, "S.M00"), "wb").write(mk(1, 2, vid[20:]))
    r_whole, r_split = run(whole), run(os.path.join(d, "S.MLV"))
    assert r_whole.returncode == 0 and r_split.returncode == 0, (r_whole.stderr, r_split.stderr)
    assert r_whole.stdout == r_split.stdout and len(r_split.stdout.splitlines()) == 40, "split != whole"
    # duplicate frame numbers are dropped (first kept)
    dup = os.path.join(tmp, "dup.MLV")
    open(dup, "wb").write(mk(0, 1, other + vid + vid[5:10]))
    assert run(dup).stdout == r_whole.stdout, "duplicates changed the output"
    # chunk declared but missing
    os.remove(os.path.join(d, "S.M00"))
    r = run(os.path.join(d, "S.MLV"))
    assert r.returncode == 2 and r.stdout == "" and "chunk" in r.stderr, r
    print("chunk tests OK")


def main():
    with tempfile.TemporaryDirectory() as tmp:
        assert os.path.exists(BIN), "build/engine/mlvmotion missing (run scripts/build-engine.sh)"
        error_paths(tmp)
        print("error paths OK")
    d, py = os.environ.get("MLV2Resolve_GYRO_DIR"), os.environ.get("MLV2Resolve_PY")
    if not d or not py:
        print("SKIP real-clip checks: MLV2Resolve_GYRO_DIR / MLV2Resolve_PY not set")
        return 0
    clip = os.path.join(d, "M24-1845.MLV")
    if not os.path.exists(clip):
        print("SKIP: clip not found")
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        chunk_test(clip, tmp)
        link = os.path.join(tmp, "M24-1845.MLV")
        os.symlink(clip, link)
        subprocess.run([py, POC, link], check=True, capture_output=True)
        ref = rows(open(os.path.join(tmp, "M24-1845.motion.csv")).read())
    t = time.time()
    r = run(clip)
    elapsed = time.time() - t
    assert r.returncode == 0, r.stderr
    got = rows(r.stdout)
    ncpu = os.cpu_count() or 1
    print("rows: ref=%d got=%d, runtime %.2fs (%d cpus)" % (len(ref), len(got), elapsed, ncpu))
    assert len(ref) == len(got) == 528
    assert [x[0] for x in ref] == [x[0] for x in got]
    for k, name in ((1, "dx"), (2, "dy")):
        a, b = [x[k] for x in ref], [x[k] for x in got]
        rr = pearson(a, b)
        med = statistics.median(abs(x - y) for x, y in zip(a, b))
        print("%s: pearson=%.4f median|d|=%.3f px" % (name, rr, med))
        assert rr >= 0.98, name
        assert med <= 0.5, name
    if ncpu >= 8:
        assert elapsed <= 3.0, "too slow: %.2fs" % elapsed
    print("PASS")
    return 0


sys.exit(main())
