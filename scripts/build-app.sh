#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds "build/MLV Switch.app" (engine + Xcode project + ad-hoc signature).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-engine.sh"

cd "$ROOT/app"
xcodegen generate --quiet
xcodebuild -project "MLV Switch.xcodeproj" -scheme "MLV Switch" -configuration Release \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build | tail -n 5

APP="$ROOT/build/DerivedData/Build/Products/Release/MLV Switch.app"
rm -rf "$ROOT/build/MLV Switch.app"
cp -R "$APP" "$ROOT/build/MLV Switch.app"
codesign --force --deep -s - "$ROOT/build/MLV Switch.app"
echo "Built: $ROOT/build/MLV Switch.app"
