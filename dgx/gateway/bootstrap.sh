#!/usr/bin/env bash
set -euo pipefail

ROOT=/opt/mistt
CACHE=/var/cache/mistt
SOURCE_COMMIT=1541f590c7099820f10ea012f48d2399282df69f
SOURCE_ARCHIVE_SHA256=cbd51f4539a709cb2ddc1f92406e69278af00f064ee420f1eda28f8b385a18e0
IMAGE_TORCH='2.11.0a0+eb65b36914.nv26.02'
mkdir -p "$CACHE"/{hf,pip,tmp,xdg,upstream}
export HF_HOME="$CACHE/hf" PIP_CACHE_DIR="$CACHE/pip" XDG_CACHE_HOME="$CACHE/xdg" TMPDIR="$CACHE/tmp"
export PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=4 MKL_NUM_THREADS=4
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
import platform, torch
assert platform.machine() == "aarch64", "gateway requires the qualified ARM64 image"
assert torch.__version__ == "2.11.0a0+eb65b36914.nv26.02", "unexpected PyTorch build"
assert torch.version.cuda == "13.1" and torch.cuda.is_available(), "qualified CUDA runtime unavailable"
assert torch.cuda.is_bf16_supported(), "qualified BF16 path unavailable"
PY

case "${MISTT_RUNTIME:-vibevoice}" in
  vibevoice) ;;
  nemotron3_5) exec bash "$ROOT/dgx/gateway/bootstrap_nemotron.sh" ;;
  *) echo "unsupported gateway runtime profile" >&2; exit 1 ;;
esac

archive="$CACHE/upstream/vibevoice-$SOURCE_COMMIT-$SOURCE_ARCHIVE_SHA256.tar.gz"
verified_source="$CACHE/upstream/source-$SOURCE_COMMIT-$SOURCE_ARCHIVE_SHA256"
if [[ -e "$archive" || -L "$archive" ]]; then
  python3 -m dgx.gateway.upstream_source --source "$verified_source" --archive "$archive"
else
  downloaded=$(mktemp "$CACHE/tmp/vibevoice-$SOURCE_COMMIT.XXXXXX.tar.gz")
  cleanup_download() { rm -f -- "$downloaded"; }
  trap cleanup_download EXIT
  curl --fail --location --silent --show-error --connect-timeout 10 --max-time 180 \
    "https://github.com/microsoft/VibeVoice/archive/$SOURCE_COMMIT.tar.gz" -o "$downloaded"
  python3 -m dgx.gateway.upstream_source --source "$verified_source" --archive "$archive" --downloaded "$downloaded"
  cleanup_download
  trap - EXIT
fi

VENV="$CACHE/venv-$SOURCE_COMMIT-$SOURCE_ARCHIVE_SHA256"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv --system-site-packages "$VENV"
fi
source "$VENV/bin/activate"
export PYTHONPATH="$verified_source:$ROOT"
python -m pip install --disable-pip-version-check -r "$ROOT/dgx/gateway/requirements.txt"
python - "$verified_source" <<'PY'
from pathlib import Path
import sys
from dgx.gateway.upstream_source import verify_import_source
verify_import_source(Path(sys.argv[1]))
PY
cd "$ROOT"
# Projected Secret entries are symlinks; retain strict regular-file validation
# by snapshotting the read-only mount into a service-private directory.
CREDENTIAL_DIR=$(python -m dgx.gateway.credentials /run/mistt-input /tmp)
export MISTT_TOKEN_FILE="$CREDENTIAL_DIR/bearer"
export MISTT_TLS_CERT_FILE="$CREDENTIAL_DIR/tls.crt"
export MISTT_TLS_KEY_FILE="$CREDENTIAL_DIR/tls.key"
exec python -m dgx.gateway
