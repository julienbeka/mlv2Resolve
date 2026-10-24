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
2. Click a shoot to mount it. The DNGs appear in `~/MLV Mounts/<shoot>` (**Show DNGs in Finder**). Import them into Resolve from there.
3. Mounted shoots are remounted automatically at launch and when their disk is plugged back in, always at the same path, so Resolve finds its clips again.
4. **Dual ISO**: use **Smooth Editing** while editing and **Grading Quality** before grading. The switch is applied live; in Resolve, select the clips and right-click → Refresh.
5. 1x3 anamorphic footage: Resolve ignores the pixel aspect ratio stored in the DNGs and its Clip Attributes offer no 3:1 option, so desqueeze on the Color page → Sizing → Input Sizing → **Width = 3** (Height stays 1). The app reminds you when you mount such a shoot.

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
