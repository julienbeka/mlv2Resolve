#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds "build/mlv2Resolve.app" (engine + Xcode project + ad-hoc signature).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-engine.sh"

# Local builds target the next release. CI may supply an explicit release version.
MARKETING_VERSION="${MARKETING_VERSION:-0.2.1}"
PREVIOUS_INFO="$ROOT/build/mlv2Resolve.app/Contents/Info.plist"
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  PREVIOUS_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PREVIOUS_INFO" 2>/dev/null || true)"
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
  if [[ "$PREVIOUS_BUILD" =~ ^[0-9]+$ ]] && (( 10#$PREVIOUS_BUILD >= BUILD_NUMBER )); then
    BUILD_NUMBER="$((10#$PREVIOUS_BUILD + 1))"
  fi
fi

cd "$ROOT/app"
xcodegen generate --quiet
xcodebuild -project "mlv2Resolve.xcodeproj" -scheme "mlv2Resolve" -configuration Release \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  build > "$ROOT/build/xcodebuild.log" 2>&1 || { grep -E "error:" "$ROOT/build/xcodebuild.log" | head -30; tail -n 30 "$ROOT/build/xcodebuild.log"; exit 1; }
tail -n 3 "$ROOT/build/xcodebuild.log"

APP="$ROOT/build/DerivedData/Build/Products/Release/mlv2Resolve.app"
# Copy next to the target, sign, then swap in one move: Finder never sees a
# half-copied bundle (which leaves it showing a generic icon).
rm -rf "$ROOT/build/.mlv2Resolve.app.new"
cp -R "$APP" "$ROOT/build/.mlv2Resolve.app.new"
codesign --force --deep -s - "$ROOT/build/.mlv2Resolve.app.new"
rm -rf "$ROOT/build/mlv2Resolve.app"
mv "$ROOT/build/.mlv2Resolve.app.new" "$ROOT/build/mlv2Resolve.app"
touch "$ROOT/build/mlv2Resolve.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$ROOT/build/mlv2Resolve.app" >/dev/null 2>&1 || true
echo "Built: $ROOT/build/mlv2Resolve.app — $MARKETING_VERSION ($BUILD_NUMBER)"
