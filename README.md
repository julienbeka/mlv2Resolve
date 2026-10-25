# mlv2dng

*[Version française](README.fr.md)*

Edit Magic Lantern MLV footage directly in DaVinci Resolve: mlv2dng mounts your clips as CinemaDNG sequences on the fly — no conversion, no terminal.

mlv2dng is a macOS menu-bar app that mounts Magic Lantern (MLV) shoots as virtual CinemaDNG sequences so you can edit them in DaVinci Resolve without converting or copying anything. It drives the MLVFS engine on FUSE-T (FUSE without a kernel extension), on Apple Silicon.

The interface follows the macOS language (English by default, French available). You can also pick the language in **Settings… → Language**.

## Download

Download the latest `mlv2dng-<version>-macos-arm64.zip` from the [Releases](https://github.com/julienbeka/mlv2dng/releases) page (Apple Silicon Mac, macOS 14 or later). Check it against the attached `.sha256` file: `shasum -a 256 -c <file>.sha256`.

1. Unzip it and move `mlv2dng.app` to `/Applications`.
2. The app is not notarized yet: on first launch, macOS blocks it. Open System Settings > Privacy & Security and click **Open Anyway**.
3. If FUSE-T is missing, the app offers to download and install it on first launch (your administrator password is asked once), then carries on by itself.

To build from source, see [Building](#building).

## Usage

1. Click the menu-bar icon (or double-click the app to open the mlv2dng window if the icon is hidden behind the notch), then **Choose Folder…**. The folder can be a single shoot or a parent folder containing several shoots.
2. Click a shoot to mount it. The DNGs appear in `~/MLV Mounts/<shoot>` (**Show DNGs in Finder**). Use **Open Resolve** to prepare the project and import the clips, or import them manually from that folder.
3. Mounted shoots are remounted automatically at launch and when their disk is plugged back in, always at the same path, so Resolve finds its clips again.
4. **Dual ISO**: use **Smooth Editing** while editing and **Grading Quality** before grading. The switch is applied live; in Resolve, select the clips and right-click → Refresh.
5. Anamorphic footage: **Open Resolve** applies the matching Input Sizing presets when available. **Desqueeze in Resolve** can also apply them to clips already imported. If a preset cannot be installed, the app explains how to save it manually (for 1x3: Color → Sizing → Input Sizing → **Width = 3**, **Height = 1**, with fit adjustments when needed).

### Prepare a Resolve project with one click

**Open Resolve** creates or opens a project named after each mounted shoot and imports its CinemaDNG sequences
with their matching WAV audio, synchronized by timecode. Sidecar files and GIF previews are excluded.

- New projects use your saved **mlv2dng** project preset. The most common desqueezed resolution and frame rate
  determine the project format; tied resolution counts use the larger image. Five 4800 × 2008 clips and two
  5208 × 2178 clips therefore select **4800 × 2008**.
- Opening the project again imports only missing clips and preserves its existing settings and timelines.
- In **Resolve Studio**, preparation runs directly from the app. In the **free edition**, use
  **Workspace → Scripts → mlv2dng** inside Resolve; a new project gets a UHD **Rushs** timeline with fitted clips.
- If gyro synchronization is still running, choose **Wait** or **Open Anyway**. Progress appears in the window
  and menu bar.
- An empty, unsaved **Untitled Project** at startup is skipped without requiring a save. Switching away from
  another project still asks for confirmation and saves it first.

Anamorphic sizing presets are installed with a backup in the supported default local project library while
Resolve is closed. Existing custom sizing choices are preserved; other libraries receive manual instructions.

### Gyro sync (SenseFlow A1)

mlv2dng syncs the gyro of a SenseFlow A1 with your clips by itself and writes a Gyroflow project for each clip, so
Resolve's Gyroflow plugin can stabilize the DNGs. No NiYien Tool and no reference clips are needed.

1. Copy the A1 logs (`*_mix.bin`) anywhere in the folder chosen with **Choose Folder…** (the shoot folder, a
   subfolder, or a parent folder shared by several shoots). Logs and MLV files are never modified.
2. Declare your lenses once in **Settings… → Lenses**: a name and the real focal length in mm (the one Magic
   Lantern writes in the MLV is not reliable). mlv2dng computes a distortion-free profile from the focal length.
3. In the mlv2dng window, each mounted shoot gets a default **Lens** and a **Sensor position** (where the A1 sits
   on the camera; **Top** by default, changeable in **Settings… → Gyro Sync**, which applies to clips synced
   afterwards). Each clip's menu can pick another lens or position for that clip only. Changing a shoot's lens or
   position rewrites the `.gyroflow` files mlv2dng wrote for its clips that have no lens or position of their own
   (the previous files are backed up); files mlv2dng did not write are never touched.
4. Clips are synced in the background, one at a time per shoot. Each clip shows its state: **Synced (R² 0.78)**
   (R² = how well the clip's motion matches the gyro, 1 = perfect), **No log covers this clip**, **Not enough
   camera motion**, **Uncertain match** (nothing is written rather than a doubtful sync), **Syncing…**,
   **Existing .gyroflow**.
5. The `.gyroflow` is saved next to the `.MLV` (named like NiYien's, `<clip folder>_000000.gyroflow`) and appears
   in the clip's folder of the mount. In Resolve: Gyroflow plugin → **Load for current file**.

Short lenses (e.g. 12 mm) have too much distortion for a computed profile: calibrate the lens in Gyroflow, then
import its `.json` in **Settings… → Lenses → Edit… → Import Calibrated Profile…** (mlv2dng keeps a copy in
`~/Library/Application Support/mlv2dng/lens-profiles`). A calibrated profile is used for the clips whose format
matches its dimensions; other clips keep the computed profile. The clip's state says which one was used
(« calibrated profile » / « computed profile »).

An existing `.gyroflow` that mlv2dng did not write (e.g. made with NiYien Tool) is kept. **Regenerate** on a
clip replaces it, as does changing that clip's lens or position; the replaced file is first copied to
`~/Library/Application Support/mlv2dng/gyroflow-backups/<shoot>/`.

### Rolling shutter matched to the EOS M recording mode

For supported **Canon EOS M Crop Mood Slim** modes, mlv2dng derives the sensor readout time from the recorded
size, frame rate and sensor sampling instead of applying one value to every clip. Both the lens profile and the
Gyroflow stabilization settings receive the same value: **32.128 ms for 4.8K 4800 × 2008**, for example, and
**35.3925 ms for 5.2K 5208 × 2178**.

The lookup covers 1×1, 1×3, 3×3 and full-resolution LV modes. It also follows sampling corrections when an MLV
header disagrees with the majority of clips of the same size. The values come from the firmware source; the
4.8K setting has been visually tested, while other modes still need visual validation. See the
[mode table and calculation details](docs/research/eosm-slim-rolling-shutter.md).

For an unknown format, a valid readout time from an imported lens profile is kept; otherwise rolling shutter
correction is disabled. Existing projects are preserved: choose **Regenerate** on a clip to apply the new values
(with a backup), then **Load for current file** in Resolve's Gyroflow plugin. Add the plugin to a Color node
manually; mlv2dng prepares its project file.

### Files saved into a clip folder (sidecars)

Some tools cannot choose their output folder and save next to the footage they read, e.g. NiYien Tool writes its
`.gyroflow` into the clip folder. Such files are saved in the shoot's original folder, next to the `.MLV`, and
appear automatically in that clip's folder of the mount:

- A clip folder shows, besides its DNGs and WAV, every file of the original folder whose name starts with the clip
  name followed by a non-alphanumeric character or by `MLV` (`M24-1546.gyroflow`, `M24-1546MLV_1_….gyroflow`;
  case-insensitive; `M24-1546B.json` belongs to clip `M24-1546B`, not `M24-1546`).
- A file with another name saved through a clip folder (e.g. `2026-10-24_15-47-01_mix.gyroflow`) is also stored
  next to the `.MLV`; the small hidden file `.mlv2dng-sidecars.json` in the original folder remembers which clip
  folder shows it (deleted when it becomes empty).
- The mount root mirrors the original folder: files saved there land in it, and its other files are listed there.

What can be written through a mount:

- **New files** of any name except the protected ones below.
- **Existing files**, which may be overwritten, truncated, renamed or deleted, only if they were created through the
  mount or have one of these extensions: `gyroflow`, `gcsv`, `json`, `csv`, `txt`, `xml`, `log`, `cube`, `srt`
  (any case). Every other existing file of the shoot folder (`.wav`, `.mov`, `.mp4`, `.dng`, `.cr2`, `.bin`…) is
  read-only through the mount.

What can never be written, renamed or deleted: the `.MLV` files and their chunks (`.M00`–`.M99`), `.IDX`, `.MLD`
(any case), the virtual DNG/WAV files, the clip folders, folders in general (no folder can be created or removed),
`.mlv2dng-sidecars.json`, `.DS_Store`, symbolic links and files with several hard links. Nothing is ever read or
written outside the shoot folder, even through a symbolic link. Your original MLV files are never modified. Since
every name maps to one file in the original folder, two clip folders cannot use the same file name: the file belongs
to the clip folder that created it.

## Building

Requirements: Xcode (command-line tools), [XcodeGen](https://github.com/yonaskolb/XcodeGen) and FUSE-T (`brew install macos-fuse-t/homebrew-cask/fuse-t`).

    scripts/build-app.sh       # builds build/mlv2dng.app (engine + app, ad-hoc signed)
    cd app && swift test       # core tests

Engine only: `scripts/build-engine.sh` (writes `build/engine/mlvfs`).

Every push to `main` is built and tested by GitHub Actions; every `v*` tag publishes a release with the zipped app.

## Credits

- Inspired by Switch by Danne.
- MLVFS by David Milligan ([repository](https://github.com/davidmilligan/MLVFS), vendored in `engine/mlvfs/`).
- Focus-pixel maps and LJ92 decoder from MLV App (ilia3101 and contributors).

## License

The code specific to this repository (app, scripts, tests, engine additions) is licensed under GPL-3.0-or-later. See `LICENSE`.

The engine (`engine/mlvfs/`) contains third-party code, all compatible with GPL-3.0:

- MLVFS (David Milligan) and the Magic Lantern code it reuses (dual ISO, chroma smoothing, pattern noise…): GPL-2.0-or-later, used here under GPL-3.0-or-later.
- Code ported from MLV App (focus-pixel maps, LJ92 decoder) and AMaZE (RawTherapee): GPL-3.0.
- LZMA SDK (Igor Pavlov): public domain. DNG tag headers: Adobe DNG SDK license (permissive).

No GPL-2.0-only component remains: the `mongoose/` web server (settings UI) and `slre/` (regular expressions), shipped with MLVFS under GPL-2.0-only, have been removed. The dual ISO mode is now switched by signal (SIGUSR1 = smooth editing, SIGUSR2 = grading quality) and Resolve folder-name matching uses POSIX `<regex.h>`. The `mlvfs` binary, and therefore the app, can be distributed under **GPL-3.0**.
