#!/bin/bash
set -euo pipefail
umask 077
mkdir -p /run/mistt-input /work /var/cache/mistt
python3 -m pip install --disable-pip-version-check cryptography==49.0.0 > /work/transport-install.log 2>&1
python3 - <<'PY'
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
from pathlib import Path
key=rsa.generate_private_key(public_exponent=65537,key_size=3072)
Path('/work/transport.key').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
Path('/work/transport.pub').write_bytes(key.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo))
PY
# Only encrypted credential payload crosses Spark exec; expire admission promptly.
for n in $(seq 1 300); do test ! -f /work/credentials.enc || break; sleep 1; done
test -f /work/credentials.enc
python3 - <<'PY'
import base64,json,os
from pathlib import Path
from cryptography.hazmat.primitives import serialization,hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
b=json.loads(Path('/work/credentials.enc').read_text())
k=serialization.load_pem_private_key(Path('/work/transport.key').read_bytes(),None)
a=k.decrypt(base64.b64decode(b['key']),padding.OAEP(mgf=padding.MGF1(hashes.SHA256()),algorithm=hashes.SHA256(),label=None))
d=json.loads(AESGCM(a).decrypt(base64.b64decode(b['nonce']),base64.b64decode(b['ciphertext']),b'mistt-practice-v1'))
for name in ('bearer','tls.crt','tls.key'):
 p=Path('/run/mistt-input')/name;p.write_text(d[name]);p.chmod(0o600)
p=Path('/work/auth.token');p.write_text(d['decision.token']);p.chmod(0o600)
Path('/work/transport.key').unlink();Path('/work/credentials.enc').unlink()
PY
export HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 DECISION_DEVICE=cuda
export HF_HOME=/var/cache/mistt/decision-hf
python3 -m venv --system-site-packages /work/decision-venv
/work/decision-venv/bin/pip install --disable-pip-version-check -r /opt/mistt/dgx/practice/decision-requirements.txt > /work/decision-install.log 2>&1
/work/decision-venv/bin/python /opt/mistt/dgx/practice/decision.py > /work/decision.log 2>&1 &
decision=$!
trap 'kill "$decision" 2>/dev/null || true' EXIT
# Upstream bootstrap retains its exact image, source, model and TLS validation.
/opt/mistt/dgx/gateway/bootstrap.sh
