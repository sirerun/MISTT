from __future__ import annotations

import json
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
            "cpu": "4",
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

        self.assertEqual(container["readinessProbe"]["httpGet"]["scheme"], "HTTPS")
        self.assertEqual(container["readinessProbe"]["httpGet"]["path"], "/mistt/healthz")
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
            (root / "model.safetensors.index.json").write_text(
                json.dumps({"weight_map": {"encoder.weight": "model-00001.safetensors"}}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "missing weight shard"):
                verify_snapshot(root)

    def test_complete_weight_index_reports_all_nonempty_shards(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "config.json").write_text("{}", encoding="utf-8")
            (root / "preprocessor_config.json").write_text("{}", encoding="utf-8")
            (root / "model.safetensors.index.json").write_text(
                json.dumps({"weight_map": {
                    "encoder.weight": "model-00001.safetensors",
                    "decoder.weight": "model-00002.safetensors",
                }}),
                encoding="utf-8",
            )
            (root / "model-00001.safetensors").write_bytes(b"first")
            (root / "model-00002.safetensors").write_bytes(b"second")
            shards, size = verify_snapshot(root)
            self.assertEqual(shards, ["model-00001.safetensors", "model-00002.safetensors"])
            self.assertEqual(size, len(b"firstsecond"))


if __name__ == "__main__":
    unittest.main()
