#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
VOLUME=/Volumes/BuildOffload
BUILD_ROOT=${MISTT_BUILD_ROOT:-$VOLUME/build/MISTT-code-native-20261004}
ARTIFACT_ROOT=${MISTT_ARTIFACT_ROOT:-$VOLUME/artifacts/MISTT-code-native-20261004}
RELAY=${MISTT_RELAY_BINARY:-}
CLAIM_REMOTE=/Users/Shared/mini-build-lease.git
CLAIM_SCRIPT=/Users/dndungu/.agents/skills/claim/scripts/claim.sh
LEASE_HELD=0
release_lease() {
  if [ "$LEASE_HELD" -eq 1 ]; then
    CLAIM_REMOTE="$CLAIM_REMOTE" "$CLAIM_SCRIPT" release R-build-lease >/dev/null
    LEASE_HELD=0
  fi
}
trap release_lease EXIT HUP INT TERM
for path in "$BUILD_ROOT" "$ARTIFACT_ROOT"; do
  case "$path" in "$VOLUME"/*) ;; *) echo "Build caches and artifacts must stay on $VOLUME." >&2; exit 2 ;; esac
done
[ -d "$VOLUME" ] && [ -w "$VOLUME" ] || { echo "$VOLUME is not mounted and writable." >&2; exit 2; }
AVAILABLE_KB=$(df -Pk "$VOLUME" | awk 'NR==2 {print $4}')
[ "${AVAILABLE_KB:-0}" -ge 5242880 ] || { echo "At least 5 GiB free on $VOLUME is required." >&2; exit 2; }
LOAD_ONE=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')
awk -v load="$LOAD_ONE" 'BEGIN { exit !(load <= 10) }' || { echo "Host one-minute load exceeds 10; defer app build." >&2; exit 2; }
if [ -z "$RELAY" ] || [ ! -x "$RELAY" ]; then
  echo "Set MISTT_RELAY_BINARY to the integrated arm64 Go relay; test fixtures are never bundled." >&2
  exit 2
fi
/usr/bin/lipo -verify_arch arm64 "$RELAY" >/dev/null 2>&1 || {
  echo "MISTT_RELAY_BINARY must contain an arm64 slice." >&2; exit 2;
}
mkdir -p "$BUILD_ROOT/swiftpm" "$BUILD_ROOT/metadata" "$ARTIFACT_ROOT"
APP="$ARTIFACT_ROOT/MISTT.app"
[ ! -e "$APP" ] || { echo "Refusing to replace existing bundle: $APP. Choose a fresh MISTT_ARTIFACT_ROOT." >&2; exit 2; }
CLAIM_REMOTE="$CLAIM_REMOTE" "$CLAIM_SCRIPT" claim R-build-lease --purpose "swift build MISTT desktop arm64 release" >/dev/null
LEASE_HELD=1
swift build --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_ROOT/swiftpm" --configuration release --arch arm64 --product MISTTDesktop
swift build --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_ROOT/swiftpm" --configuration release --arch arm64 --show-bin-path > "$BUILD_ROOT/metadata/bin-path.txt"
release_lease
BIN_PATH=$(cat "$BUILD_ROOT/metadata/bin-path.txt")
SPARKLE_FRAMEWORK=$(find "$BUILD_ROOT/swiftpm" -type d -name Sparkle.framework -print -quit)
[ -n "$SPARKLE_FRAMEWORK" ] && [ -d "$SPARKLE_FRAMEWORK" ] || {
  echo "Pinned Sparkle.framework was not produced by SwiftPM." >&2; exit 2;
}
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH/MISTTDesktop" "$APP/Contents/MacOS/MISTTDesktop"
cp "$RELAY" "$APP/Contents/MacOS/mistt"
cp "$PACKAGE_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PACKAGE_DIR/Resources/logo-3.svg" "$APP/Contents/Resources/logo-3.svg"
cp "$PACKAGE_DIR/Resources/logo-3-muted.svg" "$APP/Contents/Resources/logo-3-muted.svg"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/MISTTDesktop" | grep -Fq '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/MISTTDesktop"
fi
chmod 755 "$APP/Contents/MacOS/MISTTDesktop" "$APP/Contents/MacOS/mistt"
# Keep the vendor Sparkle framework's verified upstream signature intact. Sign
# app-owned executables and the outer local app bundle explicitly, without a
# recursive resign that would overwrite nested signature identities.
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$PACKAGE_DIR/Resources/MISTT.entitlements" "$APP/Contents/MacOS/mistt"
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$PACKAGE_DIR/Resources/MISTT.entitlements" "$APP/Contents/MacOS/MISTTDesktop"
codesign --force --sign - --timestamp=none --options runtime "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built local ad-hoc app (not a signed release): %s\n' "$APP"
