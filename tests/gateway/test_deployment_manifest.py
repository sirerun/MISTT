from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "dgx" / "gateway" / "pod.json.in"
VALUES = {
    "MISTT_GATEWAY_POD_NAME": "mistt-gateway-owner-qual",
    "MISTT_GATEWAY_SOURCE_SHA": "0123456789abcdef0123456789abcdef01234567",
    "MISTT_GATEWAY_SOURCE_VOLUME": "mistt-gateway-source-owner-qual",
    "MISTT_GATEWAY_CACHE_VOLUME": "mistt-gateway-cache-owner-qual",
    "MISTT_GATEWAY_CREDENTIALS_VOLUME": "mistt-gateway-credentials-owner-qual",
}


def render_template() -> dict:
    rendered = TEMPLATE.read_text(encoding="utf-8")
    for name, value in VALUES.items():
        rendered = rendered.replace("${" + name + "}", value)
    if "${" in rendered:
        raise AssertionError("unrendered placeholder in gateway Pod template")
    return json.loads(rendered)


class DeploymentManifestTests(unittest.TestCase):
    def test_renders_pinned_owner_volumes_without_unscoped_host_port(self) -> None:
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
        self.assertEqual(container["ports"], [
            {"name": "https", "containerPort": 7870, "protocol": "TCP"}
        ])
        self.assertTrue(all("hostPort" not in port and "hostIP" not in port
                            for port in container["ports"]))

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


if __name__ == "__main__":
    unittest.main()
