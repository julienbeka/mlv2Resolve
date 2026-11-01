# WAV header correction implementation plan

> **For agentic workers:** Execute inline with superpowers:executing-plans; use test-driven-development and verification-before-completion.

**Goal:** Remove the WAV size inconsistency reported by Resolve without claiming to fix the unproven crash cause.

**Architecture:** Keep virtual WAV generation and PCM bytes unchanged. Correct the RIFF and data lengths emitted by `wav_get_data_direct` and verify them against the actual virtual file boundaries.

**Tech Stack:** C, standalone engine regression tests, Xcode app build.

**Spec:** Resolve logs report audio lengths eight bytes larger than the virtual file. RIFF length must exclude its initial eight bytes; the data length must exclude the entire WAV header.

## Global constraints

- Increment patch version in app/project.yml and scripts/build-app.sh; update release notes.
- Rebuild and verify build/mlv2Resolve.app/Contents/Info.plist.
- Do not change user footage, project database, running mounts or Resolve security preferences.

## Review focus

- Validate a normal PCM payload and a header-only WAV.
- Check partial reads of the length fields, since Resolve reads virtual files in slices.
- Verify the PCM content remains byte-for-byte identical.
- Keep connection failure and first-pass playback latency explicitly unresolved.

## Task 1: Correct WAV lengths

**Files:** engine/tests/wav_header_test.c, engine/mlvfs/wav.c, engine/Makefile.arm64.

- [x] Add a test that parses the generated RIFF chunks and checks their boundaries and PCM payload.
- [x] Run the test and observe the expected size mismatch.
- [x] Correct the two size fields, then rerun the test.
- [x] Run relevant engine regression tests and inspect the patch.

## Task 2: Package local correction

**Files:** app/project.yml, scripts/build-app.sh, scripts/release-notes.md.

- [x] Set version 0.2.15 in both defaults and document the audio correction in English and French.
- [x] Build the local app and verify its version, signature and bundled engine.

## Evidence and rulings

- Working on local branch codex/resolve-wav-header in the current checkout; no user data or external installation changes.
- Direct Resolve connections fail through Lua, explicit loopback and built-in Python. Local scripting is already enabled. No connection code change is justified yet.
- The existing 256 MiB decoded-frame cache and second-pass fluency support a preparation/cache hypothesis; no measured bottleneck justifies enlarging it.
- Regression evidence: the WAV test failed on both length fields before the fix, then passed after. Cache tests pass under UBSan and Guard Malloc; 128 rejected preview frames release histograms and preserve pixels. Independent patch review found no actionable issues.
- Local build succeeded: CFBundleShortVersionString=0.2.15, CFBundleVersion=110. Deep strict signature verification passes; the bundled engine matches build/engine/mlvfs. The installed /Applications copy and running mount are unchanged.
- Read-only engine benchmark on 24 frames of M29-2305.MLV, with bad/focus pixel corrections: preview 40.12 fps (median 24.62 ms), raw 49.89 fps (median 19.08 ms). This excludes Resolve/FUSE and is not a cold-disk or timeline benchmark.
- Isolated FUSE-T benchmark on the same clip, 84 sequential reads: 32.24 fps (median 31.4 ms, p95 32.54 ms). Rereading the same frames with one clip in the fixture: 1074.93 fps (median 0.91 ms). This measures virtual DNG reads, not full Resolve playback. The temporary test volume was unmounted successfully; the user's UPDLV mount was not changed.
- User confirms Resolve was restarted and UPDLV opened directly in Resolve. A subsequent external read-only Lua probe still returns NO_RESOLVE; neither app settings nor connection code were changed.
