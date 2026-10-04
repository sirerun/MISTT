#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${MISTT_BUILD_ROOT:-/Volumes/BuildOffload/build/MISTT-desktop-20261003}
mkdir -p "$BUILD_ROOT/swiftpm"
swift test --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_ROOT/swiftpm" --parallel
