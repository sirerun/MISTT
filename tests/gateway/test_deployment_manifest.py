from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from dgx.gateway.prefetch_model import verify_snapshot


ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "dgx" / "gateway" / "pod.json.in"
PREFETCH_TEMPLATE = ROOT / "dgx" / "gateway" / "prefetch-pod.json.in"
VALUES = {
    "MISTT_GATEWAY_POD_NAME": "mistt-gateway-owner-qual",
    "MISTT_GATEWAY_SOURCE_SHA": "0123456789abcdef0123456789abcdef01234567",
    "MISTT_GATEWAY_SOURCE_VOLUME": "mistt-gateway-source-owner-qual",
    "MISTT_GATEWAY_CACHE_VOLUME": "mistt-gateway-cache-owner-qual",
    "MISTT_GATEWAY_CREDENTIALS_VOLUME": "mistt-gateway-credentials-owner-qual",
    "MISTT_GATEWAY_HOST_PORT": "18772",
    "MISTT_GATEWAY_TLS_SERVER_NAME": "192.0.2.10",
}


def render_template() -> dict:
    rendered = TEMPLATE.read_text(encoding="utf-8")
    for name, value in VALUES.items():
        rendered = rendered.replace("${" + name + "}", value)
    if "${" in rendered:
        raise AssertionError("unrendered placeholder in gateway Pod template")
    return json.loads(rendered)


def render_prefetch_template() -> dict:
    rendered = PREFETCH_TEMPLATE.read_text(encoding="utf-8")
    values = {
        "MISTT_PREFETCH_POD_NAME": "mistt-prefetch-owner-qual",
        "MISTT_GATEWAY_SOURCE_SHA": "0123456789abcdef0123456789abcdef01234567",
        "MISTT_GATEWAY_SOURCE_VOLUME": "mistt-gateway-source-owner-qual",
        "MISTT_GATEWAY_CACHE_VOLUME": "mistt-gateway-cache-owner-qual",
    }
    for name, value in values.items():
        rendered = rendered.replace("${" + name + "}", value)
    if "${" in rendered:
        raise AssertionError("unrendered placeholder in model prefetch Pod template")
    return json.loads(rendered)


class DeploymentManifestTests(unittest.TestCase):
    def test_renders_pinned_owner_volumes_and_configurable_lan_host_port(self) -> None:
        pod = render_template()
        self.assertEqual(pod["kind"], "Pod")
        self.assertEqual(pod["metadata"]["name"], VALUES["MISTT_GATEWAY_POD_NAME"])
        labels = pod["metadata"]["labels"]
        self.assertEqual(labels["gateway-source-sha"], VALUES["MISTT_GATEWAY_SOURCE_SHA"])
        self.assertEqual(
            labels["upstream-source-commit"],
            "1541f590c7099820f10ea012f48d2399282df69f",
        )
        self.assertEqual(labels["model-revision"], "60d858b518b4e19d404af3737f848fc185b30177")

        container = pod["spec"]["containers"][0]
        self.assertEqual(
            container["image"],
            "nvcr.io/nvidia/pytorch@sha256:bbc2b67e2533edd63ff1496bb1ed00a00338cdc1478af6c1a0bf9f4b369977e7",
        )
        self.assertEqual(container["resources"]["limits"], {
            "memory": "48Gi",
            "cpu": "8",
            "nvidia.com/gpu": "1",
        })
        self.assertEqual(
            {item["name"]: item["value"] for item in container["env"]}[
                "MISTT_STARTUP_TIMEOUT_SECONDS"
            ],
            "180",
        )
        self.assertEqual(container["ports"], [{
            "name": "https",
            "containerPort": 7870,
            "hostPort": 18772,
            "protocol": "TCP",
        }])
        self.assertNotIn("hostIP", container["ports"][0])
        self.assertEqual(container["command"], [
            "bash", "-lc", "exec /opt/mistt/dgx/gateway/bootstrap.sh"
        ])
        self.assertNotIn("args", container)

        mounts = {item["name"]: item for item in container["volumeMounts"]}
        self.assertEqual(mounts["gateway"]["mountPath"], "/opt/mistt")
        self.assertTrue(mounts["gateway"]["readOnly"])
        self.assertEqual(mounts["cache"]["mountPath"], "/var/cache/mistt")
        self.assertFalse(mounts["cache"].get("readOnly", False))
        self.assertEqual(mounts["credentials"]["mountPath"], "/run/mistt-input")
        self.assertTrue(mounts["credentials"]["readOnly"])

        volumes = {item["name"]: item["hostPath"] for item in pod["spec"]["volumes"]}
        self.assertEqual(set(volumes), {"gateway", "cache", "credentials"})
        for volume_name, placeholder in (
            ("gateway", "MISTT_GATEWAY_SOURCE_VOLUME"),
            ("cache", "MISTT_GATEWAY_CACHE_VOLUME"),
            ("credentials", "MISTT_GATEWAY_CREDENTIALS_VOLUME"),
        ):
            volume_path = volumes[volume_name]["path"]
            self.assertEqual(volume_path, VALUES[placeholder])
            self.assertNotIn("/", volume_path)
            self.assertNotIn("type", volumes[volume_name])

        self.assertNotIn("readinessProbe", container)
        self.assertEqual(
            {item["name"]: item["value"] for item in container["env"]}[
                "MISTT_TLS_PROBE_SERVER_NAME"
            ],
            VALUES["MISTT_GATEWAY_TLS_SERVER_NAME"],
        )
        probe = container["livenessProbe"]
        self.assertEqual(
            probe["exec"]["command"],
            ["python3", "/opt/mistt/dgx/gateway/probe_tls.py"],
        )
        self.assertEqual(probe["initialDelaySeconds"], 120)
        self.assertEqual(probe["periodSeconds"], 30)
        self.assertEqual(probe["timeoutSeconds"], 5)
        self.assertEqual(probe["failureThreshold"], 3)
        self.assertNotIn("httpGet", probe)
        self.assertNotIn("secret", json.dumps(pod).lower())
        self.assertNotIn("persistentVolumeClaim", json.dumps(pod))

    def test_prefetch_template_is_bounded_cpu_only_and_uses_gateway_cache(self) -> None:
        pod = render_prefetch_template()
        container = pod["spec"]["containers"][0]
        self.assertEqual(container["command"], [
            "python3", "/opt/mistt/dgx/gateway/prefetch_model.py"
        ])
        self.assertEqual(container["resources"]["limits"], {
            "cpu": "1", "memory": "4Gi"
        })
        self.assertNotIn("nvidia.com/gpu", json.dumps(pod))
        self.assertEqual(pod["spec"]["activeDeadlineSeconds"], 3600)
        mounts = {x["name"]: x["mountPath"] for x in container["volumeMounts"]}
        self.assertEqual(mounts, {
            "gateway": "/opt/mistt", "cache": "/var/cache/mistt"
        })


