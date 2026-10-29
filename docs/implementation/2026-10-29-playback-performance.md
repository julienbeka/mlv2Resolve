# Playback performance investigation — 29 October 2026

Identification/exclusion of recorded Dual ISO was removed at the user's request. Version remains 0.2.3, build 105. The independently confirmed preview histogram leak fix and its regression test remain.

## Controlled measurements

UPDLV currently contains 42 MLV clips. No user volume was mounted when investigation started. The probes read source clips without changing them; generated indexes/logs are in temporary directories. Only isolated temporary mounts were created and then unmounted. Tests read 84 frames round-robin (two per clip), preview mode, focus pixel correction enabled. Results are wall-clock throughput, not actual Resolve playback FPS. Filesystem caches/read-ahead are not purged.

| Probe | Bad pixel correction | Clips | Throughput |
|---|---|---|---|
| Direct frame processing | On | 1 (64 sequential frames) | 49.54 fps |
| Direct frame processing | On | 42 | 30.93 fps |
| Direct frame processing | Off | 42 | 48.03 fps |
| Direct grading processing | On | 42 | 25.53 fps |
| Mounted full DNG reads | On | 42 | 26.02 fps |
| Mounted full DNG reads | Off | 42 | 37.95 fps |

Mounted sequential reads reached 103.97 / 106.30 fps with / without bad pixel correction due to NFS read-ahead and caching; those are not directly comparable to direct synchronous processing. Root plus sequence listing took 0.46 / 0.42 s.

## Evidence and practical limit

`cs.c` stores only eight bad pixel maps. Alternating among more clips evicts maps and rescans their pixels. The latest real UPDLV engine session logged 149 analyses for 42 distinct clip GUIDs; the comparison 20261025 session logged eight analyses for eight distinct GUIDs. Controlled probes show that disabling this correction improves round-robin throughput by about 46% through the mount. This is a demonstrated contributor, not yet proof of the complete Resolve stall. The issue is consistent with extra image requests for thumbnails competing with playback.

No confirmed Dual ISO footage is needed to trigger this cost. Grading was slower than preview in the controlled direct test; the earlier improvement on switching modes may involve invalidated caches or changed concurrent requests rather than grading being inherently faster.

The source SSD had about 17 GiB available (96% data-volume usage). macOS reported 24 GiB RAM and about 2.7 GiB allocated swap. These snapshots do not establish active memory pressure or explain the stall by themselves.

## Next isolation test in Resolve

With other settings unchanged, unmount the shoot, disable Settings → Advanced → Fix Dead Pixels, remount and play the same source clip in the 42-clip project. The preference applies only at mounting. Keep focus pixel correction enabled. Record actual playback rate and whether background thumbnail work has finished. If the stall persists, capture process samples and DNG read latency during the stall to locate the remaining bottleneck; avoid changing GPU/color/timeline settings simultaneously.

## Validation

After removal: 269 Swift tests, nine skipped, zero failures. App build succeeded. Engine probes completed with no decode errors and temporary mounts were removed. Reproducible diagnostic programs are in engine/tests/frame_benchmark.c and engine/tests/mounted_benchmark.py.

## Live frozen-viewer capture (00:54–00:59 Paris)

During the actual freeze, source DNG reads still completed in 34–37 ms; root listing completed in 55 ms. MLVFS sampled mostly idle waiting for requests and had a 50.3 MiB physical footprint. Resolve had a 36.4 GiB footprint (peak 38.1), later 39.0 GiB (peak 41.2), on a 24 GiB machine. Swap usage reached about 16 GiB. Resolve logs repeatedly reported graph thumbnail requests timing out.

An active render-worker stack was in GyroflowNiyien.ofx (installed version 2.1.2.60), and the project API confirmed 42 Gyroflow nodes on 42 video clips. Global color/Fusion bypass changed displayed color but did not make the transport advance; it did not release previously allocated memory.

UPDLV was saved and exported to build/diagnostics/UPDLV-before-gyro-test.drp. A separate project named `UPDLV - diagnostic sans Gyroflow` was cloned from that backup; 42 Gyroflow nodes were disabled there and the clone saved. No grading nodes in the original were disabled. A project switch took over a minute. Footprint temporarily dropped to 7.4 GiB; playback remained stalled in that process. Resolve was subsequently quit normally (no force kill) to test the saved disabled-node copy in a fresh process.

