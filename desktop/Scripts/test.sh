#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VOLUME=/Volumes/BuildOffload
BUILD_ROOT=${MISTT_BUILD_ROOT:-$VOLUME/build/MISTT-code-native-20261004}
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
case "$BUILD_ROOT" in "$VOLUME"/*) ;; *) echo "Build cache must stay on $VOLUME." >&2; exit 2 ;; esac
MOUNTED_AT=$(df -P "$VOLUME" | awk 'NR == 2 {print $NF}')
[ "$MOUNTED_AT" = "$VOLUME" ] && [ -w "$VOLUME" ] || { echo "$VOLUME is not mounted and writable." >&2; exit 2; }
AVAILABLE_KB=$(df -Pk "$VOLUME" | awk 'NR==2 {print $4}')
[ "${AVAILABLE_KB:-0}" -ge 5242880 ] || { echo "At least 5 GiB free on $VOLUME is required." >&2; exit 2; }
LOAD_ONE=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')
awk -v load="$LOAD_ONE" 'BEGIN { exit !(load <= 10) }' || { echo "Host one-minute load exceeds 10; defer Swift tests." >&2; exit 2; }
mkdir -p "$BUILD_ROOT/swiftpm" "$BUILD_ROOT/tmp" "$BUILD_ROOT/clang" "$BUILD_ROOT/swift-module"
export TMPDIR="$BUILD_ROOT/tmp" CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/swift-module"
CLAIM_OUTPUT=$("$MISTT_CLAIM_SCRIPT" claim R-build-lease --purpose "swift test MISTT desktop")
case "$CLAIM_OUTPUT" in
  "WON: R-build-lease "*) LEASE_SHA=${CLAIM_OUTPUT#WON: R-build-lease }; LEASE_HELD=1 ;;
  *) echo "$CLAIM_OUTPUT" >&2; exit 75 ;;
esac
desktop_status=0
preflight_status=0
swift test --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_ROOT/desktop" --jobs 2 || desktop_status=$?
swift test --package-path "$PACKAGE_DIR/Tools/NativeCapturePreflight" --scratch-path "$BUILD_ROOT/preflight" --jobs 2 || preflight_status=$?
release_lease
if [ "$desktop_status" -ne 0 ]; then exit "$desktop_status"; fi
if [ "$preflight_status" -ne 0 ]; then exit "$preflight_status"; fi
