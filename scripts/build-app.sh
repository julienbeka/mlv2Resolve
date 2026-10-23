#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds "build/mlv2dng.app" (engine + Xcode project + ad-hoc signature).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-engine.sh"

# Local builds default to the latest release tag and the commit count, so they
# never show a stale version; CI overrides both from the tag and run number.
MARKETING_VERSION="${MARKETING_VERSION:-$({ git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true; } | sed 's/^v//')}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
MARKETING_VERSION="${MARKETING_VERSION:-0.0.0}" # shallow clone without tags

cd "$ROOT/app"
xcodegen generate --quiet
xcodebuild -project "mlv2dng.xcodeproj" -scheme "mlv2dng" -configuration Release \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}" CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  build > "$ROOT/build/xcodebuild.log" 2>&1 || { grep -E "error:" "$ROOT/build/xcodebuild.log" | head -30; tail -n 30 "$ROOT/build/xcodebuild.log"; exit 1; }
tail -n 3 "$ROOT/build/xcodebuild.log"

APP="$ROOT/build/DerivedData/Build/Products/Release/mlv2dng.app"
# Copy next to the target, sign, then swap in one move: Finder never sees a
# half-copied bundle (which leaves it showing a generic icon).
rm -rf "$ROOT/build/.mlv2dng.app.new"
cp -R "$APP" "$ROOT/build/.mlv2dng.app.new"
codesign --force --deep -s - "$ROOT/build/.mlv2dng.app.new"
rm -rf "$ROOT/build/mlv2dng.app"
mv "$ROOT/build/.mlv2dng.app.new" "$ROOT/build/mlv2dng.app"
touch "$ROOT/build/mlv2dng.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$ROOT/build/mlv2dng.app" >/dev/null 2>&1 || true
echo "Built: $ROOT/build/mlv2dng.app"
