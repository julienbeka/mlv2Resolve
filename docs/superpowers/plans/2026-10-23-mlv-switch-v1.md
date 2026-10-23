# MLV Switch v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that mounts folders of Magic Lantern MLV clips as virtual CinemaDNG sequences (via a patched MLVFS on FUSE-T) so they can be edited directly in DaVinci Resolve, with no terminal and no boot-security change.

**Architecture:** Two layers. (1) `engine/mlvfs`: a vendored fork of MLVFS (GPL, C) built for arm64 against FUSE-T's libfuse, patched for EOS M focus pixels and 1x3 squeeze. (2) `app/`: a SwiftUI `MenuBarExtra` app whose logic lives in a SwiftPM library `MLVSwitchCore` (scanning, mount paths, process supervision, dependency checks, state) unit-tested with `swift test`; the app target is generated with XcodeGen and bundles the `mlvfs` binary. Phase 1 (Tasks 1–4) proves the engine and ends with a go/no-go gate; Phase 2 (Tasks 5–11) builds the app.

**Tech Stack:** C (MLVFS fork), FUSE-T 1.2.6 (libfuse-t, FUSE 2.6 API), Swift 6 / SwiftUI, SwiftPM, XcodeGen, XCTest, exiftool + Python 3 (test tooling only).

**Spec:** `docs/specs/2026-10-23-mlv-switch-design.md`

## Global Constraints

- Apple Silicon (arm64) only; deployment target macOS 14; developed on macOS 26, Apple M4, 24 Go.
- FUSE-T is the default backend; never require macFUSE or reducing boot security in v1 (macFUSE opt-in is the fallback only if the Task 4 gate fails — a separate plan).
- No Apple Developer account: ad-hoc signing ("Sign to Run Locally"); notarization is out of scope.
- License GPL-3.0-or-later for the whole repo; credit Danne (Switch) and David Milligan (MLVFS) in `README.md` and the About box.
- Original MLV folders are never written to (read-only mounts, no sidecar files).
- Mount point: `~/MLV Switch/<shoot folder name>`; on a name collision among mounted shoots, `~/MLV Switch/<shoot folder name> (<volume name>)`.
- Default MLVFS processing: `--resolve-naming --bad-pix --dual-iso-preview`, focus-pixel fix on; "qualité étalonnage" = `dual_iso=2`, "montage fluide" = `dual_iso=1`, switched globally at runtime through each MLVFS web GUI (`GET /set_value?dual_iso=N`), never by remounting.
- UI text in French. No technical settings visible outside « Réglages… → Avancé ».
- Test clips: `M29-0615.MLV` (320 frames, 25 fps, 1600×2040, LJ92, EOS M 0x80000331) and `M23-1246.MLV` (539 frames) in the project root. Never commit them (`.gitignore` `*.MLV`, `*.M0?`).

## Review Focus

1. External SSD unplugged while a shoot is mounted → the mount is removed cleanly, the icon shows the alert state, no hung Finder; replugging remounts at the same path (Task 10 test).
2. Shoot folder names with spaces, accents or emoji (`Tournage été 2026 🎬`) → scanned, mounted and passed to `mlvfs` without shell quoting issues (Task 6 and Task 8 tests).
3. Spanned clips (`A001.MLV` + `A001.M00` + `A001.M01`) → counted as one clip and its size summed (Task 6 test).
4. `mlvfs` crashing or the app being force-quit → no stale mount left in `~/MLV Switch`; on next launch stale mount points are unmounted and removed before remounting (Task 8 test).
5. Web-GUI port already taken by another app → the next free port is used, and the dual ISO switch still reaches every process (Task 8 test).

---

## Phase 1 — Engine and go/no-go

### Task 1: Repository and vendored MLVFS building for arm64 on FUSE-T

