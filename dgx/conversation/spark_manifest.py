#!/usr/bin/env python3
"""Render only; provisioning, ingress policy and Spark submission are separate."""
import argparse
import json
from pathlib import PurePosixPath
import re


def narrow(path):
    value = PurePosixPath(path)
    return value.is_absolute() and len(value.parts) >= 4 and ".." not in value.parts and str(value) == path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--models-host-path", required=True)
    parser.add_argument("--token-directory", required=True)
    parser.add_argument("--host-port", required=True, type=int)
    parser.add_argument("--private-ingress-ready", required=True, action="store_true",
                        help="Attest the selected host port is already restricted to the secure gateway/tunnel")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", args.name):
        parser.error("DNS label required")
    if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", args.image):
        parser.error("immutable registry image digest required")
    if not all(narrow(p) for p in (args.models_host_path, args.token_directory)):
        parser.error("dedicated narrow absolute mount directories required")
    model, token = map(PurePosixPath, (args.models_host_path, args.token_directory))
    if model == token or model in token.parents or token in model.parents:
        parser.error("model and token mounts must not overlap")
    if not 1024 <= args.host_port <= 65535:
        parser.error("unprivileged host port required")
    print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": args.name},
        "spec": {"restartPolicy": "Always", "containers": [{"name": "stt", "image": args.image,
            "command": ["python", "/app/serve.py"],
            "args": ["--host", "0.0.0.0", "--port", "8793", "--model-directory", "/models",
                     "--token-file", "/run/mistt/token"],
            "ports": [{"containerPort": 8793, "hostPort": args.host_port}],
            "resources": {"limits": {"cpu": "2", "memory": "4Gi"}},
            "livenessProbe": {"exec": {"command": ["python", "/app/healthcheck.py"]},
                              "initialDelaySeconds": 30, "periodSeconds": 10,
                              "timeoutSeconds": 3, "failureThreshold": 3},
            "volumeMounts": [{"name": "models", "mountPath": "/models", "readOnly": True},
                             {"name": "credential", "mountPath": "/run/mistt", "readOnly": True}]}],
            "volumes": [{"name": "models", "hostPath": {"path": args.models_host_path}},
                        {"name": "credential", "hostPath": {"path": args.token_directory}}]}}, indent=2))


if __name__ == "__main__":
    main()
