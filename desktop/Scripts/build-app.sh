#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
VOLUME=/Volumes/BuildOffload
BUILD_ROOT=${MISTT_BUILD_ROOT:-$VOLUME/build/MISTT-code-native-20261004}
ARTIFACT_ROOT=${MISTT_ARTIFACT_ROOT:-$VOLUME/artifacts/MISTT-code-native-20261004}
RELAY=${MISTT_RELAY_BINARY:-}
INFO_PLIST=${MISTT_INFO_PLIST:-$PACKAGE_DIR/Resources/Info.plist}
SIGN_IDENTITY=${MISTT_SIGNING_IDENTITY:--}
SIGN_KEYCHAIN=${MISTT_SIGNING_KEYCHAIN:-}
: "${MISTT_CLAIM_SCRIPT:?Set the installed shared build claim script path}"
: "${CLAIM_REMOTE:?Set the shared Mac build lease repository}"
export CLAIM_REMOTE
LEASE_HELD=0
LEASE_SHA=
release_lease() {
  if [ "$LEASE_HELD" -eq 1 ]; then
    "$MISTT_CLAIM_SCRIPT" release R-build-lease "$LEASE_SHA" >/dev/null
    LEASE_HELD=0
  fi
}
trap release_lease EXIT HUP INT TERM
if [ "$SIGN_IDENTITY" = "-" ] && [ -n "$SIGN_KEYCHAIN" ]; then
  echo "MISTT_SIGNING_KEYCHAIN requires a Developer ID MISTT_SIGNING_IDENTITY." >&2
  exit 2
fi
if [ "$SIGN_IDENTITY" != "-" ] && [ -z "$SIGN_KEYCHAIN" ]; then
  echo "Developer ID signing requires an explicit MISTT_SIGNING_KEYCHAIN." >&2
  exit 2
fi
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none --options runtime)
if [ -n "$SIGN_KEYCHAIN" ]; then
  SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
fi
for path in "$BUILD_ROOT" "$ARTIFACT_ROOT"; do
  case "$path" in "$VOLUME"/*) ;; *) echo "Build caches and artifacts must stay on $VOLUME." >&2; exit 2 ;; esac
done
MOUNTED_AT=$(df -P "$VOLUME" | awk 'NR == 2 {print $NF}')
[ "$MOUNTED_AT" = "$VOLUME" ] && [ -w "$VOLUME" ] || { echo "$VOLUME is not mounted and writable." >&2; exit 2; }
AVAILABLE_KB=$(df -Pk "$VOLUME" | awk 'NR==2 {print $4}')
[ "${AVAILABLE_KB:-0}" -ge 5242880 ] || { echo "At least 5 GiB free on $VOLUME is required." >&2; exit 2; }
LOAD_ONE=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')
awk -v load="$LOAD_ONE" 'BEGIN { exit !(load <= 10) }' || { echo "Host one-minute load exceeds 10; defer app build." >&2; exit 2; }
if [ -z "$RELAY" ] || [ ! -x "$RELAY" ]; then
  echo "Set MISTT_RELAY_BINARY to the integrated arm64 Go relay; test fixtures are never bundled." >&2
  exit 2
fi
[ -f "$INFO_PLIST" ] || { echo "MISTT_INFO_PLIST must name an existing Info.plist." >&2; exit 2; }
/usr/bin/lipo -verify_arch arm64 "$RELAY" >/dev/null 2>&1 || {
  echo "MISTT_RELAY_BINARY must contain an arm64 slice." >&2; exit 2;
}
mkdir -p "$BUILD_ROOT/swiftpm" "$BUILD_ROOT/metadata" "$BUILD_ROOT/tmp" "$BUILD_ROOT/clang" "$BUILD_ROOT/swift-module" "$ARTIFACT_ROOT"
export TMPDIR="$BUILD_ROOT/tmp" CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swift-module"
APP="$ARTIFACT_ROOT/MISTT.app"
[ ! -e "$APP" ] || { echo "Refusing to replace existing bundle: $APP. Choose a fresh MISTT_ARTIFACT_ROOT." >&2; exit 2; }
CLAIM_OUTPUT=$("$MISTT_CLAIM_SCRIPT" claim R-build-lease --purpose "swift build MISTT desktop arm64 release")
case "$CLAIM_OUTPUT" in
  "WON: R-build-lease "*) LEASE_SHA=${CLAIM_OUTPUT#WON: R-build-lease }; LEASE_HELD=1 ;;
  *) echo "$CLAIM_OUTPUT" >&2; exit 75 ;;
esac
swift build --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_ROOT/swiftpm" --configuration release --arch arm64 --jobs 2 --product MISTTDesktop
swift build --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_ROOT/swiftpm" --configuration release --arch arm64 --jobs 2 --show-bin-path > "$BUILD_ROOT/metadata/bin-path.txt"
release_lease
BIN_PATH=$(cat "$BUILD_ROOT/metadata/bin-path.txt")
SPARKLE_FRAMEWORK=$(find "$BUILD_ROOT/swiftpm" -type d -name Sparkle.framework -print -quit)
[ -n "$SPARKLE_FRAMEWORK" ] && [ -d "$SPARKLE_FRAMEWORK" ] || {
  echo "Pinned Sparkle.framework was not produced by SwiftPM." >&2; exit 2;
}
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH/MISTTDesktop" "$APP/Contents/MacOS/MISTTDesktop"
cp "$RELAY" "$APP/Contents/MacOS/mistt"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$PACKAGE_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PACKAGE_DIR/Resources/logo-3.svg" "$APP/Contents/Resources/logo-3.svg"
cp "$PACKAGE_DIR/Resources/logo-3-muted.svg" "$APP/Contents/Resources/logo-3-muted.svg"
cp "$PACKAGE_DIR/Resources/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp "$PACKAGE_DIR/../LICENSE" "$APP/Contents/Resources/MISTT-LICENSE.txt"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/MISTTDesktop" | grep -Fq '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/MISTTDesktop"
fi
chmod 755 "$APP/Contents/MacOS/MISTTDesktop" "$APP/Contents/MacOS/mistt"
# Re-sign Sparkle's nested helpers with the same identity as this app so
# hardened-runtime library validation sees a consistent Team ID. Sparkle 2.6+
# requires preserving entitlements only for Downloader.xpc; Autoupdate,
# Updater.app, and the framework must be signed without vendor entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
NESTED_BUNDLES=$(find "$SPARKLE" -type d \( -name '*.xpc' -o -name '*.app' \) -print \
  | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
while IFS= read -r nested; do
  [ -n "$nested" ] || continue
  case "${nested##*/}" in
    Downloader.xpc)
      codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$nested"
      ;;
    *)
      codesign "${SIGN_ARGS[@]}" "$nested"
      ;;
  esac
done <<< "$NESTED_BUNDLES"
AUTUPDATE="$SPARKLE/Versions/B/Autoupdate"
if [ -e "$AUTUPDATE" ]; then
  codesign "${SIGN_ARGS[@]}" "$AUTUPDATE"
fi
codesign "${SIGN_ARGS[@]}" "$SPARKLE"
codesign "${SIGN_ARGS[@]}" --entitlements "$PACKAGE_DIR/Resources/MISTT.entitlements" \
  "$APP/Contents/MacOS/mistt"
codesign "${SIGN_ARGS[@]}" --entitlements "$PACKAGE_DIR/Resources/MISTT.entitlements" \
  "$APP/Contents/MacOS/MISTTDesktop"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
  printf 'Built local ad-hoc app (not a signed release): %s\n' "$APP"
else
  printf 'Built local Developer ID signed app (not notarized): %s\n' "$APP"
fi