**Files:**
- Create: `.gitignore`, `README.md`, `LICENSE` (GPL-3.0 text), `engine/mlvfs/` (copy of `davidmilligan/MLVFS` @ 2016-05-31 `mlvfs/` directory), `engine/Makefile.arm64`, `scripts/build-engine.sh`
- Move: existing `poc/` stays as is (not part of the build).

**Interfaces:**
- Produces: `scripts/build-engine.sh` → writes `build/engine/mlvfs` (arm64 Mach-O, ad-hoc signed). Later tasks call this script.

- [ ] **Step 1:** `git init`; `.gitignore` contains `*.MLV`, `*.M0?`, `build/`, `.superpowers/`, `*.gcsv`, `*.mp4`, `*.motion.csv`, `poc/out/`.
- [ ] **Step 2:** Install FUSE-T for development only: `brew install macos-fuse-t/homebrew-cask/fuse-t` (the app will install it itself in Task 9). Expected: `/usr/local/lib/libfuse-t.dylib` and `/usr/local/include/fuse/fuse.h` exist.
- [ ] **Step 3:** Copy MLVFS sources into `engine/mlvfs/`. Write `engine/Makefile.arm64` from the upstream `Makefile`: `-arch arm64`, `-I/usr/local/include/fuse`, `-L/usr/local/lib -lfuse-t`, `-DFUSE_USE_VERSION=26 -D_FILE_OFFSET_BITS=64`, `VERSION` from `git describe` of this repo. Replace SSE-only code paths (`sleefsseavx.c`, `helpersse2.h` used by `amaze_demosaic_RT.c`) with the plain-C fallbacks already in the file when `__SSE2__` is undefined; if a file has no fallback, add `sse2neon.h` (MIT, vendored in `engine/third_party/`).
- [ ] **Step 4:** `scripts/build-engine.sh`: runs `make -f Makefile.arm64`, copies to `build/engine/mlvfs`, `codesign -s - --force`.
- [ ] **Step 5:** Verify. Run: `scripts/build-engine.sh && file build/engine/mlvfs && build/engine/mlvfs --version`. Expected: `Mach-O 64-bit executable arm64` and a version string, exit 0.
- [ ] **Step 6:** Commit `chore: vendor MLVFS and build it for arm64 against FUSE-T`.

### Task 2: Mount spike and engine test harness

**Files:**
- Create: `engine/tests/mount_test.py` (Python 3 stdlib only), `engine/tests/README.md`

**Interfaces:**
- Consumes: `build/engine/mlvfs`.
- Produces: `python3 engine/tests/mount_test.py <clip.MLV> [--expect-frames N] [--min-fps F] [--backend nfs|smb]` — mounts the clip's folder in a temp dir, asserts, unmounts. Exit 0 = pass. Reused by Tasks 3, 4.

- [ ] **Step 1: Write the test.** It launches `mlvfs <mnt> --mlv-dir=<folder> --resolve-naming --bad-pix -f` (foreground, killed at the end), waits ≤10 s for `<mnt>/<clip>/` to appear, then asserts:
  - number of `*.dng` in the clip folder == `--expect-frames` (320 for `M29-0615.MLV`);
  - first DNG: TIFF magic `II*\0`, ImageWidth 1600, ImageLength 2040 (parse IFD0 with `struct`);
  - sequential read of all DNGs: frames per second ≥ `--min-fps` (default 25);
  - after `umount <mnt>`, the mount point is empty.
- [ ] **Step 2:** Run: `python3 engine/tests/mount_test.py M29-0615.MLV --expect-frames 320`. Record the result (pass/fail, measured fps, any mount errors) in `docs/spikes/2026-10-engine.md`.
- [ ] **Step 3:** If fps < 25 or the mount drops, repeat with the FUSE-T SMB backend (`--backend smb` sets the FUSE-T backend option documented in its README) and record both.
- [ ] **Step 4:** Commit `test: engine mount harness and first FUSE-T measurements`.

### Task 3: 1x3 squeeze and focus pixels in the MLVFS fork

