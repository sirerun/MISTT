#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MISTT_CLAIM_SCRIPT:?Set the installed shared build claim script path}"
: "${CLAIM_REMOTE:?Set the shared Mac build lease repository}"
MISTT_VALIDATE_ROOT="${MISTT_VALIDATE_ROOT:-/Volumes/BuildOffload/build/mistt-product-validation}"
test -d /Volumes/BuildOffload && test -w /Volumes/BuildOffload
python3 -c 'import os,sys; sys.exit(0 if os.path.ismount("/Volumes/BuildOffload") else 75)'
case "$MISTT_VALIDATE_ROOT" in /Volumes/BuildOffload/*) ;; *) echo 'Use an external SSD validation root' >&2; exit 2;; esac
mkdir -p "$MISTT_VALIDATE_ROOT/tmp"
export GOCACHE="$MISTT_VALIDATE_ROOT/gocache" GOMODCACHE="$MISTT_VALIDATE_ROOT/gomodcache"
export TMPDIR="$MISTT_VALIDATE_ROOT/tmp" CLANG_MODULE_CACHE_PATH="$MISTT_VALIDATE_ROOT/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$MISTT_VALIDATE_ROOT/swift-module"
lease_held=0
lease_sha=
release_lease() {
  if [ "$lease_held" = 1 ]; then
    "$MISTT_CLAIM_SCRIPT" release R-build-lease "$lease_sha"
    lease_held=0
  fi
}
trap release_lease EXIT
admitted() {
  uptime
  python3 -c 'import os,sys; sys.exit(0 if os.getloadavg()[0] <= 10 else 75)'
  claim_output=$("$MISTT_CLAIM_SCRIPT" claim R-build-lease --purpose "$*")
  case "$claim_output" in WON:*) lease_held=1 ;; *) echo "$claim_output" >&2; return 75;; esac
  lease_sha=$(printf '%s\n' "$claim_output" | awk '{print $3}')
  local result=0
  "$@" || result=$?
  release_lease
  return "$result"
}
admitted go test ./... -timeout 120s
admitted go vet ./...
if [ "${MISTT_RUN_RACE:-0}" = 1 ]; then admitted go test -race ./... -timeout 120s; fi
admitted swift test --package-path desktop --scratch-path "$MISTT_VALIDATE_ROOT/desktop" --jobs 2
admitted swift test --package-path desktop/Tools/NativeCapturePreflight --scratch-path "$MISTT_VALIDATE_ROOT/preflight" --jobs 2
