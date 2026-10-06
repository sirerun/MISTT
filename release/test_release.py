import json
import re
import plistlib
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
        parent = os.environ.get("RUNNER_TEMP") if os.environ.get("GITHUB_ACTIONS") == "true" else (
            "/Volumes/BuildOffload/tmp" if sys.platform == "darwin" else None)
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "MISTT-0.1.0-arm64.zip"
        self.archive.write_bytes(b"synthetic metadata test only, not a release")
        self.signature = base64.b64encode(bytes(64)).decode()
    def generate(self, *args, source_repo="sirerun/MISTT", distribution_sha=None):
        repo = args[4]
        source_sha = "a" * 40
        target = distribution_sha or (source_sha if repo == source_repo else "b" * 40)
        with patch.object(tools, "source_repository", return_value=source_repo):
            return tools.generate_metadata(*args, source_sha=source_sha,
                                           distribution_commit_sha=target)

    def test_bundle_contains_declared_microphone_icon(self):
        app = self.root / "MISTT.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        tools.copy_app_resources(app)
        source = tools.ROOT / "desktop/Resources"
        info = plistlib.loads((source / "Info.plist").read_bytes())
        icon_name = info["CFBundleIconFile"]
        if not icon_name.endswith(".icns"):
            icon_name += ".icns"
        bundled = resources / icon_name
        self.assertEqual(bundled.read_bytes()[:4], b"icns")
        self.assertEqual(bundled.read_bytes(), (source / icon_name).read_bytes())

    def test_bundle_contains_licenses_for_pinned_dependencies(self):
        app = self.root / "MISTT.app"
        resources = app / "Contents/Resources"
        resources.mkdir(parents=True)
        tools.copy_app_resources(app)
        notices = (resources / "THIRD_PARTY_NOTICES.txt").read_bytes()
        self.assertEqual(notices, (tools.ROOT / "desktop/Resources/THIRD_PARTY_NOTICES.txt").read_bytes())
        self.assertEqual((resources / "MISTT-LICENSE.txt").read_bytes(), (tools.ROOT / "LICENSE").read_bytes())
        text = notices.decode()
        pins = re.findall(r"^\s*([\w./-]+)\s+(v\S+)", (tools.ROOT / "go.mod").read_text(), re.MULTILINE)
        self.assertTrue(pins)
        for module, version in pins:
            self.assertIn(f"{module}@{version}", text)
        package = json.loads((tools.ROOT / "desktop/Package.resolved").read_text())
        for pin in package["pins"]:
            self.assertEqual(pin["identity"], "sparkle")
            self.assertIn(f'Sparkle {pin["state"]["version"]} ', text)

    def test_release_source_rejects_dirty_or_changed_checkout(self):
        sha = "a" * 40
        for head, status in [("b" * 40, ""), (sha, " M desktop/source.swift"),
                             (sha, "?? desktop/injected.swift")]:
            with patch.object(tools, "run", side_effect=[head, status]) as execute:
                with self.assertRaises(ValueError):
                    tools.require_release_source(sha)
                self.assertLessEqual(execute.call_count, 2)

    def test_release_source_requires_land_reachability(self):
        sha = "a" * 40
        failure = subprocess.CalledProcessError(1, "git merge-base")
        with patch.object(tools, "run", side_effect=[sha, "", "", failure]) as execute:
            with self.assertRaises(subprocess.CalledProcessError):
                tools.require_release_source(sha)
            self.assertEqual(execute.call_args.args,
                             ("git", "merge-base", "--is-ancestor", sha, "origin/main"))

    def test_clean_release_source_is_rechecked_without_refetch(self):
        sha = "a" * 40
        with patch.object(tools, "run", side_effect=[sha, "", ""]) as execute:
            self.assertEqual(tools.require_release_source(sha, refresh=False), sha)
            self.assertEqual(execute.call_count, 3)

    def test_recovery_verification_rejects_modified_archive_before_commands(self):
        (self.root / "manifest.json").write_text(json.dumps({
            "version": "0.1.0", "build": "1", "repository": "sirerun/MISTT",
            "feed_url": tools.canonical_feed_url("sirerun/MISTT"),
            "source_sha": "a" * 40, "distribution_commit_sha": "a" * 40,
            "download_url": f"https://github.com/sirerun/MISTT/releases/download/v0.1.0/{self.archive.name}",
            "archive": self.archive.name, "sha256": "0" * 64,
        }))
        with patch.object(tools, "source_repository", return_value="sirerun/MISTT"), patch.object(tools, "run") as command:
            with self.assertRaisesRegex(ValueError, "modified or renamed"):
                tools.verify_artifacts(self.root)
            command.assert_not_called()

    def test_enclosure_and_cask_bind_same_artifact(self):
        manifest = self.generate(self.archive, self.signature, "0.1.0", "1", "sirerun/MISTT", self.root)
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
        self.assertEqual(manifest["feed_url"], "https://github.com/sirerun/MISTT/releases/latest/download/appcast.xml")
        self.assertEqual(manifest["source_sha"], "a" * 40)
        self.assertEqual(manifest["distribution_commit_sha"], "a" * 40)
        self.assertNotIn("zap", cask)

    def test_separate_public_distribution_keeps_source_provenance_distinct(self):
        manifest = self.generate(self.archive, self.signature, "0.1.0", "1",
                                 "public-owner/mistt-dist", self.root)
        self.assertEqual(manifest["source_sha"], "a" * 40)
        self.assertEqual(manifest["distribution_commit_sha"], "b" * 40)
        self.assertIn("https://github.com/public-owner/mistt-dist/releases/download/", manifest["download_url"])
        self.assertEqual(manifest["feed_url"], "https://github.com/public-owner/mistt-dist/releases/latest/download/appcast.xml")
        self.assertEqual(ET.parse(self.root / "appcast.xml").find("channel/link").text,
                         "https://github.com/public-owner/mistt-dist")
        self.assertIn('homepage "https://github.com/public-owner/mistt-dist"',
                      (self.root / "mistt.rb").read_text())

    def test_manifest_feed_relabel_is_rejected_before_signature_commands(self):
        manifest = self.generate(self.archive, self.signature, "0.1.0", "1",
                                 "public-owner/mistt-dist", self.root)
        manifest["feed_url"] = "https://github.com/private-owner/MISTT/releases/latest/download/appcast.xml"
        (self.root / "manifest.json").write_text(json.dumps(manifest))
        with patch.object(tools, "source_repository", return_value="sirerun/MISTT"), \
             patch.object(tools, "run") as command:
            with self.assertRaisesRegex(ValueError, "feed URL"):
                tools.verify_artifacts(self.root)
            command.assert_not_called()

    def test_signed_bundle_feed_must_match_selected_public_repository(self):
        with self.assertRaisesRegex(ValueError, "Embedded update feed"):
            tools.validate_embedded_feed(
                {"SUFeedURL": "https://github.com/private-owner/MISTT/releases/latest/download/appcast.xml"},
                "https://github.com/public-owner/mistt-dist/releases/latest/download/appcast.xml")
        tools.validate_embedded_feed(
            {"SUFeedURL": "https://github.com/public-owner/mistt-dist/releases/latest/download/appcast.xml"},
            "https://github.com/public-owner/mistt-dist/releases/latest/download/appcast.xml")

    def test_distribution_sha_defaults_only_for_same_repository(self):
        source = "a" * 40
        self.assertEqual(tools.resolve_distribution_commit_sha("sirerun/MISTT", source,
                                                                 "sirerun/MISTT"), source)
        with self.assertRaisesRegex(ValueError, "requires MISTT_DISTRIBUTION_COMMIT_SHA"):
            tools.resolve_distribution_commit_sha("public-owner/mistt-dist", source,
                                                   "sirerun/MISTT")
        with self.assertRaisesRegex(ValueError, "selected separately"):
            tools.resolve_distribution_commit_sha("public-owner/mistt-dist", source,
                                                   "sirerun/MISTT", source)

    def test_public_target_preflight_requires_public_writable_existing_reachable_commit(self):
        sha = "b" * 40
        cases = [
            ([json.dumps({"visibility": "private", "permissions": {"push": True}})], "public and writable"),
            ([json.dumps({"visibility": "public", "permissions": {"push": False}})], "public and writable"),
            ([json.dumps({"visibility": "public", "permissions": {"push": True}, "default_branch": "main"}),
              json.dumps({"sha": "c" * 40})], "does not exist"),
            ([json.dumps({"visibility": "public", "permissions": {"push": True}, "default_branch": "main"}),
              json.dumps({"sha": sha}),
              json.dumps({"status": "behind", "ahead_by": 1, "merge_base_commit": {"sha": "a" * 40}})],
             "reachable from the public default branch"),
        ]
        for outputs, expected in cases:
            with self.subTest(expected=expected), patch.object(tools, "run", side_effect=outputs) as command:
                with self.assertRaisesRegex(ValueError, expected):
                    tools.validate_distribution_target("public-owner/mistt-dist", sha)
                self.assertTrue(all(call.args[0:2] == ("gh", "api") for call in command.call_args_list))

    def test_public_target_ancestor_of_default_branch_is_reachable(self):
        sha = "b" * 40
        outputs = [json.dumps({"visibility": "public", "permissions": {"push": True},
                               "default_branch": "main"}),
                   json.dumps({"sha": sha}),
                   json.dumps({"status": "behind", "ahead_by": 0,
                               "merge_base_commit": {"sha": sha}})]
        with patch.object(tools, "run", side_effect=outputs) as command:
            tools.validate_distribution_target("public-owner/mistt-dist", sha)
        self.assertEqual(command.call_count, 3)

    def test_existing_wrong_distribution_tag_fails_without_mutation(self):
        result = subprocess.CompletedProcess(args=[], returncode=0,
                                             stdout=json.dumps({"object": {"type": "commit", "sha": "a" * 40}}),
                                             stderr="")
        with patch.object(tools.subprocess, "run", return_value=result), patch.object(tools, "run") as mutate:
            with self.assertRaisesRegex(ValueError, "different distribution commit"):
                tools.establish_distribution_tag("public-owner/mistt-dist", "v0.1.0", "b" * 40)
            mutate.assert_not_called()

    def test_release_lookup_requires_explicit_404_for_absence(self):
        for status_text in ("(HTTP 401)", "(HTTP 403)", "(HTTP 429)", "(HTTP 500)", "network timeout"):
            with self.subTest(status=status_text), \
                 patch.object(tools.subprocess, "run", return_value=subprocess.CompletedProcess(
                     args=[], returncode=1, stdout="", stderr=status_text)):
                with self.assertRaisesRegex(ValueError, "Cannot establish release absence"):
                    tools.require_release_absent("public-owner/mistt-dist", "v0.1.0")
        result = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="gh: Not Found (HTTP 404)")
        with patch.object(tools.subprocess, "run", return_value=result):
            self.assertIsNone(tools.require_release_absent("public-owner/mistt-dist", "v0.1.0"))
        existing = subprocess.CompletedProcess(args=[], returncode=0, stdout="{}", stderr="")
        with patch.object(tools.subprocess, "run", return_value=existing):
            with self.assertRaisesRegex(ValueError, "already exists"):
                tools.require_release_absent("public-owner/mistt-dist", "v0.1.0")

    def test_publish_release_lookup_failure_stops_before_tag_or_mutation(self):
        manifest = {"source_sha": "a" * 40, "distribution_commit_sha": "b" * 40,
                    "repository": "public-owner/mistt-dist", "version": "0.1.0",
                    "build": "1", "archive": self.archive.name}
        api_outputs = [json.dumps({"permissions": {"push": True}}), "[]"]
        failed_lookup = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="(HTTP 403)")
        with patch.object(tools, "artifact_root", return_value=self.root), \
             patch.object(tools, "verify_artifacts", return_value=manifest), \
             patch.object(tools, "require_release_source", return_value="a" * 40), \
             patch.object(tools, "validate_distribution_target"), \
             patch.object(tools, "required", side_effect=lambda key: {
                 "MISTT_TAP_REPOSITORY": "public-owner/homebrew-tap", "MISTT_TAP_TOKEN": "test-token"
             }[key]), \
             patch.object(tools, "run", side_effect=api_outputs) as command, \
             patch.object(tools.subprocess, "run", return_value=failed_lookup), \
             patch.object(tools, "establish_distribution_tag") as tag:
            with self.assertRaisesRegex(ValueError, "Cannot establish release absence"):
                tools.publish(self.root)
            tag.assert_not_called()
            self.assertFalse(any("POST" in call.args for call in command.call_args_list))

    def test_new_tag_targets_only_preexisting_distribution_commit(self):
        result = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="(HTTP 404)")
        with patch.object(tools.subprocess, "run", return_value=result), patch.object(tools, "run") as mutate:
            tools.establish_distribution_tag("public-owner/mistt-dist", "v0.1.0", "b" * 40)
            self.assertIn("sha=b" + "b" * 39, mutate.call_args.args)

    def test_publish_stops_at_distribution_preflight_before_any_mutation(self):
        manifest = {"source_sha": "a" * 40, "distribution_commit_sha": "b" * 40,
                    "repository": "public-owner/mistt-dist", "version": "0.1.0"}
        with patch.object(tools, "artifact_root", return_value=self.root), \
             patch.object(tools, "verify_artifacts", return_value=manifest), \
             patch.object(tools, "require_release_source", return_value="a" * 40), \
             patch.object(tools, "validate_distribution_target", side_effect=ValueError("private target")), \
             patch.object(tools, "run") as command:
            with self.assertRaisesRegex(ValueError, "private target"):
                tools.publish(self.root)
            command.assert_not_called()

    def test_rejects_invalid_signature_or_archive_identity(self):
        for signature in ["invalid", base64.b64encode(bytes(32)).decode()]:
            with self.assertRaises(ValueError):
                self.generate(self.archive, signature, "0.1.0", "1", "sirerun/MISTT", self.root)
        with self.assertRaises(ValueError):
            self.generate(self.archive, self.signature, "0.2.0", "1", "sirerun/MISTT", self.root)

    def test_rejects_interpolated_shell_or_repository_values(self):
        for version, build, repo in [("0.1.0;evil", "1", "sirerun/MISTT"), ("0.1.0", "0", "sirerun/MISTT"),
                                    ("0.1.0", "1", "sirerun/MISTT?token=secret")]:
            with self.assertRaises(ValueError):
                self.generate(self.archive, self.signature, version, build, repo, self.root)

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
