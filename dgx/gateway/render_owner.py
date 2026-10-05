"""Render and locally validate the owner gateway Pod; never submits to Spark."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any

from .config import MODEL_ID, MODEL_REVISION, SOURCE_COMMIT


EXPECTED_IMAGE = (
    "nvcr.io/nvidia/pytorch@sha256:"
    "bbc2b67e2533edd63ff1496bb1ed00a00338cdc1478af6c1a0bf9f4b369977e7"
)
EXPECTED_CPU = "8"
EXPECTED_MEMORY = "48Gi"
EXPECTED_GPU = "1"
EXPECTED_STARTUP_SECONDS = "180"
PLACEHOLDER_COUNTS = {
    "MISTT_GATEWAY_POD_NAME": 1,
    "MISTT_GATEWAY_SOURCE_SHA": 1,
    "MISTT_GATEWAY_SOURCE_VOLUME": 1,
    "MISTT_GATEWAY_CACHE_VOLUME": 1,
    "MISTT_GATEWAY_CREDENTIALS_VOLUME": 1,
    "MISTT_GATEWAY_HOST_PORT": 1,
    "MISTT_GATEWAY_TLS_SERVER_NAME": 1,
}
STRING_KEYS = frozenset(PLACEHOLDER_COUNTS) - {"MISTT_GATEWAY_HOST_PORT"}
DNS_LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
SHA40 = re.compile(r"^[0-9a-f]{40}$")
PLACEHOLDER = re.compile(r"\$\{([A-Z0-9_]+)\}")
MAX_CONFIG_BYTES = 16 * 1024


class OwnerRenderError(ValueError):
    """A sanitized failure that never includes input values or file contents."""


def _fail() -> None:
    raise OwnerRenderError("invalid_owner_render_input")


def _pairs_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail()
        result[key] = value
    return result


def _reject_constant(_value: str) -> None:
    _fail()


def _absolute_path(path: str | Path) -> Path:
    candidate = Path(path)
    if not candidate.is_absolute():
        _fail()
    return Path(os.path.abspath(candidate))


def _open_private_parent(path: Path) -> int:
    parent = path.parent
    try:
        resolved = parent.resolve(strict=True)
        if resolved != parent:
            _fail()
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(parent, flags)
    except (OSError, RuntimeError):
        _fail()
    info = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        os.close(descriptor)
        _fail()
    return descriptor


def read_private_config(path: str | Path) -> tuple[dict[str, Any], str]:
    config_path = _absolute_path(path)
    parent_fd = _open_private_parent(config_path)
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(config_path.name, flags, dir_fd=parent_fd)
        except OSError:
            _fail()
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_size > MAX_CONFIG_BYTES
            ):
                _fail()
            raw = stream.read(MAX_CONFIG_BYTES + 1)
        if len(raw) > MAX_CONFIG_BYTES:
            _fail()
        try:
            text = raw.decode("utf-8")
            config = json.loads(
                text,
                object_pairs_hook=_pairs_without_duplicates,
                parse_constant=_reject_constant,
            )
        except (UnicodeDecodeError, json.JSONDecodeError):
            _fail()
        if not isinstance(config, dict):
            _fail()
        return config, hashlib.sha256(raw).hexdigest()
    finally:
        os.close(parent_fd)


def validate_config(config: dict[str, Any]) -> dict[str, Any]:
    if set(config) != set(PLACEHOLDER_COUNTS):
        _fail()
    values = dict(config)
    for name in STRING_KEYS:
        value = values[name]
        if not isinstance(value, str) or not value or value != value.strip():
            _fail()
        if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
            _fail()

    source_sha = values["MISTT_GATEWAY_SOURCE_SHA"]
    if not SHA40.fullmatch(source_sha):
        _fail()
    pod_name = values["MISTT_GATEWAY_POD_NAME"]
    if not DNS_LABEL.fullmatch(pod_name):
        _fail()
    sha_prefix = source_sha[:8]
    if sha_prefix not in pod_name.split("-"):
        _fail()

    volume_keys = (
        "MISTT_GATEWAY_SOURCE_VOLUME",
        "MISTT_GATEWAY_CACHE_VOLUME",
        "MISTT_GATEWAY_CREDENTIALS_VOLUME",
    )
    volume_names = [values[name] for name in volume_keys]
    if len(set(volume_names)) != len(volume_names):
        _fail()
    if any(not DNS_LABEL.fullmatch(name) for name in volume_names):
        _fail()

    port = values["MISTT_GATEWAY_HOST_PORT"]
    if type(port) is not int or not 1024 <= port <= 65535:
        _fail()
    values["MISTT_GATEWAY_HOST_PORT"] = port

    try:
        server_ip = ipaddress.ip_address(values["MISTT_GATEWAY_TLS_SERVER_NAME"])
    except ValueError:
        _fail()
    if server_ip.version != 4 or str(server_ip) != values["MISTT_GATEWAY_TLS_SERVER_NAME"]:
        _fail()
    return values


def _load_weight_pin() -> None:
    manifest_path = Path(__file__).with_name("model-weight-manifest.json")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        _fail()
    if not isinstance(manifest, dict):
        _fail()
    weights = manifest.get("weights")
    expected_names = {f"model-{index:05d}-of-00008.safetensors" for index in range(1, 9)}
    if (
        manifest.get("model_id") != MODEL_ID
        or manifest.get("revision") != MODEL_REVISION
        or not isinstance(weights, dict)
        or set(weights) != expected_names
        or any(
            not isinstance(row, dict)
            or type(row.get("size")) is not int
            or row["size"] <= 0
            or not isinstance(row.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"])
            for row in weights.values()
        )
        or sum(row["size"] for row in weights.values()) != 17_348_198_658
    ):
        _fail()


def _expected_template_placeholders(text: str) -> None:
    counts: dict[str, int] = {}
    for match in PLACEHOLDER.finditer(text):
        key = match.group(1)
        counts[key] = counts.get(key, 0) + 1
    if counts != PLACEHOLDER_COUNTS:
        _fail()


def _replace_placeholders(text: str, values: dict[str, Any]) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in values:
            _fail()
        value = values[name]
        if name == "MISTT_GATEWAY_HOST_PORT":
            return str(value)
        # The template keeps its surrounding JSON quotes. Encode only the
        # string body so quotes, backslashes, and control values cannot escape.
        encoded = json.dumps(value, ensure_ascii=True)
        return encoded[1:-1]

    return PLACEHOLDER.sub(replace, text)


def _validate_manifest(pod: Any, values: dict[str, Any]) -> None:
    if not isinstance(pod, dict) or set(pod) != {"apiVersion", "kind", "metadata", "spec"}:
        _fail()
    if pod["apiVersion"] != "v1" or pod["kind"] != "Pod":
        _fail()
    metadata = pod["metadata"]
    if not isinstance(metadata, dict) or set(metadata) != {"name", "labels"}:
        _fail()
    if metadata["name"] != values["MISTT_GATEWAY_POD_NAME"]:
        _fail()
    expected_labels = {
        "app": "mistt",
        "purpose": "owner-pinned-gateway",
        "gateway-source-sha": values["MISTT_GATEWAY_SOURCE_SHA"],
        "upstream-source-commit": SOURCE_COMMIT,
        "model-revision": MODEL_REVISION,
    }
    if metadata["labels"] != expected_labels:
        _fail()

    spec = pod["spec"]
    if not isinstance(spec, dict) or set(spec) != {"restartPolicy", "containers", "volumes"}:
        _fail()
    if spec["restartPolicy"] != "Never" or not isinstance(spec["containers"], list) or len(spec["containers"]) != 1:
        _fail()
    container = spec["containers"][0]
    if not isinstance(container, dict) or set(container) != {
        "name", "image", "command", "env", "ports", "resources", "volumeMounts", "livenessProbe"
    }:
        _fail()
    if (
        container["name"] != "gateway"
        or container["image"] != EXPECTED_IMAGE
        or container["command"] != ["bash", "-lc", "exec /opt/mistt/dgx/gateway/bootstrap.sh"]
    ):
        _fail()

    env = container["env"]
    if not isinstance(env, list):
        _fail()
    env_values: dict[str, str] = {}
    for item in env:
        if not isinstance(item, dict) or set(item) != {"name", "value"} or item["name"] in env_values:
            _fail()
        env_values[item["name"]] = item["value"]
    expected_env = {
        "HF_HOME": "/var/cache/mistt/hf",
        "PIP_CACHE_DIR": "/var/cache/mistt/pip",
        "XDG_CACHE_HOME": "/var/cache/mistt/xdg",
        "TMPDIR": "/var/cache/mistt/tmp",
        "MISTT_TOKEN_FILE": "/run/mistt-input/bearer",
        "MISTT_TLS_CERT_FILE": "/run/mistt-input/tls.crt",
        "MISTT_TLS_KEY_FILE": "/run/mistt-input/tls.key",
        "MISTT_TLS_PROBE_SERVER_NAME": values["MISTT_GATEWAY_TLS_SERVER_NAME"],
        "MISTT_STARTUP_TIMEOUT_SECONDS": EXPECTED_STARTUP_SECONDS,
    }
    if env_values != expected_env:
        _fail()

    if container["ports"] != [{
        "name": "https", "containerPort": 7870,
        "hostPort": values["MISTT_GATEWAY_HOST_PORT"], "protocol": "TCP",
    }]:
        _fail()
    resources = container["resources"]
    if resources != {"limits": {"memory": EXPECTED_MEMORY, "cpu": EXPECTED_CPU, "nvidia.com/gpu": EXPECTED_GPU}}:
        _fail()

    expected_mounts = {
        "gateway": {"name": "gateway", "mountPath": "/opt/mistt", "readOnly": True},
        "cache": {"name": "cache", "mountPath": "/var/cache/mistt"},
        "credentials": {"name": "credentials", "mountPath": "/run/mistt-input", "readOnly": True},
    }
    mounts = container["volumeMounts"]
    if not isinstance(mounts, list) or {item.get("name"): item for item in mounts if isinstance(item, dict)} != expected_mounts:
        _fail()
    expected_volumes = {
        "gateway": values["MISTT_GATEWAY_SOURCE_VOLUME"],
        "cache": values["MISTT_GATEWAY_CACHE_VOLUME"],
        "credentials": values["MISTT_GATEWAY_CREDENTIALS_VOLUME"],
    }
    volume_rows = spec["volumes"]
    if not isinstance(volume_rows, list):
        _fail()
    volumes: dict[str, Any] = {}
    for item in volume_rows:
        if not isinstance(item, dict) or set(item) != {"name", "hostPath"} or item["name"] in volumes:
            _fail()
        if not isinstance(item["hostPath"], dict) or set(item["hostPath"]) != {"path"}:
            _fail()
        volumes[item["name"]] = item["hostPath"]["path"]
    if volumes != expected_volumes or any("/" in path for path in volumes.values()):
        _fail()

    expected_probe = {
        "exec": {"command": ["python3", "/opt/mistt/dgx/gateway/probe_tls.py"]},
        "initialDelaySeconds": 120, "periodSeconds": 30,
        "timeoutSeconds": 5, "failureThreshold": 3,
    }
    if container["livenessProbe"] != expected_probe:
        _fail()


def render_manifest(template_text: str, config: dict[str, Any]) -> tuple[bytes, dict[str, Any]]:
    values = validate_config(config)
    _expected_template_placeholders(template_text)
    try:
        substituted = _replace_placeholders(template_text, values)
        pod = json.loads(substituted, object_pairs_hook=_pairs_without_duplicates, parse_constant=_reject_constant)
    except (json.JSONDecodeError, TypeError):
        _fail()
    try:
        _load_weight_pin()
        _validate_manifest(pod, values)
    except (KeyError, TypeError, AttributeError):
        _fail()
    rendered = (json.dumps(pod, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    return rendered, values


def _write_new_file(directory_fd: int, name: str, content: bytes) -> tuple[int, int, str]:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, 0o600, dir_fd=directory_fd)
    except OSError:
        _fail()
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(content)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                _fail()
            view = view[written:]
        os.fsync(descriptor)
        info = os.fstat(descriptor)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
            _fail()
        return info.st_dev, info.st_ino, hashlib.sha256(content).hexdigest()
    finally:
        os.close(descriptor)


def render_to_files(config_path: str | Path, output_path: str | Path, receipt_path: str | Path) -> None:
    config, config_sha = read_private_config(config_path)
    values = validate_config(config)
    template_path = Path(__file__).with_name("pod.json.in")
    if template_path.is_symlink():
        _fail()
    try:
        template = template_path.read_text(encoding="utf-8")
    except OSError:
        _fail()
    manifest, values = render_manifest(template, values)
    template_sha = hashlib.sha256(template.encode("utf-8")).hexdigest()
    receipt = {
        "schema": 1,
        "status": "rendered-and-validated",
        "config_sha256": config_sha,
        "template_sha256": template_sha,
        "manifest_sha256": hashlib.sha256(manifest).hexdigest(),
        "pod_name": values["MISTT_GATEWAY_POD_NAME"],
        "source_sha": values["MISTT_GATEWAY_SOURCE_SHA"],
        "image": EXPECTED_IMAGE,
        "model_id": MODEL_ID,
        "model_revision": MODEL_REVISION,
        "upstream_source_commit": SOURCE_COMMIT,
        "resources": {"gpu": 1, "cpu": 8, "memory": "48Gi"},
        "host_port": values["MISTT_GATEWAY_HOST_PORT"],
        "source_volume": values["MISTT_GATEWAY_SOURCE_VOLUME"],
        "cache_volume": values["MISTT_GATEWAY_CACHE_VOLUME"],
        "credentials_volume": values["MISTT_GATEWAY_CREDENTIALS_VOLUME"],
        "credential_values_included": False,
        "submitted_to_spark": False,
    }
    receipt_bytes = (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    output = _absolute_path(output_path)
    receipt_file = _absolute_path(receipt_path)
    if output == receipt_file or output.name == receipt_file.name:
        _fail()
    output_parent = _open_private_parent(output)
    try:
        receipt_parent = _open_private_parent(receipt_file)
        try:
            if output.parent != receipt_file.parent:
                _fail()
            created: list[tuple[str, int, int]] = []
            try:
                for name, content in ((output.name, manifest), (receipt_file.name, receipt_bytes)):
                    dev, ino, _digest = _write_new_file(output_parent, name, content)
                    created.append((name, dev, ino))
                os.fsync(output_parent)
            except BaseException:
                for name, dev, ino in reversed(created):
                    try:
                        current = os.stat(name, dir_fd=output_parent, follow_symlinks=False)
                        if current.st_dev == dev and current.st_ino == ino:
                            os.unlink(name, dir_fd=output_parent)
                    except OSError:
                        pass
                raise
        finally:
            os.close(receipt_parent)
    finally:
        os.close(output_parent)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--receipt", required=True)
    args = parser.parse_args()
    try:
        render_to_files(args.config, args.output, args.receipt)
    except (OwnerRenderError, OSError, ValueError):
        print("owner manifest rendering failed validation", file=sys.stderr)
        return 2
    print("owner manifest rendered and validated locally; no Spark request was made")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