class ModelPrefetchTests(unittest.TestCase):
    def test_partial_weight_index_fails_instead_of_marking_cache_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "config.json").write_text("{}", encoding="utf-8")
            (root / "preprocessor_config.json").write_text("{}", encoding="utf-8")
            partial = b"partial"
            (root / "model-00001.safetensors").write_bytes(partial)
            (root / "model.safetensors.index.json").write_text(
                json.dumps({"weight_map": {"encoder.weight": "model-00001.safetensors"}}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "complete shard set"):
                verify_snapshot(root, {
                    "model-00001.safetensors": {"size": len(partial), "sha256": hashlib.sha256(partial).hexdigest()},
                    "model-00002.safetensors": {"size": 1, "sha256": hashlib.sha256(b"x").hexdigest()},
                })

    def test_complete_weight_index_reports_all_nonempty_shards(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "config.json").write_text("{}", encoding="utf-8")
            (root / "preprocessor_config.json").write_text("{}", encoding="utf-8")
            fixture_weights = {
                "model-00001.safetensors": b"first",
                "model-00002.safetensors": b"second",
            }
            (root / "model.safetensors.index.json").write_text(
                json.dumps({"weight_map": {
                    f"weight.{i}": name for i, name in enumerate(fixture_weights)
                }}),
                encoding="utf-8",
            )
            expected = {}
            for name, content in fixture_weights.items():
                (root / name).write_bytes(content)
                expected[name] = {"size": len(content), "sha256": hashlib.sha256(content).hexdigest()}
            shards, size = verify_snapshot(root, expected)
            self.assertEqual(shards, sorted(fixture_weights))
            self.assertEqual(size, sum(map(len, fixture_weights.values())))

    def test_truncated_or_wrong_content_weight_fails_hash_check(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "config.json").write_text("{}", encoding="utf-8")
            (root / "preprocessor_config.json").write_text("{}", encoding="utf-8")
            name = "model-00001.safetensors"
            (root / "model.safetensors.index.json").write_text(
                json.dumps({"weight_map": {"encoder.weight": name}}), encoding="utf-8"
            )
            content = b"truncated"
            (root / name).write_bytes(content)
            expected = {name: {"size": len(content), "sha256": hashlib.sha256(b"complete").hexdigest()}}
            with self.assertRaisesRegex(RuntimeError, "wrong SHA-256"):
                verify_snapshot(root, expected)

    def test_weight_index_rejects_parent_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "config.json").write_text("{}", encoding="utf-8")
            (root / "preprocessor_config.json").write_text("{}", encoding="utf-8")
            (root / "model.safetensors.index.json").write_text(
                json.dumps({"weight_map": {"bad.weight": "../../escape.safetensors"}}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "complete shard set"):
                verify_snapshot(root, {
                    "model-00001.safetensors": {"size": 1, "sha256": hashlib.sha256(b"x").hexdigest()},
                    "model-00002.safetensors": {"size": 1, "sha256": hashlib.sha256(b"x").hexdigest()},
                })

    def test_snapshot_shard_symlink_must_stay_inside_hub_blob_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp)
            repo_cache = temp_root / "models--microsoft--VibeVoice-ASR-Streaming-7B"
            root = repo_cache / "snapshots" / "pinned-revision"
            blobs = repo_cache / "blobs"
            root.mkdir(parents=True)
            blobs.mkdir()
            (root / "config.json").write_text("{}", encoding="utf-8")
            (root / "preprocessor_config.json").write_text("{}", encoding="utf-8")
            fixture_names = ["model-00001.safetensors", "model-00002.safetensors"]
            (root / "model.safetensors.index.json").write_text(
                json.dumps({"weight_map": {f"weight.{i}": name for i, name in enumerate(fixture_names)}}),
                encoding="utf-8",
            )
            outside = temp_root / "outside.safetensors"
            outside.write_bytes(b"outside")
            expected = {}
            for i, name in enumerate(fixture_names):
                destination = root / name
                content = b"outside" if i == 0 else b"inside"
                expected[name] = {"size": len(content), "sha256": hashlib.sha256(content).hexdigest()}
                if i == 0:
                    destination.symlink_to(outside)
                else:
                    destination.write_bytes(content)
            with self.assertRaisesRegex(RuntimeError, "outside the Hub blob cache"):
                verify_snapshot(root, expected)

    def test_import_works_from_outside_repository_with_installed_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            env = os.environ.copy()
            env["PYTHONPATH"] = str(ROOT)
            result = subprocess.run(
                [sys.executable, "-c", "from dgx.gateway.prefetch_model import verify_snapshot"],
                cwd=temp,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
