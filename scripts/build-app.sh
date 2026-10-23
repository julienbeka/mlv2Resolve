#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds "build/mlv2dng.app" (engine + Xcode project + ad-hoc signature).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-engine.sh"

cd "$ROOT/app"
xcodegen generate --quiet
xcodebuild -project "mlv2dng.xcodeproj" -scheme "mlv2dng" -configuration Release \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}" CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  build | tail -n 5

APP="$ROOT/build/DerivedData/Build/Products/Release/mlv2dng.app"
rm -rf "$ROOT/build/mlv2dng.app"
cp -R "$APP" "$ROOT/build/mlv2dng.app"
codesign --force --deep -s - "$ROOT/build/mlv2dng.app"
echo "Built: $ROOT/build/mlv2dng.app"
