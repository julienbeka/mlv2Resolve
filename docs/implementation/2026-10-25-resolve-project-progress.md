# Resolve project implementation
Spec: docs/specs/2026-10-25-resolve-project-design.md

Execution authorized by the user's request to implement the supplied design. Working in the existing clean feature checkout (feat/gyro-sync).

1. Core manifest: mounted DNG sequences, corrected squeeze, majority frame rate and native resolution (ties: largest). Test filesystem discovery and format selection.
2. Shared Lua worker: project creation/preset/settings, recursive deduplication, paired audio sync, new-clip sizing, UHD Rushs timeline. Test against a controlled Resolve API fixture through fuscript.
3. App integration: asynchronous launch/connect/retry, project-switch consent, free guide and preset guide, menu-script refresh, gyro activity in menu/window.
4. Full Swift test suite and application build; whole-change review.

Ruling: UHD uses the specified Rushs timeline fallback; Input Sizing presets cannot encode a general per-clip zoom for mixed formats.
Ruling: script requests approval for each project switch, including successive shoots. Existing projects receive only missing media (no timeline or settings edits).
Baseline: swift test — 218 tests, 8 skipped, 0 failures.

Task 1 complete: filesystem sequence bounds, header-only format reading, correction map, modal resolution/cadence. User adjustment: 5 clips 4.8K + 2 clips 5.2K => 4800x2008; tie => largest.
Task 2 complete: shared Lua worker and menu script; fresh project settings, recursive deduplication, paired audio sync, UHD Rushs framing; existing project untouched apart from new media.
Task 3 complete: menu/window actions, wait/continue gyro alert, save-and-switch confirmation, 60-second connection probe, guide, first-use/preset notices, live gyro progress.
Review findings fixed: empty shoots no longer disappear; Desqueeze is disabled/guarded while waiting for gyro; different-aspect Studio clips receive Fit preset variants.
Ruling: per-format Fit variants extend standard presets for anamorphic outliers only. Applying pure squeeze after RAW scale-to-fit would crop; Width=factor*zoom, Height=zoom keeps the entire frame. Existing user presets are preserved. Presets still use the existing local-library backup/schema/running-app safeguards and manual fallback.
Verification pending: final full test suite, Release build, manual real-media checks documented separately.
Final review correction: newly added clips use GetSetting dimensions from the existing project; Fit variants are prepared for every native source resolution, since any one could have been the original majority. Custom dimensions absent from the preset library are reported with manual Width/Height values.
Final verification: swift test — 238 tests, 8 skipped, 0 failures. Release app built successfully: build/mlv2Resolve.app, version 0.1.15 (87). Debug build also passed. git diff --check clean. Real visual Studio/free-version acceptance remains manual, with steps in 2026-10-25-resolve-project-validation.md.

Launch regression fixed (0.1.16 / 88): user could not open the app. Live sample of 0.1.15 showed the main thread repeatedly inside MenuBarExtraHost.requestUpdate / NSStatusBarButton.setImage, ~90% CPU and 29.1 GB physical footprint. Replaced TimelineView in the status label with discrete quarter-turn state updates every 500 ms from a cancellable task. Rebuilt and verified the actual window through accessibility: mounted 20261025 and all action buttons visible. Corrected process measured 0% CPU and ~100 MB RSS after 28 seconds. codesign --verify --deep --strict and git diff --check passed. App left open for the user.