**Files:**
- Modify: `engine/mlvfs/dng.c` (squeeze detection around the current `aspect_ratio > 2.0 && rawH <= 720` check, ~line 659)
- Create: `engine/mlvfs/focus_pixels.c`, `engine/mlvfs/focus_pixels.h`, `engine/mlvfs/fpm/` (EOS M `.fpm` maps taken from MLV App `ilia3101/MLV-App`, GPL, keep their file names)
- Modify: `engine/mlvfs/main.c` (call the fix after decode, before DNG packing; option `--no-focus-pixels`), `engine/Makefile.arm64`, `engine/tests/mount_test.py`

**Interfaces:**
- Produces: `int fpm_fix(uint16_t *raw, int width, int height, uint32_t camera_model, int crop_x, int crop_y, const char *fpm_dir)` returning the number of pixels corrected (0 if no map). The `fpm_dir` is passed with a new option `--fpm-dir=%s` (the app passes its bundle's `Resources/fpm`).

- [ ] **Step 1: Extend the test.** `mount_test.py --expect-scale 3,1` asserts the first DNG's `DefaultScale` tag (50718) equals `3/1, 1/1`; `--expect-fpm` asserts the `mlvfs` log line `focus pixels: N corrected` with N > 0.
- [ ] **Step 2:** Run it on `M29-0615.MLV`. Expected: FAIL (DefaultScale absent or 1,1; no focus pixel log).
- [ ] **Step 3:** Squeeze: derive horizontal scale from the MLV `RAWC` block (`binning_x + skipping_x` horizontally vs vertically; for this clip RAWC = binning_x 3, binning_y 1 → scale 3:1). Keep the old heuristic only when RAWC is absent.
- [ ] **Step 4:** Focus pixels: port MLV App's map lookup (camera id + raw dimensions + crop position) and its interpolation of listed pixels; log the count once per clip.
- [ ] **Step 5:** Run: `python3 engine/tests/mount_test.py M29-0615.MLV --expect-frames 320 --expect-scale 3,1 --expect-fpm`. Expected: PASS. Also run on `M23-1246.MLV --expect-frames 539`.
- [ ] **Step 6:** Commit `feat(engine): 1x3 squeeze from RAWC and EOS M focus pixel fix`.

### Task 3b: Lossless decoding of Magic Lantern compressed clips (added during execution)

Added by controller ruling: the 2016 MLVFS LJ92 decoder produces noise on current Magic Lantern in-camera lossless clips (the test clips), so the DNGs are unusable although Tasks 2–3 pass.

**Files:**
- Modify: `engine/mlvfs/lj92.c`, `engine/mlvfs/lj92.h`, `engine/mlvfs/main.c` (decode path around the `lj92_compressed` branch, ~line 572–640)
- Create: `engine/tests/make_reference.py` (dev-only: needs numpy + imagecodecs), extend `engine/tests/mount_test.py`

**Interfaces:**
- Consumes: `build/engine/mlvfs`, harness from Tasks 2–3.
- Produces: `mount_test.py --expect-raw <ref_dir>` — compares the raw pixel values of DNG frames 0 and 160 (decoded per BitsPerSample/strip layout) with `<ref_dir>/<clip>_<frame>.u16` written by `make_reference.py <clip.MLV> <ref_dir> 0 160` (decodes the VIDF payload with `imagecodecs.ljpeg_decode`, reshapes `(h, w/2, 2)` → `(h, w)`, writes little-endian uint16). Mount for this check with `--no-focus-pixels` and without `--bad-pix`.

- [ ] **Step 1:** Write `make_reference.py` and the `--expect-raw` check; generate references for `M29-0615.MLV`; run the harness on the current binary. Expected: FAIL (pixel mismatch).
- [ ] **Step 2:** Port the lossless decoder used by MLV App (`ilia3101/MLV-App`, its current lj92 / "lossless" decode including the frame layout/untiling it applies) into MLVFS, replacing the old path for LJ92 clips; keep LZMA and uncompressed paths unchanged.
- [ ] **Step 3:** Run `mount_test.py M29-0615.MLV --expect-frames 320 --expect-raw build/ref` and the same for `M23-1246.MLV` (frames 0 and 160). Expected: PASS, exact match. Re-run Task 3's `--expect-scale 3,1 --expect-fpm` checks and the ≥25 fps check. Expected: PASS.
- [ ] **Step 4:** Commit `fix(engine): decode current Magic Lantern lossless clips`.

### Task 3c: Keep MLVFS index files out of the rushes folders (added during execution)

Added by controller ruling: upstream MLVFS writes `<clip>.IDX` next to each source MLV (`engine/mlvfs/index.c`, ~lines 115 and 189), violating « Original MLV folders are never written to ».

**Files:**
- Modify: `engine/mlvfs/index.c`, `engine/mlvfs/main.c` (option table), `engine/tests/mount_test.py`, `.gitignore` (add `*.IDX`)

**Interfaces:**
- Produces: mlvfs option `--index-dir=%s` (absolute directory, created if missing). Index file path = `<index-dir>/<hex of a stable 64-bit hash of the MLV's absolute path>_<file size>.IDX`, so two clips with the same name in different folders never collide and a changed file is re-indexed. Without the option, behaviour is unchanged (next to the MLV). The app (Task 8) always passes `--index-dir=~/Library/Caches/MLV Switch/index`.

- [ ] **Step 1:** Extend the harness: `--index-dir <dir>` is passed to mlvfs, and the harness snapshots the source folder (names, sizes, mtimes) before mounting and asserts it is identical after unmount (`--assert-source-untouched`, on by default). Run on the current binary with a fresh copy of the folder free of `.IDX` files. Expected: FAIL (new `.IDX` files appear).
- [ ] **Step 2:** Implement the option in both index read and write paths.
- [ ] **Step 3:** Run `mount_test.py M29-0615.MLV --expect-frames 320 --expect-raw build/ref --index-dir /tmp/mlvswitch-idx` twice (second run reuses the index). Expected: PASS both times, source folder untouched, `.IDX` present in the index dir.
- [ ] **Step 4:** Commit `fix(engine): write MLVFS index files to a cache directory`.

### Task 4: Resolve validation and go/no-go gate

**Files:**
- Create: `docs/spikes/2026-10-resolve.md`

This task is manual and done with the user (Resolve has no scripting in this phase).

- [ ] **Step 1:** Mount the project root with `mlvfs` (as in Task 2, not foreground) and ask the user to import `M29-0615` from the mount in Resolve Studio 21 (Media page), on a 25 fps timeline.
- [ ] **Step 2:** Record in the spike doc, with the user: a non-dual-ISO clip looks identical with `--dual-iso-preview` and `--dual-iso` (MLVFS must only process clips that are dual ISO), image displayed 4800×2040-shaped (squeeze honoured or not), focus-pixel dots visible or not, real-time playback at « Half » without dropped frames (Resolve's playback indicator), dual ISO switch on `M23-1246.MLV` via `curl "http://localhost:8000/set_value?dual_iso=2"` then right-click → refresh: image changes or not.
- [ ] **Step 3: Gate.** GO if mount stable + playback criterion met (spec « Critères de réussite »). If the squeeze is not honoured by Resolve, note it: the app will tell the user to set Clip Attributes → Pixel Aspect Ratio (acceptable for v1). NO-GO on FUSE-T (both backends) → stop and write the macFUSE opt-in plan instead of Phase 2.
- [ ] **Step 4:** Commit `docs: Resolve validation and engine go/no-go`.

## Phase 2 — Menu-bar app

### Task 5: Swift package and app skeleton

**Files:**
- Create: `app/Package.swift` (library `MLVSwitchCore`, test target `MLVSwitchCoreTests`), `app/Sources/MLVSwitchCore/Shoot.swift`, `app/project.yml` (XcodeGen: app target `MLV Switch`, bundle id `net.mlvswitch.app`, `LSUIElement = YES`, depends on the package, post-build script copies `build/engine/mlvfs` and `engine/mlvfs/fpm` into `Contents/Resources/`), `app/MLVSwitch/MLVSwitchApp.swift`, `scripts/build-app.sh`

**Interfaces:**
- Produces:
  ```swift
  public struct Clip: Equatable, Sendable { public let name: String; public let files: [URL]; public let bytes: Int64 }
  public struct Shoot: Equatable, Hashable, Sendable { public let name: String; public let folder: URL; public let volumeName: String; public let clips: [Clip]
      public var totalBytes: Int64 { get } }
  ```
- `scripts/build-app.sh` → `build/MLV Switch.app` (runs `build-engine.sh`, `xcodegen`, `xcodebuild -scheme "MLV Switch" -configuration Release`, ad-hoc sign).

- [ ] **Step 1:** `brew install xcodegen`. Write `Package.swift`, the two structs, and an empty `MenuBarExtra("MLV Switch", systemImage: "film.stack")` app.
- [ ] **Step 2:** Run: `cd app && swift build && cd .. && scripts/build-app.sh && ls "build/MLV Switch.app/Contents/Resources/mlvfs"`. Expected: build succeeds, file exists.
- [ ] **Step 3:** Commit `feat(app): package and menu-bar skeleton bundling mlvfs`.

### Task 6: Shoot scanning

**Files:**
- Create: `app/Sources/MLVSwitchCore/ShootScanner.swift`, `app/Tests/MLVSwitchCoreTests/ShootScannerTests.swift`

**Interfaces:**
- Produces: `public enum ShootScanner { public static func scan(_ folder: URL) throws -> [Shoot] }` — shoots sorted by name descending (newest date-named folders first).

- [ ] **Step 1: Write the failing tests** (build temp folders with empty files of known sizes):
  - `testFolderWithMLVIsOneShoot`: `T/A.MLV` → `[Shoot(name: "T", clips: 1)]`.
  - `testParentWithSubfolders`: `P/2026-10-23/A.MLV`, `P/2026-08-29/B.MLV`, `P/vide/notes.txt` → 2 shoots, names `["2026-10-23", "2026-08-29"]`; `vide` excluded.
  - `testSpannedClipIsOneClip`: `A001.MLV`(10 B) + `A001.M00`(20 B) + `A001.M01`(30 B) → 1 clip, `bytes == 60`, files ordered MLV, M00, M01.
  - `testUnicodeNames`: folder `Tournage été 2026 🎬` → shoot name preserved exactly.
  - `testOnlyOneLevelDeep`: `P/a/b/C.MLV` → no shoots.
  - `testExtensionsCaseInsensitive`: `a.mlv` counts.
- [ ] **Step 2:** Run `cd app && swift test --filter ShootScannerTests`. Expected: FAIL (no `ShootScanner`).
- [ ] **Step 3:** Implement with `FileManager.contentsOfDirectory(at:includingPropertiesForKeys: [.fileSizeKey, .volumeNameKey])`; the folder itself is a shoot if it contains MLV files, otherwise each direct subfolder that does.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): scan folders into shoots and clips`.

### Task 7: Stable mount paths

**Files:**
- Create: `app/Sources/MLVSwitchCore/MountPaths.swift`, `app/Tests/MLVSwitchCoreTests/MountPathsTests.swift`

**Interfaces:**
- Produces: `public struct MountPaths { public init(root: URL); public func mountPoint(for shoot: Shoot, alreadyMounted: [Shoot: URL]) -> URL }` — default `root` is `~/MLV Switch`.

- [ ] **Step 1: Write the failing tests:**
  - `testPathIsShootFolderName`: shoot `2026-10-23` on volume `SSD` → `root/2026-10-23`.
  - `testSameShootOnOtherDiskKeepsPath`: same name on volume `Backup`, nothing mounted → `root/2026-10-23`.
  - `testCollisionAddsVolumeName`: `2026-10-23` on `SSD` already mounted, second on `Backup` → `root/2026-10-23 (Backup)`.
  - `testAlreadyMountedShootKeepsItsPath`: asking again for the mounted shoot returns its existing URL.
- [ ] **Step 2:** Run `swift test --filter MountPathsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Strip `/` and `:` from names (replace with `-`).
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): deterministic mount paths with collision suffix`.

### Task 8: MLVFS process supervision and dual ISO switch

**Files:**
- Create: `app/Sources/MLVSwitchCore/MountManager.swift`, `app/Sources/MLVSwitchCore/DualISOMode.swift`, `app/Tests/MLVSwitchCoreTests/MountManagerTests.swift`, `app/Tests/MLVSwitchCoreTests/Fakes.swift`

**Interfaces:**
- Consumes: `Shoot`, `MountPaths`.
- Produces:
  ```swift
  public enum DualISOMode: Int, Sendable { case montageFluide = 1, qualiteEtalonnage = 2 }
  public protocol ProcessLauncher: Sendable { func launch(_ executable: URL, _ args: [String]) throws -> any RunningProcess }
  public protocol RunningProcess: AnyObject, Sendable { var isRunning: Bool { get }; func terminate(); var onExit: (@Sendable (Int32) -> Void)? { get set } }
  public protocol Unmounter: Sendable { func unmount(_ path: URL) throws; func isMountPoint(_ path: URL) -> Bool }
  public actor MountManager {
      public init(mlvfs: URL, fpmDir: URL, paths: MountPaths, launcher: ProcessLauncher, unmounter: Unmounter, http: (URL) async throws -> Void, portRange: ClosedRange<Int> = 8100...8199, isPortFree: @Sendable (Int) -> Bool)
      public func mount(_ shoot: Shoot, mode: DualISOMode, fixBadPixels: Bool = true, fixFocusPixels: Bool = true) throws -> URL
      public func unmount(_ shoot: Shoot) throws
      public func unmountAll()
      public func setMode(_ mode: DualISOMode) async   // GET http://127.0.0.1:<port>/set_value?dual_iso=<raw>
      public func cleanStaleMounts() throws            // unmount + remove empty dirs under paths.root not owned by a live process
      public var mounted: [Shoot: URL] { get }
  }
  ```
- Launch arguments (array, never a shell string), in this order: `mountPoint.path`, `--mlv-dir=\(shoot.folder.path)`, `--resolve-naming`, `--bad-pix` (only if `fixBadPixels`), `--no-focus-pixels` (only if `!fixFocusPixels`), `--dual-iso-preview` or `--dual-iso` (per `mode`), `--fpm-dir=\(fpmDir.path)`, `--index-dir=\(indexDir.path)` (`indexDir` = `~/Library/Caches/MLV Switch/index`, a new `MountManager.init` parameter), `--port=\(port)`, `-o`, `ro`, `-o`, `volname=\(shoot.name)`.

- [ ] **Step 1: Write the failing tests** with fakes (`FakeLauncher` records args, `FakeUnmounter`, recording `http`):
  - `testMountPassesArgsAsArray`: shoot `Tournage été 2026 🎬` → args[0] is `root/Tournage été 2026 🎬`, contains `--mlv-dir=<folder with spaces>` unescaped, `--dual-iso-preview`, `-o`, `ro`.
  - `testAdvancedTogglesChangeArgs`: `fixBadPixels: false, fixFocusPixels: false` → no `--bad-pix`, has `--no-focus-pixels`.
  - `testPortSkipsBusyPorts`: `isPortFree` false for 8100 → `--port=8101`.
  - `testSetModeHitsEveryProcess`: two shoots mounted on 8100/8101 → `setMode(.qualiteEtalonnage)` calls both `…/set_value?dual_iso=2`.
  - `testCrashCleansMount`: fake process exits with code 11 → unmounter called for its path, shoot removed from `mounted`.
  - `testCleanStaleMounts`: a mount point exists under root with no live process → unmounted and removed.
  - `testUnmountAll`: all processes terminated and paths unmounted.
- [ ] **Step 2:** Run `swift test --filter MountManagerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `MountManager`; real implementations `FoundationLauncher` (`Process`), `UmountUnmounter` (`/sbin/umount`, fallback `/usr/sbin/diskutil unmount force`), `isPortFree` via `bind()` on 127.0.0.1, `http` via `URLSession`.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5: Integration check.** Add `testRealMountOfTestClip` (skipped unless env `MLVSWITCH_INTEGRATION=1`): real launcher + `build/engine/mlvfs`, mounts the project root shoot, asserts 320 `.dng` under `<mount>/M29-0615*/`, unmounts. Run: `MLVSWITCH_INTEGRATION=1 swift test --filter testRealMountOfTestClip`. Expected: PASS.
- [ ] **Step 6:** Commit `feat(core): supervise mlvfs processes and switch dual ISO mode live`.

