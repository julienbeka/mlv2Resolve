# MLV Switch

A macOS menu-bar app that mounts Magic Lantern MLV video files as virtual CinemaDNG sequences, for editing in DaVinci Resolve. It runs the MLVFS engine on FUSE-T (kext-less FUSE) on Apple Silicon.

## Build the engine

Requires Xcode command line tools and FUSE-T (`brew install macos-fuse-t/homebrew-cask/fuse-t`).

    scripts/build-engine.sh

This writes `build/engine/mlvfs` (arm64, ad-hoc signed).

## Credits

- Danne (Switch) for the original MLV workflow.
- David Milligan for [MLVFS](https://github.com/davidmilligan/MLVFS) (vendored in `engine/mlvfs/`, GPL-2.0-or-later).

## License

GPL-3.0-or-later. See `LICENSE`.
