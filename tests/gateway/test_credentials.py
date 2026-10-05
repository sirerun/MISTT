import os
from pathlib import Path
import tempfile
import sys
import unittest

from dgx.gateway.config import read_restricted_secret, validate_tls_files
from dgx.gateway.credentials import snapshot_credentials


class ProjectedCredentialsTest(unittest.TestCase):
    def setUp(self):
        parent = "/Volumes/BuildOffload/tmp" if sys.platform == "darwin" else None
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.mount = self.root / "secret"
        data = self.mount / "..revision"
        data.mkdir(parents=True)
        (self.mount / "..data").symlink_to("..revision")
        for name in ("bearer", "tls.crt", "tls.key"):
            path = data / name
            path.write_text("test-credential")
            path.chmod(0o400)
            (self.mount / name).symlink_to("..data/" + name)

    def test_projected_layout_becomes_private_regular_snapshot(self):
        with self.assertRaises(OSError):
            read_restricted_secret(self.mount / "bearer")
        output = snapshot_credentials(self.mount, self.root)
        self.assertEqual(read_restricted_secret(output / "bearer"), "test-credential")
        validate_tls_files(output / "tls.crt", output / "tls.key")
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        for path in output.iterdir():
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_target_outside_mount_is_rejected_and_snapshot_removed(self):
        outside = self.root / "outside"
        outside.write_text("not-a-mounted-credential")
        outside.chmod(0o400)
        bearer = self.mount / "bearer"
        bearer.unlink()
        bearer.symlink_to(outside)
        with self.assertRaises(ValueError):
            snapshot_credentials(self.mount, self.root)
        self.assertEqual(list(self.root.glob("mistt-credentials-*")), [])

    def test_readable_by_other_users_is_rejected(self):
        (self.mount / "..revision" / "tls.key").chmod(0o644)
        with self.assertRaises(ValueError):
            snapshot_credentials(self.mount, self.root)
        self.assertEqual(list(self.root.glob("mistt-credentials-*")), [])