### Task 9: Dependencies and first-launch onboarding

**Files:**
- Create: `app/Sources/MLVSwitchCore/Dependencies.swift`, `app/Tests/MLVSwitchCoreTests/DependenciesTests.swift`, `app/MLVSwitch/OnboardingView.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum DependencyState: Equatable { case ready, fuseTMissing, fuseTOutdated(found: String, minimum: String) }
  public struct Dependencies { public init(fileExists: (String) -> Bool, fuseTVersion: () -> String?); public func check() -> DependencyState
      public static let minimumFuseT = "1.2.6"
      public static let fuseTInstaller = URL(string: "https://github.com/macos-fuse-t/fuse-t/releases/download/1.2.6/fuse-t-macos-installer-1.2.6.pkg")! }
  public func resolveAppURL(fileExists: (String) -> Bool) -> URL?   // "/Applications/DaVinci Resolve/DaVinci Resolve.app", then "/Applications/DaVinci Resolve Studio/DaVinci Resolve Studio.app"
  ```
- [ ] **Step 1: Write the failing tests:** `ready` when `/usr/local/lib/libfuse-t.dylib` exists and version `1.2.6`; `fuseTMissing` when absent; `fuseTOutdated(found:"1.1.0", minimum:"1.2.6")`; version comparison is numeric (`1.10.0 > 1.2.6`); `resolveAppURL` returns nil when neither path exists.
- [ ] **Step 2:** Run `swift test --filter DependenciesTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Version read from `pkgutil --pkg-info org.fuse-t.core` (or the receipt plist) in the real `fuseTVersion`.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** `OnboardingView`: shown when `check() != .ready`. Copy (French): « Pour afficher vos MLV en DNG, MLV Switch a besoin de FUSE-T, un composant gratuit qui ne modifie pas la sécurité de votre Mac. L'installation demande votre mot de passe une seule fois. » Button « Installer FUSE-T » downloads the pkg to `~/Library/Caches/MLV Switch/` and opens it with `NSWorkspace.shared.open` (macOS Installer); the view re-checks every 2 s and closes on `.ready`. If Resolve is missing: line « DaVinci Resolve n'a pas été trouvé — vous pourrez l'installer plus tard. » (non-blocking).
- [ ] **Step 6: Manual check:** `brew uninstall --cask fuse-t`, launch `build/MLV Switch.app`, install through the window, window closes. Commit `feat: dependency check and FUSE-T onboarding`.

### Task 10: Persistence, auto-remount and disk events

**Files:**
- Create: `app/Sources/MLVSwitchCore/AppState.swift`, `app/Tests/MLVSwitchCoreTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `ShootScanner`, `MountManager`, `DualISOMode`.
- Produces:
  ```swift
  @MainActor public final class AppState: ObservableObject {
      public init(manager: MountManager, defaults: UserDefaults, scan: @escaping (URL) throws -> [Shoot])
      @Published public private(set) var folder: URL?; @Published public private(set) var shoots: [Shoot]; @Published public private(set) var mounted: Set<String>  // shoot folder paths
      @Published public private(set) var mode: DualISOMode; @Published public private(set) var alert: String?
      public func choose(folder: URL) async; public func toggle(_ shoot: Shoot) async; public func setMode(_ m: DualISOMode) async
      public func restore() async            // launch: cleanStaleMounts, then remount saved shoots whose folder exists
      public func volumeDidMount(_ volume: URL) async; public func volumeWillUnmount(_ volume: URL) async
  }
  ```
  Defaults keys: `lastFolder` (bookmark data), `mountedShoots` ([String] folder paths), `dualISOMode` (Int).
