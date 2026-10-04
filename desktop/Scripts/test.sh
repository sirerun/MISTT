#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VOLUME=/Volumes/BuildOffload
BUILD_ROOT=${MISTT_BUILD_ROOT:-$VOLUME/build/MISTT-code-native-20261004}
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
case "$BUILD_ROOT" in "$VOLUME"/*) ;; *) echo "Build cache must stay on $VOLUME." >&2; exit 2 ;; esac
[ -d "$VOLUME" ] && [ -w "$VOLUME" ] || { echo "$VOLUME is not mounted and writable." >&2; exit 2; }
AVAILABLE_KB=$(df -Pk "$VOLUME" | awk 'NR==2 {print $4}')
[ "${AVAILABLE_KB:-0}" -ge 5242880 ] || { echo "At least 5 GiB free on $VOLUME is required." >&2; exit 2; }
LOAD_ONE=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')
awk -v load="$LOAD_ONE" 'BEGIN { exit !(load <= 10) }' || { echo "Host one-minute load exceeds 10; defer Swift tests." >&2; exit 2; }
mkdir -p "$BUILD_ROOT/swiftpm"
CLAIM_REMOTE="$CLAIM_REMOTE" "$CLAIM_SCRIPT" claim R-build-lease --purpose "swift test MISTT desktop" >/dev/null
LEASE_HELD=1
swift test --package-path "$PACKAGE_DIR" --scratch-path "$BUILD_ROOT/swiftpm" --jobs 4
release_lease
