#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${MISTT_PREFLIGHT_BUILD_ROOT:-/Volumes/BuildOffload/build/mistt-native-preflight}"
ARTIFACT_ROOT="${MISTT_PREFLIGHT_ARTIFACT_ROOT:-/Volumes/BuildOffload/artifacts/mistt-native-preflight}"
APP="${ARTIFACT_ROOT}/MISTT-Capture-Preflight.app"
SIGN_IDENTITY="${MISTT_DEV_SIGN_IDENTITY:--}"

if [[ -e "$APP" ]]; then
    printf 'Refusing to overwrite existing artifact: %s\n' "$APP" >&2
    exit 2
fi
mkdir -p "$BUILD_ROOT" "$(dirname "$APP")"
BIN_ROOT="$(swift build --show-bin-path --package-path "$ROOT" --scratch-path "$BUILD_ROOT" --configuration debug --arch arm64 --jobs 2)"
swift build --package-path "$ROOT" --scratch-path "$BUILD_ROOT" --configuration debug --arch arm64 --jobs 2 --product NativeCapturePreflight
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_ROOT/NativeCapturePreflight" "$APP/Contents/MacOS/NativeCapturePreflight"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp=none --entitlements "$ROOT/Resources/MISTT.entitlements" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
printf 'Built signed preflight app: %s\n' "$APP"
