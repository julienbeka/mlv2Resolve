# mlv2Resolve

<img src="artwork/mlv2Resolve-icon.png" width="128" alt="mlv2Resolve">

*[Version française](README.fr.md)*

Edit Magic Lantern **MLV footage directly in DaVinci Resolve**, without converting or copying it first. mlv2Resolve mounts your shoots as virtual CinemaDNG sequences, prepares a Resolve project, and can synchronize SenseFlow A1 gyro data.

## Download and install

**[Download mlv2Resolve 0.2.2 for Apple Silicon](https://github.com/julienbeka/mlv2Resolve/releases/download/v0.2.2/mlv2Resolve-0.2.2-macos-arm64.zip)** · [Release notes and SHA-256](https://github.com/julienbeka/mlv2Resolve/releases/tag/v0.2.2)

- **Mac:** Apple Silicon, macOS 14 or later. The interface includes native macOS Tahoe icons and styling.
- **Resolve:** tested with DaVinci Resolve Studio 21.1.1. Studio supports direct actions from the app; the free edition uses the Workspace script described below.
- **FUSE-T:** required for virtual mounts. The app offers its installer if missing.
- **Gyroflow(NiYien) OFX:** required only for stabilization inside Resolve; install it separately.

1. Unzip the download and move `mlv2Resolve.app` to `/Applications`.
2. The app is not notarized: if macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**.
3. Open the app and complete FUSE-T installation if prompted. The main window opens at launch; the app also appears in the Dock and **Command-Tab**. Its menu-bar camera **ML** icon gives quick access to the workflow.

To verify the download, place the ZIP and its `.sha256` file in the same folder and run `shasum -a 256 -c mlv2Resolve-0.2.2-macos-arm64.zip.sha256`.

English and French are included. The interface follows macOS; choose a different language in **Settings → Language**.

## Quick start

The window has four sections:

| Section | What to do |
| --- | --- |
| **Footage** | Choose a shoot folder or a parent folder containing several shoots. Mount each folder with its switch; **Unmount All** is available here. |
| **Gyro Sync** | If using a SenseFlow A1, choose a lens and sensor position, then wait for synchronization. Desqueezed thumbnails and enlarged previews help identify each shot. |
| **Editing** | Enter a project title (default: **My Project**) and click **Create Project**. All mounted folders are combined into **one** Resolve project. |
| **Settings** | Open the left drawer to configure lenses, Dual ISO, project size, cadence and the optional All shots timeline. |

DNG sequences appear in `~/MLV Mounts/<shoot>`. Keep the folders mounted while editing. Mounts are restored when the app launches or their disk is reconnected, using the same paths so Resolve can find the footage.

## Resolve workflow

With **Resolve Studio**, enable **Preferences → System → General → External scripting using: Local**. With **Resolve Free**, choose the action in mlv2Resolve, then run **Workspace → Scripts → mlv2Resolve** inside Resolve.

| Action | Result |
| --- | --- |
| **Create Project** | Create one named project from all mounted shoots, import CinemaDNG and matching WAV audio, and synchronize audio by timecode. |
| **Open Project** | Reopen a linked project without changing its media, timelines or grades. |
| **Open Resolve** | Launch Resolve. |
| **Desqueeze in Resolve** | Desqueeze existing timeline clips while preserving custom framing and avoiding a second stretch. |

In **Settings → Resolve**:

- **Project size:** Automatic uses the majority desqueezed resolution across mounted footage; UHD or HD fits the complete image, with bars where needed.
- **Cadence:** use the majority footage frame rate or choose a manual value. Both project timeline cadence and playback cadence are prepared to match.
- **All shots:** optionally add every imported shot to a timeline. It is enabled by default; the name is editable and defaults to **All shots**. Disable it to prepare an empty timeline with its CSTs.
- **Project links:** clear the app's saved associations without deleting Resolve projects or footage.

New populated timelines receive a **Gyroflow(NiYien)** Color node on each clip when the plugin is installed. In the plugin, use **Load for current file** to load that clip's `.gyroflow` data. Missing plugin installation is reported.

### Color management

Choose **Color Management** in Resolve settings. Both modes use **DaVinci WG/Intermediate** for the timeline, **Rec.709-A** for project output, and CinemaDNG decoding **Project / P3 D60 / Linear**.

| Mode | Active timeline nodes |
| --- | --- |
| **Rec709-A Conversion** (default) | One CST: P3-D60 / Linear → DaVinci Wide Gamut / Rec.709-A |
| **Kodak 2383** | One CST: P3-D60 / Linear → Rec.709 / Cineon Film Log, followed by Resolve’s built-in **Film Looks / Rec709 Kodak 2383 D60** LUT |

The CSTs use None for Tone Mapping and Gamut Mapping, with Apply Forward OOTF disabled. All selected mode nodes are active on creation. The choice is remembered and applies only to new projects; existing projects retain their settings. The Kodak LUT is resolved from the local Resolve installation; a clear error is reported if it is unavailable.

### Anamorphic footage and Dual ISO

MLV previews are desqueezed automatically. Created timeline clips fit the whole image even when no Input Sizing preset exists, using separate horizontal/vertical zoom. Clips imported only into the Media Pool can still need an Input Sizing preset when assembling another timeline manually.

Use **Smooth Editing** Dual ISO mode while editing and **Grading Quality** before grading/export. The switch applies live; select the clips in Resolve and use **Refresh** after changing it. Both modes are explained in Settings.

### Gyro sync (SenseFlow A1)

mlv2Resolve syncs the gyro of a SenseFlow A1 with your clips by itself and writes a Gyroflow project for each clip, so
Resolve's Gyroflow plugin can stabilize the DNGs. No NiYien Tool and no reference clips are needed.

1. Copy the A1 logs (`*_mix.bin`) anywhere in the folder chosen with **Choose Folder…** (the shoot folder, a
   subfolder, or a parent folder shared by several shoots). Logs and MLV files are never modified.
2. Declare your lenses once in **Settings… → Lenses**: a name and the real focal length in mm (the one Magic
   Lantern writes in the MLV is not reliable). mlv2Resolve computes a distortion-free profile from the focal length.
3. In the mlv2Resolve window, each mounted shoot gets a default **Lens** and a **Sensor position** (where the A1 sits
   on the camera; **Top** by default, changeable in **Settings… → Gyro Sync**, which applies to clips synced
   afterwards). Each clip's menu can pick another lens or position for that clip only. Changing a shoot's lens or
   position rewrites the `.gyroflow` files mlv2Resolve wrote for its clips that have no lens or position of their own
   (the previous files are backed up); files mlv2Resolve did not write are never touched.
4. Clips are synced in the background, one at a time per shoot. Each clip shows its state: **Synced (R² 0.78)**
   (R² = how well the clip's motion matches the gyro, 1 = perfect), **No log covers this clip**, **Not enough
   camera motion**, **Uncertain match** (nothing is written rather than a doubtful sync), **Syncing…**,
   **Existing .gyroflow**.
5. The `.gyroflow` is saved next to the `.MLV` (named like NiYien's, `<clip folder>_000000.gyroflow`) and appears
   in the clip's folder of the mount. In Resolve: Gyroflow plugin → **Load for current file**.

Short lenses (e.g. 12 mm) have too much distortion for a computed profile: calibrate the lens in Gyroflow, then
import its `.json` in **Settings… → Lenses → Edit… → Import Calibrated Profile…** (mlv2Resolve keeps a copy in
`~/Library/Application Support/mlv2Resolve/lens-profiles`). A calibrated profile is used for the clips whose format
matches its dimensions; other clips keep the computed profile. The clip's state says which one was used
(« calibrated profile » / « computed profile »).

An existing `.gyroflow` that mlv2Resolve did not write (e.g. made with NiYien Tool) is kept. **Regenerate** on a
clip replaces it, as does changing that clip's lens or position; the replaced file is first copied to
`~/Library/Application Support/mlv2Resolve/gyroflow-backups/<shoot>/`.

### Rolling shutter matched to the EOS M recording mode

For supported **Canon EOS M Crop Mood Slim** modes, mlv2Resolve derives the sensor readout time from the recorded
size, frame rate and sensor sampling instead of applying one value to every clip. Both the lens profile and the
Gyroflow stabilization settings receive the same value: **32.128 ms for 4.8K 4800 × 2008**, for example, and
**35.3925 ms for 5.2K 5208 × 2178**.

The lookup covers 1×1, 1×3, 3×3 and full-resolution LV modes. It also follows sampling corrections when an MLV
header disagrees with the majority of clips of the same size. The values come from the firmware source; the
4.8K setting has been visually tested, while other modes still need visual validation. See the
[mode table and calculation details](docs/research/eosm-slim-rolling-shutter.md).

For an unknown format, a valid readout time from an imported lens profile is kept; otherwise rolling shutter
correction is disabled. Existing projects are preserved: choose **Regenerate** on a clip to apply the new values
(with a backup), then **Load for current file** in Resolve's Gyroflow plugin. New populated timelines already have Gyroflow(NiYien) on each clip’s Color node when the plugin is installed. For existing projects, add it manually if needed.

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

Requirements: full Xcode 26 or later (including its command-line tools), [XcodeGen](https://github.com/yonaskolb/XcodeGen) and FUSE-T (`brew install macos-fuse-t/homebrew-cask/fuse-t`).

    scripts/build-app.sh       # builds build/mlv2Resolve.app (engine + app, ad-hoc signed)
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