- [ ] **Step 1: Write the failing tests** (in-memory `UserDefaults(suiteName:)`, fake manager via the Task 8 fakes):
  - `testLastFolderRemembered`; `testRestoreRemountsExistingOnly` (one saved folder missing → not mounted, no alert loop);
  - `testUnplugUnmountsAndAlerts`: `volumeWillUnmount(/Volumes/SSD)` → shoots on it unmounted, `alert == "Disque « SSD » débranché"`, still listed in `mountedShoots` for later;
  - `testReplugRemounts`: then `volumeDidMount(/Volumes/SSD)` → remounted at the same path, `alert == nil`;
  - `testModePersistsAndApplies`.
- [ ] **Step 2:** Run `swift test --filter AppStateTests`. Expected: FAIL.
- [ ] **Step 3:** Implement; the app wires `NSWorkspace.didMountNotification` / `willUnmountNotification` to the two volume methods, and `applicationWillTerminate` to `manager.unmountAll()` (saved list kept).
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): remember folder, auto-remount, handle disk unplug`.

### Task 11: Menu, settings and end-to-end check

**Files:**
- Create: `app/MLVSwitch/MenuContent.swift`, `app/MLVSwitch/SettingsView.swift`; Modify: `app/MLVSwitch/MLVSwitchApp.swift`, `README.md`

**Interfaces:**
- Consumes: `AppState`, `resolveAppURL`, `Dependencies`.

- [ ] **Step 1:** Menu (French copy, in this order): folder name (or « Aucun dossier choisi »); one row per shoot « <nom> — <n> clips · <taille> » with a green dot when mounted, click toggles; separator; « Choisir un dossier… » (`NSOpenPanel`, directories only); « Ouvrir Resolve » (disabled if not found); « Afficher les DNG dans le Finder » (opens `~/MLV Switch`); picker « Dual ISO : Montage fluide / Qualité étalonnage » — after switching to Qualité, show once « Dans Resolve, sélectionnez les plans puis clic droit → Rafraîchir. »; « Tout démonter »; « Réglages… »; « Quitter ». Menu-bar label: `film.stack` + count of mounted shoots; `exclamationmark.triangle` tint orange when `alert != nil`.
- [ ] **Step 2:** Settings: « Lancer au démarrage » (`SMAppService.mainApp`, on by default at first launch), « Avancé » disclosure with toggles « Corriger les pixels morts » and « Corriger les focus pixels » (applied on next mount), About with credits to Danne (Switch) and David Milligan (MLVFS) and the GPL notice.
- [ ] **Step 3:** Run all tests: `cd app && swift test`. Expected: all PASS.
- [ ] **Step 4: End-to-end with the user** (spec « Critères de réussite »): fresh launch → FUSE-T present → choose the project root → shoots listed → mount → import in Resolve → playback criterion; quit Resolve and app, reboot, relaunch → Resolve project finds all clips; unplug/replug an SSD holding a copy of the test shoot → remount at the same path. Record results in `docs/spikes/2026-10-e2e.md`.
- [ ] **Step 5:** README: what it does, install steps (FUSE-T handled by the app; first-open « Ouvrir quand même » note while not notarized), credits, GPL. Commit `feat(app): menu, settings and v1 end-to-end validation`.
