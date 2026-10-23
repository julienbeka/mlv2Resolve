#!/bin/bash
# Builds the vendored MLVFS engine for arm64 -> build/engine/mlvfs (ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/engine"
make -f Makefile.arm64 -j"$(sysctl -n hw.ncpu)"
mkdir -p "$ROOT/build/engine"
cp mlvfs-bin "$ROOT/build/engine/mlvfs"
codesign -s - --force "$ROOT/build/engine/mlvfs"
echo "Built $ROOT/build/engine/mlvfs"
