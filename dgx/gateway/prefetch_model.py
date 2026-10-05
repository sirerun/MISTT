"""Prefetch the pinned ASR snapshot into the gateway's persistent HF cache."""

from __future__ import annotations

import json
import hashlib
import os
import subprocess
import sys
import textwrap
from pathlib import Path

MODEL_ID = "microsoft/VibeVoice-ASR-Streaming-7B"
MODEL_REVISION = "60d858b518b4e19d404af3737f848fc185b30177"
HUB_VERSION = "0.34.4"
WEIGHT_MANIFEST_PATH = Path(__file__).with_name("model-weight-manifest.json")
_WEIGHT_MANIFEST = json.loads(WEIGHT_MANIFEST_PATH.read_text(encoding="utf-8"))
if _WEIGHT_MANIFEST.get("model_id") != MODEL_ID or _WEIGHT_MANIFEST.get("revision") != MODEL_REVISION:
    raise RuntimeError("prefetch weight manifest does not match the pinned model identity")
EXPECTED_WEIGHT_MANIFEST = _WEIGHT_MANIFEST["weights"]
EXPECTED_WEIGHT_SHARDS = set(EXPECTED_WEIGHT_MANIFEST)


def verify_snapshot(
    model_path: Path, expected_weights: dict[str, dict[str, int | str]] | None = None
) -> tuple[list[str], int]:
    expected_weights = expected_weights or EXPECTED_WEIGHT_MANIFEST
    for name in ("config.json", "preprocessor_config.json"):
        if not (model_path / name).is_file():
            raise RuntimeError(f"pinned model snapshot lacks {name}")
    index = model_path / "model.safetensors.index.json"
    if not index.is_file():
        raise RuntimeError("pinned model snapshot lacks its safetensors weight index")
    payload = json.loads(index.read_text(encoding="utf-8"))
    weight_map = payload.get("weight_map")
    if not isinstance(weight_map, dict) or not weight_map:
        raise RuntimeError("pinned model weight index has no weight map")
    if not all(isinstance(name, str) for name in weight_map.values()):
        raise RuntimeError("pinned model weight index contains a non-string shard path")
    shards = set(weight_map.values())
    if shards != set(expected_weights):
        raise RuntimeError("pinned model weight index does not reference the complete shard set")
    total_bytes = 0
    for name in sorted(shards):
        shard = model_path / name
        metadata = expected_weights[name]
        expected_size = metadata.get("size")
        expected_digest = metadata.get("sha256")
        if not isinstance(expected_size, int) or expected_size <= 0:
            raise RuntimeError(f"pinned model manifest has an invalid size for {name}")
        if not isinstance(expected_digest, str) or len(expected_digest) != 64:
            raise RuntimeError(f"pinned model manifest has an invalid SHA-256 for {name}")
        if not shard.is_file() or shard.stat().st_size != expected_size:
            raise RuntimeError(f"pinned model snapshot has a missing, empty, or truncated weight shard {name}")
        if shard.is_symlink():
            blob_root = model_path.parent.parent / "blobs"
            try:
                shard.resolve(strict=True).relative_to(blob_root.resolve(strict=True))
            except (OSError, ValueError) as exc:
                raise RuntimeError(f"pinned model shard {name} resolves outside the Hub blob cache") from exc
        digest = hashlib.sha256()
        with shard.open("rb") as source_file:
            for chunk in iter(lambda: source_file.read(8 * 1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected_digest:
            raise RuntimeError(f"pinned model weight shard {name} has the wrong SHA-256")
        total_bytes += expected_size
    return sorted(shards), total_bytes


def main() -> None:
    cache_root = Path(os.environ.get("MISTT_CACHE_ROOT", "/var/cache/mistt"))
    cache_root.mkdir(parents=True, exist_ok=True)
    venv_dir = cache_root / "venv"
    venv_python = venv_dir / "bin" / "python"
    if not venv_python.is_file():
        subprocess.run(
            [sys.executable, "-m", "venv", "--system-site-packages", str(venv_dir)],
            check=True,
        )
    env = os.environ.copy()
    env.update(
        HF_HOME=str(cache_root / "hf"),
        PIP_CACHE_DIR=str(cache_root / "pip"),
        XDG_CACHE_HOME=str(cache_root / "xdg"),
        TMPDIR=str(cache_root / "tmp"),
    )
    for name in ("HF_HOME", "PIP_CACHE_DIR", "XDG_CACHE_HOME", "TMPDIR"):
        Path(env[name]).mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(venv_python),
            "-m",
            "pip",
            "install",
            "--disable-pip-version-check",
            f"huggingface_hub=={HUB_VERSION}",
        ],
        check=True,
        env=env,
    )
    script = textwrap.dedent(
        f"""\
        import json
        import sys
        from pathlib import Path
        from huggingface_hub import snapshot_download

        sys.path.insert(0, "/opt/mistt")
        repo_id = {MODEL_ID!r}
        revision = {MODEL_REVISION!r}
        from dgx.gateway.prefetch_model import verify_snapshot

        model_path = Path(snapshot_download(repo_id=repo_id, revision=revision, token=False))
        shards, total_bytes = verify_snapshot(model_path)
        record = {{"model_id": repo_id, "model_revision": revision,
                  "snapshot_path": str(model_path), "weight_shards": shards,
                  "weight_bytes": total_bytes}}
        record_path = Path({str(cache_root / "prefetch-record.json")!r})
        temporary = record_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(record, sort_keys=True) + "\\n", encoding="utf-8")
        temporary.replace(record_path)
        print("pinned model snapshot and all referenced weight shards verified; record written")
        """
    )
    env["PYTHONPATH"] = "/opt/mistt" + (
        os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
    )
    subprocess.run([str(venv_python), "-c", script], check=True, env=env)


if __name__ == "__main__":
    main()
