import json
import base64
import importlib.util
import tempfile
import os
from pathlib import Path
import unittest
from unittest.mock import patch
import subprocess
import sys
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("release_tools", Path(__file__).with_name("release.py"))
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class ReleaseMetadataTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ["RUNNER_TEMP"] if os.environ.get("GITHUB_ACTIONS") == "true" else "/Volumes/BuildOffload/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "MISTT-0.1.0-arm64.zip"
        self.archive.write_bytes(b"synthetic metadata test only, not a release")
        self.signature = base64.b64encode(bytes(64)).decode()

    def test_recovery_verification_rejects_modified_archive_before_commands(self):
        (self.root / "manifest.json").write_text(json.dumps({
            "version": "0.1.0", "build": "1", "repository": "sirerun/MISTT",
            "archive": self.archive.name, "sha256": "0" * 64,
        }))
        with patch.object(tools, "run") as command:
            with self.assertRaisesRegex(ValueError, "modified or renamed"):
                tools.verify_artifacts(self.root)
            command.assert_not_called()

    def test_enclosure_and_cask_bind_same_artifact(self):
        manifest = tools.generate_metadata(self.archive, self.signature, "0.1.0", "1", "sirerun/MISTT", self.root)
        enclosure = ET.parse(self.root / "appcast.xml").find("channel/item/enclosure")
        self.assertEqual(int(enclosure.attrib["length"]), self.archive.stat().st_size)
        self.assertEqual(enclosure.attrib["url"], manifest["download_url"])
        self.assertEqual(enclosure.attrib[f"{{{tools.SPARKLE_NS}}}edSignature"], self.signature)
        cask = (self.root / "mistt.rb").read_text()
        self.assertIn(manifest["sha256"], cask)
        self.assertIn(manifest["download_url"], cask)
        self.assertIn("auto_updates true", cask)
        self.assertIn('depends_on macos: "14.2"', cask)
        self.assertEqual(manifest["minimum_macos"], "14.2")
        self.assertNotIn("zap", cask)

    def test_rejects_invalid_signature_or_archive_identity(self):
        for signature in ["invalid", base64.b64encode(bytes(32)).decode()]:
            with self.assertRaises(ValueError):
                tools.generate_metadata(self.archive, signature, "0.1.0", "1", "sirerun/MISTT", self.root)
        with self.assertRaises(ValueError):
            tools.generate_metadata(self.archive, self.signature, "0.2.0", "1", "sirerun/MISTT", self.root)

    def test_rejects_interpolated_shell_or_repository_values(self):
        for version, build, repo in [("0.1.0;evil", "1", "sirerun/MISTT"), ("0.1.0", "0", "sirerun/MISTT"),
                                    ("0.1.0", "1", "sirerun/MISTT?token=secret")]:
            with self.assertRaises(ValueError):
                tools.generate_metadata(self.archive, self.signature, version, build, repo, self.root)

    def test_feed_credentials_are_rejected(self):
        for url in ["http://example.test/feed.xml", "https://token@example.test/feed.xml", "https://example.test/feed.xml#frag"]:
            with self.assertRaises(ValueError):
                tools.validate_https(url)

    def test_lost_lease_never_builds_or_releases_another_claim(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false", "MISTT_CLAIM_SCRIPT": "claim-helper", "CLAIM_REMOTE": "lease-store"}), \
             patch.object(tools.os, "getloadavg", return_value=(0, 0, 0)), \
             patch.object(tools, "run", side_effect=["load", "LOST: R-build-lease another-owner"]) as execute:
            with self.assertRaises(ValueError):
                tools.run_build("go", "build", "./cmd/mistt")
            self.assertEqual(execute.call_count, 2)

    def test_failed_build_releases_only_acquired_lease(self):
        lease = "a" * 40
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false", "MISTT_CLAIM_SCRIPT": "claim-helper", "CLAIM_REMOTE": "lease-store"}), \
             patch.object(tools.os, "getloadavg", return_value=(0, 0, 0)), \
             patch.object(tools, "run", side_effect=["load", f"WON: R-build-lease {lease}", subprocess.CalledProcessError(1, "go"), "released"]) as execute:
            with self.assertRaises(subprocess.CalledProcessError):
                tools.run_build("go", "build", "./cmd/mistt")
            self.assertEqual(execute.call_args.args, ("claim-helper", "release", "R-build-lease", lease))

    def test_credential_failure_does_not_render_secret_arguments(self):
        signing_spec = importlib.util.spec_from_file_location("signing_setup", Path(__file__).with_name("setup_signing.py"))
        signing = importlib.util.module_from_spec(signing_spec)
        with patch.dict(sys.modules, {"release": tools}):
            signing_spec.loader.exec_module(signing)
        secret = "synthetic-private-password"
        failure = subprocess.CalledProcessError(1, ["security", "import", "-P", secret], stderr=secret)
        with patch.object(signing.subprocess, "run", side_effect=failure):
            with self.assertRaises(SystemExit) as stopped:
                signing.run("security", "import", "-P", secret)
        self.assertNotIn(secret, str(stopped.exception))
        self.assertTrue(stopped.exception.__suppress_context__)


if __name__ == "__main__":
    unittest.main()
