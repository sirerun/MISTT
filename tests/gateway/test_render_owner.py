from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import unittest

from dgx.gateway import render_owner


SOURCE_SHA = "29a9f8b9" + "a" * 32
CONFIG = {
    "MISTT_GATEWAY_POD_NAME": "mistt-gateway-29a9f8b9-20261005",
    "MISTT_GATEWAY_SOURCE_SHA": SOURCE_SHA,
    "MISTT_GATEWAY_SOURCE_VOLUME": "mistt-gateway-source-29a9f8b",
    "MISTT_GATEWAY_CACHE_VOLUME": "mistt-gateway-cache-29a9f8b",
    "MISTT_GATEWAY_CREDENTIALS_VOLUME": "mistt-gateway-credentials-29a9f8b",
    "MISTT_GATEWAY_HOST_PORT": 18772,
    "MISTT_GATEWAY_TLS_SERVER_NAME": "192.168.86.250",
}


class OwnerRenderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.template = (Path(render_owner.__file__).with_name("pod.json.in")).read_text()

    def test_renders_only_pinned_cpu8_manifest_with_configurable_owner_values(self) -> None:
        rendered, values = render_owner.render_manifest(self.template, CONFIG)
        pod = json.loads(rendered)
        self.assertEqual(values["MISTT_GATEWAY_HOST_PORT"], 18772)
        self.assertEqual(pod["metadata"]["name"], CONFIG["MISTT_GATEWAY_POD_NAME"])
        self.assertEqual(pod["metadata"]["labels"]["gateway-source-sha"], SOURCE_SHA)
        container = pod["spec"]["containers"][0]
        self.assertEqual(container["resources"]["limits"], {
            "memory": "48Gi", "cpu": "8", "nvidia.com/gpu": "1",
        })
        self.assertEqual(container["ports"][0]["hostPort"], 18772)
        self.assertNotIn("hostIP", container["ports"][0])
        self.assertEqual(pod["spec"]["restartPolicy"], "Never")
        self.assertEqual(
            {row["name"]: row.get("readOnly", False) for row in container["volumeMounts"]},
            {"gateway": True, "cache": False, "credentials": True},
        )

    def test_rejects_unknown_keys_and_wrong_json_types(self) -> None:
        for key, value in (
            ("MISTT_BEARER_TOKEN", "must-never-be-an-input"),
            ("MISTT_GATEWAY_EXTRA", "unexpected"),
        ):
            config = dict(CONFIG)
            config[key] = value
            with self.subTest(key=key), self.assertRaises(render_owner.OwnerRenderError):
                render_owner.render_manifest(self.template, config)
        for key, value in (
            ("MISTT_GATEWAY_HOST_PORT", True),
            ("MISTT_GATEWAY_HOST_PORT", "18772"),
            ("MISTT_GATEWAY_POD_NAME", 7),
        ):
            config = dict(CONFIG)
            config[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(render_owner.OwnerRenderError):
                render_owner.render_manifest(self.template, config)

    def test_rejects_unsafe_volume_names_and_bad_pins(self) -> None:
        for key, value in (
            ("MISTT_GATEWAY_SOURCE_VOLUME", "source."),
            ("MISTT_GATEWAY_CACHE_VOLUME", "../cache"),
            ("MISTT_GATEWAY_SOURCE_SHA", "not-a-sha"),
            ("MISTT_GATEWAY_TLS_SERVER_NAME", "gateway.local"),
        ):
            config = dict(CONFIG)
            config[key] = value
            with self.subTest(key=key), self.assertRaises(render_owner.OwnerRenderError):
                render_owner.render_manifest(self.template, config)

    def test_rejects_mutated_template_and_resource_contract(self) -> None:
        with self.assertRaises(render_owner.OwnerRenderError):
            render_owner.render_manifest(self.template.replace("${MISTT_GATEWAY_HOST_PORT}", "1"), CONFIG)
        mutated = self.template.replace('"cpu": "8"', '"cpu": "4"')
        with self.assertRaises(render_owner.OwnerRenderError):
            render_owner.render_manifest(mutated, CONFIG)

    def test_secure_render_creates_private_files_once_and_receipt_claims_no_submission(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as root:
            directory = Path(root) / "owner"
            directory.mkdir(mode=0o700)
            os.chmod(directory, 0o700)
            config_file = directory / "input.json"
            config_file.write_text(json.dumps(CONFIG), encoding="utf-8")
            os.chmod(config_file, 0o600)
            output, receipt = directory / "pod.json", directory / "receipt.json"

            render_owner.render_to_files(config_file, output, receipt)

            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
            result = json.loads(receipt.read_text())
            self.assertEqual(result["manifest_sha256"], hashlib.sha256(output.read_bytes()).hexdigest())
            self.assertFalse(result["submitted_to_spark"])
            self.assertFalse(result["credential_values_included"])
            with self.assertRaises(render_owner.OwnerRenderError):
                render_owner.render_to_files(config_file, output, receipt)

    def test_rejects_insecure_config_permissions_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"]) as root:
            directory = Path(root) / "owner"
            directory.mkdir(mode=0o700)
            os.chmod(directory, 0o700)
            source = directory / "input.json"
            source.write_text(json.dumps(CONFIG), encoding="utf-8")
            os.chmod(source, 0o644)
            with self.assertRaises(render_owner.OwnerRenderError):
                render_owner.read_private_config(source)
            os.chmod(source, 0o600)
            link = directory / "link.json"
            link.symlink_to(source)
            with self.assertRaises(render_owner.OwnerRenderError):
                render_owner.read_private_config(link)


if __name__ == "__main__":
    unittest.main()
