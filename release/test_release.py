import base64
import importlib.util
import tempfile
import os
from pathlib import Path
import unittest
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


if __name__ == "__main__":
    unittest.main()