These observations shift the investigation to Resolve/plugin memory and processing rather than proving the earlier throughput limitation is the cause of the complete stall. Samples retained locally under build/diagnostics.

### Fresh-process verification

The saved diagnostic clone loaded successfully after normal Resolve restart. Resolve footprint was 4.0 GiB (peak 4.2). With only the 42 Gyroflow nodes disabled and the same 42 mounted DNG clips, native timeline seek refreshed the image and native Space playback showed the green 25 fps indicator. Playback visibly advanced across cuts from 01:03:28:17 to 01:03:42:24 before being stopped. The diagnostic clone remains open; the original project and exported backup are preserved.

Important limitation: restart also clears Resolve caches, so this test strongly implicates the Gyroflow/Resolve processing and memory path but does not yet distinguish a plugin defect, serialized node settings, or cache interaction. No further application-code changes were made from this observation. Earlier throughput/cache limitations do not explain the whole frozen-viewer symptom by themselves.

## Standard Gyroflow comparison

Installed bundles: Gyroflow.ofx.bundle / xyz.gyroflow.ofx version 2.1.1.0, and GyroflowNiyien.ofx.bundle / com.niyien.gyroflow.ofx version 2.1.2.60. A separate `UPDLV - test Gyroflow` project was cloned from the saved disabled-node project. Original projects and MLV/gyro source files were not changed.

The scripting API cannot add arbitrary OFX tools. Native drag/drop did not apply the effect, so a diagnostic DRX grade was prepared using the installed plugin's identifier (`xyz.gyroflow`) and an existing serialized node structure. Stored NiYien parameter overrides were removed; ProjectPath was supplied explicitly. API verification returned exactly `OFX: Gyroflow`. On synced clip M28-2252, a timeline re-export verified the standard plugin's `Status=OK`, correct LoadedProject filename and canonical mounted ProjectPath. This demonstrates actual file loading, not simply an empty/bypassed node.

For the full comparison, a clean grade exported from untouched clip M28-1922 in the copied project preserved project Camera Raw defaults; per-clip grades were generated with the standard plugin and applied to all 42 clips. Thirty-five source gyroflow sidecars exist; those paths were supplied individually; the remaining seven had no project path. All 42 nodes were verified as the standard OFX plugin and enabled. The test project was saved.

In the initial process, footprint grew from 16.7 to 21.6 GiB and a sampled active render-worker stack ran inside Gyroflow.ofx. To remove prior NiYien/cache contamination, Resolve was quit normally and restarted, and the standard-only test project loaded into a fresh process. It again displayed a black viewer and incomplete thumbnails. Native timeline seek and Space activated Play but did not deliver usable image playback. Footprint was 14.4 GiB at sampling, peak 17.7. The test was saved and Resolve quit normally before restoring the usable disabled-node diagnostic project.

Conclusion: swapping the installed NiYien fork for the installed standard plugin is not sufficient with this test configuration. It does not establish a defect in every standard-plugin setup: the generated node serialization, sidecar data, image-sequence integration, and plugin/cache interactions remain candidates. No product defaults or bundled templates were changed as a result. Samples and diagnostic grades/scripts are retained under build/diagnostics.

## 29 October — many Gyroflow instances: full-session telemetry amplification

Research and a controlled data-only change identify a concrete optimization. There is no established
42-node limit. The application generated 34 different projects referring to the same 250,648,064-byte
SenseFlow session log (15,649,823 gyro samples at 1 kHz, approximately 4 h 21 min). Another project,
M28-1936, refers to an unrelated small October 24 log. The tiny `.gyroflow` JSON files do not reflect
what each stabilization instance loads. The upstream SenseFlow parser allocates gyro and accelerometer
vectors for the whole log before returning them; separate clip projects require separate stabilization
state. Local plugin logs explicitly showed full-file parsing without a time range.

Primary research:
- https://github.com/AdrianEddy/telemetry-parser/blob/master/src/senseflow/binary.rs
- https://github.com/gyroflow/gyroflow-plugins/blob/v2.1.1/common/src/lib.rs
  (global manager cache and per-instance manager caches; neither constitutes a hard clip-count limit)
- https://github.com/gyroflow/gyroflow-plugins/issues/65
  (reported batch-copy relinking bug; distinct from the proven telemetry-size improvement)
- https://github.com/gyroflow/gyroflow-plugins/issues/64
  (Metal queue lifetime crash report, closed October 11; not proof of the cause of this freeze)

### Experiment and result

