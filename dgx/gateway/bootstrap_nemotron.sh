#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${MISTT_TOKEN_FILE:?existing token file required}"
: "${MISTT_NEMOTRON_CACHE_DIR:?settled public Nemotron cache required}"
export MISTT_CACHE_ROOT="${MISTT_CACHE_ROOT:-/var/cache/mistt}"
export HF_HOME="$MISTT_CACHE_ROOT/hf"
export PIP_CACHE_DIR="$MISTT_CACHE_ROOT/pip-nemotron"
export XDG_CACHE_HOME="$MISTT_CACHE_ROOT/xdg"
export TMPDIR="$MISTT_CACHE_ROOT/tmp"
export OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 TOKENIZERS_PARALLELISM=false
export PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$PIP_CACHE_DIR" "$XDG_CACHE_HOME" "$TMPDIR"
REQ_HASH="$(sha256sum "$repo_root/dgx/gateway/requirements-nemotron.txt" | cut -d ' ' -f 1)"
venv_root="$MISTT_CACHE_ROOT/venvs/nemotron-$REQ_HASH"
if [[ ! -x "$venv_root/bin/python" ]]; then
  python3 -m venv --system-site-packages "$venv_root"
fi
PYTHON_BIN="$venv_root/bin/python"
if [[ ! -f "$venv_root/.requirements-ready" ]]; then
  "$PYTHON_BIN" -m pip install --disable-pip-version-check -r "$repo_root/dgx/gateway/requirements-nemotron.txt"
  touch "$venv_root/.requirements-ready"
fi
# No model metadata/download path is enabled in this profile.
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1
cd "$repo_root"
CREDENTIAL_DIR=$("$PYTHON_BIN" -m dgx.gateway.credentials /run/mistt-input /tmp)
export MISTT_TOKEN_FILE="$CREDENTIAL_DIR/bearer"
export MISTT_TLS_CERT_FILE="$CREDENTIAL_DIR/tls.crt"
export MISTT_TLS_KEY_FILE="$CREDENTIAL_DIR/tls.key"
exec "$PYTHON_BIN" -m dgx.gateway
