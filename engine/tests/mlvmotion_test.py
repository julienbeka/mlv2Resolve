#!/usr/bin/env python3
"""mlvmotion vs poc/mlv_motion.py on a real clip.

Needs MLV2DNG_GYRO_DIR (folder with M24-1845.MLV) and MLV2DNG_PY (python with numpy + imagecodecs);
skips (exit 0) when either is unset. The reference writes its CSV next to the clip, so the clip is
symlinked into a temp dir first (the original folder is never written to).
"""
import math, os, shutil, statistics, subprocess, sys, tempfile, time

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


def main():
    d, py = os.environ.get("MLV2DNG_GYRO_DIR"), os.environ.get("MLV2DNG_PY")
    if not d or not py:
        print("SKIP: MLV2DNG_GYRO_DIR / MLV2DNG_PY not set")
        return 0
    clip = os.path.join(d, "M24-1845.MLV")
    if not os.path.exists(clip):
        print("SKIP: clip not found")
        return 0
    assert os.path.exists(BIN), "build/engine/mlvmotion missing (run scripts/build-engine.sh)"
    # error paths
    r = subprocess.run([BIN, os.path.join(d, "nonexistent.MLV")], capture_output=True, text=True)
    assert r.returncode == 2 and r.stderr.strip().count("\n") == 0 and r.stderr.strip(), r
    with tempfile.TemporaryDirectory() as tmp:
        junk = os.path.join(tmp, "junk.MLV")
        open(junk, "wb").write(b"not an mlv" * 20)
        r = subprocess.run([BIN, junk], capture_output=True, text=True)
        assert r.returncode == 2 and r.stderr.strip(), r
        link = os.path.join(tmp, "M24-1845.MLV")
        os.symlink(clip, link)
        subprocess.run([py, POC, link], check=True, capture_output=True)
        ref = rows(open(os.path.join(tmp, "M24-1845.motion.csv")).read())
    t = time.time()
    r = subprocess.run([BIN, clip], capture_output=True, text=True)
    elapsed = time.time() - t
    assert r.returncode == 0, r.stderr
    got = rows(r.stdout)
    print("rows: ref=%d got=%d, runtime %.2fs" % (len(ref), len(got), elapsed))
    assert len(ref) == len(got) == 528
    assert [x[0] for x in ref] == [x[0] for x in got]
    for k, name in ((1, "dx"), (2, "dy")):
        a, b = [x[k] for x in ref], [x[k] for x in got]
        rr = pearson(a, b)
        med = statistics.median(abs(x - y) for x, y in zip(a, b))
        print("%s: pearson=%.4f median|d|=%.3f px" % (name, rr, med))
        assert rr >= 0.98, name
        assert med <= 0.5, name
    assert elapsed <= 3.0, "too slow: %.2fs" % elapsed
    print("PASS")
    return 0


sys.exit(main())
