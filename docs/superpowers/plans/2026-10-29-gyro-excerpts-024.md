# Gyro excerpts 0.2.4 Implementation Plan

> **For agentic workers:** Use tests before changes and execute inline; final review covers the complete change.

**Goal:** Ship mlv2Resolve 0.2.4 with automatic, lossless per-clip SenseFlow telemetry excerpts.

**Architecture:** A Swift core helper prepares clip-sized logs with ten-second handles, preserves raw records and shifts synchronization timestamps consistently. New sync writes excerpts; mount-time migration only updates sidecars owned by this app, backing them up first and preserving all other project fields. Files live in the source shoot's hidden `.mlv2resolve-gyro` directory, with content-based names so older project backups remain valid.

**Tech Stack:** Swift 6, Foundation, CryptoKit, XCTest; existing macOS application build scripts.

**Spec:** docs/implementation/2026-10-29-playback-performance.md, plus the user's request for version 0.2.4.

## Global Constraints

- Never modify original MLV or session gyro log files.
- Preserve sampling rate, binary motion samples and constant sync mapping; ten-second handles on both sides.
- Only migrate sidecars recorded in gyroWritten; foreign files stay untouched.
- Reject unsupported/corrupt logs or variable offsets; report the failure without replacing the project.
- Repeated mounts must not rewrite optimized projects; excerpt names remain immutable across regeneration.
- Keep this existing workspace and its uncommitted diagnostic/leak-fix work; no unrelated reset or publication.

## Review Focus

- Correct handling of standard three-slash and NiYien four-slash file URLs.
- Markers, checksum failures, clipping at log boundaries, fractional offsets and header date rollover.
- Cancellation and write failure must not leave a partial sidecar; backup before replacing existing data.
- Preserve lens/stabilization fields and original full-log sync metadata used to estimate camera skew.
- No duplicate full-log excerpts enter log discovery; no Python runtime dependency in the app.

## Tasks

- [x] Add excerpt unit tests and new/migration coordinator regression tests; establish failures.
- [x] Implement GyroLogExcerpt and integrate new sync and owned-sidecar migration, with backups/cancellation.
- [x] Run focused and full Swift tests, standalone utility tests, and a read-only real-data equivalence check.
- [x] Update version, release notes and user documentation; build 0.2.4 and verify bundle/signature.
- [x] Review final changes and package the local app with a SHA-256 checksum; no GitHub publication requested.

## Execution ledger

- Design follows the data-only optimization validated at 25 fps in Resolve. Existing workspace retained because it holds the authorized investigation and already tested leak fix.

- Added the Swift excerpt helper, migration with cancellation propagation, immutable log names, and shared project backup logic.
- Regression tests first reproduced old full-log generation and absence of migration; both now pass. Reviewed calendar handling and changed excerpt headers to explicit Gregorian to match the reader.
- Final full suite: 279 tests, 9 skipped, zero failures with the real-data equivalence check enabled. Standalone Python utility: 7 tests pass.
- Real 250 MB SenseFlow log: Swift excerpt bytes and sync offsets match the prior Python output validated in Resolve. Original files only read by this check.
- Built 0.2.4 (106), arm64. Deep/strict signature verification passes. Local ZIP and SHA-256 verified; archive integrity passes. No installation replacement, commit, or GitHub publication performed.