1. Created `UPDLV - test gyro allege` from the previously backed-up disabled-node diagnostic project.
2. Copied exact binary sensor records for each clip with ten seconds of handles on either side.
   Retained the header, scales, rate, orientation, accelerometer and checksums. Shifted timestamps and
   all three constant sync offsets by the same amount. No sensor downsampling or video transcoding.
3. Merely setting an alternate ProjectPath in the grade was insufficient: on first rendering the plugin
   can replace it with the sidecar found beside the DNG. The initial unsuccessful test therefore still
   loaded full-session data for some clips and is not evidence against cropping.
4. Backed up source `.gyroflow` sidecars and associated the excerpts through those canonical sidecars.
   Restarted Resolve normally to release old managers. Plugin traces then reported 28 excerpt loads,
   zero 250 MB loads, each parsing tens of thousands of samples rather than 15.6 million.
5. Native timeline playback in the test project showed green **25 fps**, moving images and working
   seeking. Resolve footprint measured **5.0 GiB**, peak **5.0 GiB** (`resolve-cropped-working.sample`),
   compared with approximately 39 GiB during the original freeze. This is a local playback test, not a
   long-run render or pixel-identical stabilization comparison; cropping changes initialization context.

### Durable optimization applied to UPDLV

Added `scripts/optimize-gyro-logs.py`, a standard-library maintenance tool. Default is dry-run; `--apply`
creates immutable, content-named excerpts and original project backups in the shoot's
`.mlv2resolve-gyro/` directory, then atomically replaces each sidecar with adjusted references and offsets.
It validates checksums, supports the observed A1 accel+gyro record format and constant offsets only,
and refuses out-of-range clips. It skips already optimized projects. Do not remove this directory while
using the optimized projects; the full original session log remains untouched.

Applied to 34 UPDLV projects: repeated telemetry input **8,522,034,176 → 16,321,392 bytes** (about 522×
smaller). All 34 original sidecars are backed up in `.mlv2resolve-gyro/backups/`. M28-1936 was preserved
byte-for-byte because its small referenced log does not cover the clip. It needs a separate sync review.
The test-only alternate `.gyroflow` files still exist under build/diagnostics for reproducibility, but the
34 source sidecars reference durable excerpts alongside the source footage, not build files.

Reloaded original `UPDLV` with **42 original Gyroflow nodes**, unchanged topology and parameters, after
another normal Resolve restart. Native viewer refreshed, playback advanced through cuts from around
01:02:50 to 01:05:17 and later 01:06:08. Original-project footprint was **5.0 GiB**, peak **5.0 GiB**
(`resolve-original-optimized.sample`); traces contained only optimized-log loads at inspection time.
Saved original project normally. The explicit 25 fps measurement above belongs to the test copy.

Validation: seven Python tests cover record identity across one-second markers, offset/time mapping,
header timestamp adjustment, padding at log boundaries, checksum rejection, unsupported format
rejection, out-of-range/variable-sync refusal, dry-run without writes, original-log preservation,
backup creation and repeat-apply idempotence. All seven pass. This utility is not yet called automatically
by the app's sync coordinator; a new sync/regeneration in build 105 will still write a full-log reference.
No new application build or plugin installation was performed for this investigation.


## Integrated release 0.2.4 (build 106)

The previous maintenance-only limitation is resolved. `GyroLogExcerpt.swift` now performs the validated
binary excerpt operation inside the Swift application, with no Python dependency. New sync and regeneration
write excerpts before publishing their sidecar. On mount, sidecars recorded in `gyroWritten` are migrated
without rerunning motion estimation, preserving all other JSON fields, backing up the exact original and
keeping stored full-log lag metadata for clock-skew estimation. Foreign sidecars remain untouched.
Migration cancellation propagates to the detached worker; the worker checks cancellation during scanning
and before publication. Unsupported/corrupt logs and variable/out-of-range offsets are refused without
replacing the existing sidecar. Header dates use the Gregorian calendar matching `A1Log.parseHeader`.

Final validation: 279 Swift tests, 9 optional tests skipped, zero failures; included real-file check confirms
byte-identical excerpt and identical offsets compared with the Resolve-validated Python output. Seven
standalone Python utility tests also pass. Local application is 0.2.4 (106), arm64, with successful deep/strict
signature verification; ZIP and SHA-256 are in `build/releases/`. Existing installed/running app was not
replaced, to preserve the current mounted editing session. Restart Resolve after legacy migration if it had
already loaded full-session logs.
