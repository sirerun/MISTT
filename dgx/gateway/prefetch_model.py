"""Prefetch the pinned ASR snapshot into the gateway's persistent HF cache."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap
from pathlib import Path

MODEL_ID = "microsoft/VibeVoice-ASR-Streaming-7B"
MODEL_REVISION = "60d858b518b4e19d404af3737f848fc185b30177"
HUB_VERSION = "0.34.4"


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
        from pathlib import Path
        from huggingface_hub import snapshot_download
        from huggingface_hub.errors import LocalEntryNotFoundError

        repo_id = {MODEL_ID!r}
        revision = {MODEL_REVISION!r}
        try:
            snapshot = snapshot_download(repo_id=repo_id, revision=revision, local_files_only=True)
            print("pinned snapshot already present")
        except LocalEntryNotFoundError:
            snapshot = snapshot_download(repo_id=repo_id, revision=revision)
            print("pinned snapshot download complete")
        model_path = Path(snapshot)
        for name in ("config.json", "preprocessor_config.json"):
            if not (model_path / name).is_file():
                raise RuntimeError(f"pinned model snapshot lacks {{name}}")
        record = {{"model_id": repo_id, "model_revision": revision, "snapshot_path": str(model_path)}}
        record_path = Path({str(cache_root / "prefetch-record.json")!r})
        temporary = record_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(record, sort_keys=True) + "\\n", encoding="utf-8")
        temporary.replace(record_path)
        print("pinned model snapshot verified; record written")
        """
    )
    subprocess.run([str(venv_python), "-c", script], check=True, env=env)


if __name__ == "__main__":
    main()
