import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from serve import read_token


class PackagingTests(unittest.TestCase):
    def render(self, *extra):
        return subprocess.run([sys.executable, str(Path(__file__).with_name("spark_manifest.py")),
            "--name", "mistt-stt-test", "--image", "registry/stt@sha256:" + "a" * 64,
            "--models-host-path", "/srv/mistt/model-v1", "--token-directory", "/srv/mistt/credential-v1",
            "--host-port", "18793", "--private-ingress-ready", *extra], capture_output=True, text=True)

    def test_manifest_has_bounded_cpu_and_read_only_narrow_mounts(self):
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        pod = json.loads(result.stdout)
        self.assertEqual(pod["apiVersion"], "v1")
        self.assertEqual(pod["kind"], "Pod")
        self.assertEqual(pod["spec"]["restartPolicy"], "Always")
        service = pod["spec"]["containers"][0]
        self.assertEqual(service["resources"]["limits"], {"cpu": "2", "memory": "4Gi"})
        self.assertTrue(all(m["readOnly"] for m in service["volumeMounts"]))
        self.assertNotIn("env", service)
        self.assertEqual(service["livenessProbe"]["exec"]["command"], ["python", "/app/healthcheck.py"])
        self.assertEqual(service["livenessProbe"]["timeoutSeconds"], 3)
        self.assertEqual(service["ports"][0]["hostPort"], 18793)

    def test_rejects_mutable_images_and_broad_or_overlapping_mounts(self):
        for extra in [("--image", "registry/stt:latest"), ("--models-host-path", "/srv"),
                      ("--token-directory", "/srv/mistt/model-v1/secrets"),
                      ("--models-host-path", "/srv/mistt/../cache"), ("--host-port", "80")]:
            with self.subTest(extra=extra):
                self.assertNotEqual(self.render(*extra).returncode, 0)

    def test_container_packages_local_speech_gate(self):
        root = Path(__file__).parent
        copy_lines = [line.split() for line in (root / "Containerfile").read_text().splitlines()
                      if line.startswith("COPY ")]
        copied = {source for line in copy_lines for source in line[1:-1]}
        self.assertIn("speech_gate.py", copied)
        for source in copied:
            self.assertTrue((root / source).is_file(), source)

    def test_token_rejects_exposure_symlink_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory) / "token"
            token.write_text("a" * 32)
            token.chmod(0o600)
            self.assertEqual(read_token(token), "a" * 32)
            token.chmod(0o644)
            with self.assertRaises(ValueError): read_token(token)
            token.chmod(0o600)
            link = Path(directory) / "link"
            link.symlink_to(token)
            with self.assertRaises(OSError): read_token(link)
            token.write_text("a" * 4097)
            with self.assertRaises(ValueError): read_token(token)


if __name__ == "__main__":
    unittest.main()
