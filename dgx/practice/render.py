"""Render bounded practice desired state; never contacts Spark or changes clients."""
import argparse, base64, io, json, os, re, subprocess, tarfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
IMAGE = "nvcr.io/nvidia/pytorch@sha256:bbc2b67e2533edd63ff1496bb1ed00a00338cdc1478af6c1a0bf9f4b369977e7"

def render(*, asr_only=False, name="zendesk-paired-practice-20261104", lifetime_seconds=43200):
    if not re.fullmatch(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?", name):
        raise ValueError("Invalid bounded owner pod name")
    if type(lifetime_seconds) is not int or not 600 <= lifetime_seconds <= 43200:
        raise ValueError("Lifetime must be 600 through 43200 seconds")
    if type(asr_only) is not bool: raise ValueError("Mode must be explicit Boolean")
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w:gz") as tar:
        tracked = subprocess.check_output(["git", "ls-files", "-z", "dgx/gateway", "dgx/practice"], cwd=ROOT).decode().split("\0")
        for relative in sorted(filter(None, tracked)):
            path = ROOT / relative
            if relative.startswith("dgx/practice/") and path.suffix not in (".py", ".sh", ".txt"):
                continue
            if path.is_symlink():
                raise ValueError("Source symlinks are refused")
            tar.add(path, arcname=relative, recursive=False)
    payload = base64.b64encode(archive.getvalue()).decode()
    script = "set -eu; umask 077; mkdir -p /opt/mistt; printf '%s' '" + payload + "' | base64 -d | tar xz -C /opt/mistt; exec timeout " + str(lifetime_seconds) + " bash /opt/mistt/dgx/practice/bootstrap.sh"
    mode = "asr-only" if asr_only else "paired-and-decision"
    ports = [{"containerPort": 7870, "hostPort": 18772}]
    if not asr_only: ports.append({"containerPort": 28193, "hostPort": 28193})
    resources = {"cpu": "8", "memory": "48Gi" if asr_only else "64Gi", "nvidia.com/gpu": "1"}
    return {"apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "labels": {"purpose": "owned-bounded-paired-practice", "practice-mode": mode, "gateway-source-sha": source}},
        "spec": {"restartPolicy": "Never", "containers": [{
            "name": "practice", "image": IMAGE, "command": ["bash", "-lc", script],
            "env": [{"name": "MISTT_TLS_PROBE_SERVER_NAME", "value": "192.168.86.250"}, {"name": "MISTT_PRACTICE_MODE", "value": mode}],
            "ports": ports, "resources": {"requests": resources.copy(), "limits": resources.copy()},
            "volumeMounts": [{"name": "work", "mountPath": "/work"}]}],
            "volumes": [{"name": "work", "emptyDir": {}}]}}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asr-only", action="store_true", help="Do not install/start Qwen or expose a decision port")
    parser.add_argument("--name", default="zendesk-paired-practice-20261104")
    parser.add_argument("--lifetime-seconds", type=int, default=43200)
    parser.add_argument("--output", type=Path, required=True, help="NEW file in an existing owner-only directory")
    args = parser.parse_args()
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip():
        raise ValueError("Commit the exact source before rendering a persisted preview")
    parent = args.output.absolute().parent
    info = parent.stat()
    if not parent.is_dir() or parent.resolve() != parent or parent.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Protected output directory required; existing permissions are not repaired")
    manifest = render(asr_only=args.asr_only, name=args.name, lifetime_seconds=args.lifetime_seconds)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(manifest, output, indent=2); output.write("\n"); output.flush(); os.fsync(output.fileno())
    container = manifest["spec"]["containers"][0]
    print(json.dumps({"preview_only": True, "pod": manifest["metadata"]["name"], "mode": manifest["metadata"]["labels"]["practice-mode"],
        "lifetime_seconds": args.lifetime_seconds, "image": container["image"], "resources": container["resources"], "ports": container["ports"],
        "client_configuration_changed": False, "spark_requests": 0}))
if __name__ == "__main__": main()
