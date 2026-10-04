#!/usr/bin/env bash
set -euo pipefail

ROOT=/opt/mistt
CACHE=/var/cache/mistt
SOURCE_COMMIT=1541f590c7099820f10ea012f48d2399282df69f
IMAGE_TORCH='2.11.0a0+eb65b36914.nv26.02'
mkdir -p "$CACHE"/{hf,pip,tmp,xdg,source}
export HF_HOME="$CACHE/hf" PIP_CACHE_DIR="$CACHE/pip" XDG_CACHE_HOME="$CACHE/xdg" TMPDIR="$CACHE/tmp"
export PYTHONUNBUFFERED=1 OMP_NUM_THREADS=4 MKL_NUM_THREADS=4

python3 - <<'PY'
import platform, torch
assert platform.machine() == "aarch64", "gateway requires the qualified ARM64 image"
assert torch.__version__ == "2.11.0a0+eb65b36914.nv26.02", "unexpected PyTorch build"
assert torch.version.cuda == "13.1" and torch.cuda.is_available(), "qualified CUDA runtime unavailable"
assert torch.cuda.is_bf16_supported(), "qualified BF16 path unavailable"
PY

if [[ ! -f "$CACHE/source/pyproject.toml" ]]; then
  archive="$CACHE/tmp/vibevoice-$SOURCE_COMMIT.tar.gz"
  curl --fail --location --silent --show-error \
    "https://github.com/microsoft/VibeVoice/archive/$SOURCE_COMMIT.tar.gz" -o "$archive"
  tar -xzf "$archive" --strip-components=1 -C "$CACHE/source"
fi

if [[ ! -x "$CACHE/venv/bin/python" ]]; then
  python3 -m venv --system-site-packages "$CACHE/venv"
fi
source "$CACHE/venv/bin/activate"
python -m pip install --disable-pip-version-check -r "$ROOT/dgx/gateway/requirements.txt"
python -m pip install --disable-pip-version-check --no-deps -e "$CACHE/source"
cd "$ROOT"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
exec python -m dgx.gateway

