#!/usr/bin/env python3
"""Download exactly the reviewed model revision into a NEW dedicated directory."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

p = argparse.ArgumentParser()
p.add_argument("--pins", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
pins = json.loads(a.pins.read_text())
a.output.mkdir(parents=True, exist_ok=False)
for asset in pins["files"]:
    name = asset["path"]
    if Path(name).name != name:
        raise ValueError("model asset must be a simple filename")
    url = f'https://huggingface.co/{pins["model"]}/resolve/{pins["revision"]}/{name}'
    target = a.output / name
    digest = hashlib.sha256()
    count = 0
    with urllib.request.urlopen(url, timeout=120) as response, target.open("xb") as output:
        while chunk := response.read(1 << 20):
            count += len(chunk)
            if count > asset["bytes"]:
                raise ValueError("asset exceeds pinned length")
            digest.update(chunk)
            output.write(chunk)
    if count != asset["bytes"] or digest.hexdigest() != asset["sha256"]:
        raise ValueError(f"model asset hash mismatch: {name}")
    print(json.dumps({"prepared": name, "sha256": digest.hexdigest(), "bytes": count}), flush=True)
(a.output / "pins.json").write_text(json.dumps(pins, indent=2) + "\n")
