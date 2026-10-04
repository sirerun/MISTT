#!/usr/bin/env bash
set -euo pipefail
TASK=/task
exec > >(tee "$TASK/evidence/bootstrap.log") 2>&1
export PYTHONUNBUFFERED=1 HF_HOME="$TASK/cache/hf" PIP_CACHE_DIR="$TASK/cache/pip"
export XDG_CACHE_HOME="$TASK/cache/xdg" TMPDIR="$TASK/cache/tmp"
export OMP_NUM_THREADS=4 MKL_NUM_THREADS=4
mkdir -p "$TMPDIR" "$XDG_CACHE_HOME" "$TASK/source"
trap 'printf "BOOTSTRAP_EXIT=%s\n" "$?"' EXIT
python - <<'PY'
import platform, torch, json
print('BASE_RUNTIME',json.dumps({'arch':platform.machine(),'python':platform.python_version(),'torch':torch.__version__,'cuda':torch.version.cuda,'gpu':torch.cuda.get_device_name(0),'capability':torch.cuda.get_device_capability(0)}),flush=True)
assert platform.machine()=='aarch64' and torch.cuda.is_available()
a=torch.randn((64,64),device='cuda',dtype=torch.bfloat16); b=a@a; torch.cuda.synchronize()
print('CUDA_BF16_SMOKE_OK',flush=True)
PY
if [ ! -f "$TASK/source/pyproject.toml" ]; then
 tar -xzf "$TASK/vibevoice-1541f590.tar.gz" --strip-components=1 -C "$TASK/source"
fi
python -m venv --system-site-packages "$TASK/cache/venv"
source "$TASK/cache/venv/bin/activate"
python -m pip install --disable-pip-version-check \
 'transformers==4.56.2' 'accelerate==1.10.1' 'diffusers==0.35.1' \
 'fastapi==0.116.1' 'uvicorn==0.35.0' 'websockets==15.0.1' 'soundfile==0.13.1'
python -m pip install --disable-pip-version-check --no-deps -e "$TASK/source"
python - <<'PY'
import torch, transformers, diffusers, fastapi, platform, json
from vibevoice.modular.modeling_vibevoice_asr import VibeVoiceASRForConditionalGeneration
from vibevoice.processor.vibevoice_asr_processor import VibeVoiceASRProcessor
runtime={'arch':platform.machine(),'torch':torch.__version__,'cuda':torch.version.cuda,'transformers':transformers.__version__,'diffusers':diffusers.__version__,'fastapi':fastapi.__version__}
print('IMPORTS_OK',json.dumps(runtime),flush=True)
open('/task/evidence/runtime.json','w').write(json.dumps(runtime,indent=2)+'\n')
PY
python -m pip freeze > "$TASK/evidence/pip-freeze.txt"
python - <<'PY'
import time,json
from huggingface_hub import snapshot_download
start=time.monotonic()
path=snapshot_download(repo_id='microsoft/VibeVoice-ASR-Streaming-7B', revision='60d858b518b4e19d404af3737f848fc185b30177', cache_dir='/task/cache/hf/hub',allow_patterns=['*.json','*.txt','*.safetensors'],max_workers=4)
json.dump({'model_path':path,'revision':'60d858b518b4e19d404af3737f848fc185b30177','download_seconds':time.monotonic()-start},open('/task/evidence/checkpoint.json','w'),indent=2)
print('CHECKPOINT_READY',path,flush=True)
PY
printf 'BOOTSTRAP_READY\n'
touch "$TASK/evidence/bootstrap-ready"
# Hold the admitted test pod for coordinator-controlled inference execution.
sleep 1800
