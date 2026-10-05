import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("setup_signing", Path(__file__).with_name("setup_signing.py"))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)
spec = importlib.util.spec_from_file_location("release_contract", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class SigningEnvironmentTest(unittest.TestCase):
    def test_setup_exports_required_explicit_signing_keychain(self):
        with tempfile.TemporaryDirectory(dir="/Volumes/BuildOffload/tmp") as directory:
            path = Path(directory) / "environment"
            keychain = Path(directory) / "job.keychain-db"
            setup.write_environment(path, keychain, "private-key", "sign_update")
            environment = dict(line.split("=", 1) for line in path.read_text().splitlines())
            with patch.dict("os.environ", environment, clear=True):
                self.assertEqual(release.required("MISTT_SIGN_KEYCHAIN"), str(keychain))
                self.assertEqual(release.required("MISTT_NOTARY_KEYCHAIN"), str(keychain))
