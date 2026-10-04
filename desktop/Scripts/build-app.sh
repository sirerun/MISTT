#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_ROOT=${MISTT_BUILD_ROOT:-/Volumes/BuildOffload/build/MISTT-desktop-20261003}
ARTIFACT_ROOT=${MISTT_ARTIFACT_ROOT:-/Volumes/BuildOffload/artifacts/MISTT-desktop-20261003}
RELAY=${MISTT_RELAY_BINARY:-}
if [ -z "$RELAY" ] || [ ! -x "$RELAY" ]; then
  echo "Set MISTT_RELAY_BINARY to the integrated arm64 Go relay; test fixtures are never bundled." >&2
  exit 2
fi
if ! /usr/bin/lipo -verify_arch arm64 "$RELAY" >/dev/null 2>&1; then
  echo "MISTT_RELAY_BINARY must contain an arm64 slice." >&2
  exit 2
fi
mkdir -p "$BUILD_ROOT/swiftpm" "$BUILD_ROOT/metadata" "$ARTIFACT_ROOT"
swift build --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_ROOT/swiftpm" --configuration release --arch arm64 --product MISTTDesktop
swift build --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_ROOT/swiftpm" --configuration release --arch arm64 --show-bin-path > "$BUILD_ROOT/metadata/bin-path.txt"
BIN_PATH=$(cat "$BUILD_ROOT/metadata/bin-path.txt")
APP="$ARTIFACT_ROOT/MISTT.app"
if [ -e "$APP" ]; then
  echo "Refusing to replace an existing bundle: $APP. Choose a fresh MISTT_ARTIFACT_ROOT." >&2
  exit 2
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/MISTTDesktop" "$APP/Contents/MacOS/MISTTDesktop"
cp "$RELAY" "$APP/Contents/MacOS/mistt"
cp "$PACKAGE_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PACKAGE_DIR/Resources/logo-3.svg" "$APP/Contents/Resources/logo-3.svg"
cp "$PACKAGE_DIR/Resources/logo-3-muted.svg" "$APP/Contents/Resources/logo-3-muted.svg"
chmod 755 "$APP/Contents/MacOS/MISTTDesktop" "$APP/Contents/MacOS/mistt"
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$PACKAGE_DIR/Resources/MISTT.entitlements" "$APP/Contents/MacOS/mistt"
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$PACKAGE_DIR/Resources/MISTT.entitlements" "$APP/Contents/MacOS/MISTTDesktop"
codesign --force --sign - --timestamp=none --options runtime --deep \
  --entitlements "$PACKAGE_DIR/Resources/MISTT.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built local ad-hoc app: %s\n' "$APP"
