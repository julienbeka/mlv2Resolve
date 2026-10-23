#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds "build/mlv2dng.app" (engine + Xcode project + ad-hoc signature).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-engine.sh"

# Each local build replaces the same app and increments its patch/build versions.
# Explicit CI release versions and build numbers still take precedence.
PREVIOUS_INFO="$ROOT/build/mlv2dng.app/Contents/Info.plist"
if [[ -z "${MARKETING_VERSION:-}" ]]; then
  PREVIOUS_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PREVIOUS_INFO" 2>/dev/null || true)"
  # Consider every release tag, including tags outside the current branch.
  # Advance past both the last local build and the highest known release.
  LATEST_TAG_VERSION="$(git tag --list 'v[0-9]*' | sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | sort -t . -k1,1n -k2,2n -k3,3n | tail -n 1)"
  PREVIOUS_VERSION="$(printf '%s\n' "$PREVIOUS_VERSION" "$LATEST_TAG_VERSION" | sed -nE '/^[0-9]+\.[0-9]+\.[0-9]+$/p' | sort -t . -k1,1n -k2,2n -k3,3n | tail -n 1)"
  if [[ "$PREVIOUS_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    MARKETING_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((10#${BASH_REMATCH[3]} + 1))"
  else
    MARKETING_VERSION="0.1.0"
  fi
fi
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  PREVIOUS_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PREVIOUS_INFO" 2>/dev/null || true)"
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
  if [[ "$PREVIOUS_BUILD" =~ ^[0-9]+$ ]] && (( 10#$PREVIOUS_BUILD >= BUILD_NUMBER )); then
    BUILD_NUMBER="$((10#$PREVIOUS_BUILD + 1))"
  fi
fi

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
echo "Built: $ROOT/build/mlv2dng.app — $MARKETING_VERSION ($BUILD_NUMBER)"
