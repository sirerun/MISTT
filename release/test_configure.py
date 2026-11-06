import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

class CaptureProfileTests(unittest.TestCase):
 def test_profiles_are_explicit_private_and_no_overwrite(self):
  profiles = {
   "tiktok": ("com.tiktok.livestudio.desktop", "Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"),
   "zoom": ("us.zoom.xos", "Contents/MacOS/zoom.us"),
   "zoom-cpthost": ("us.zoom.xos", "Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost"),
   "copilot-practice": ("run.david.evidence-copilot.development", "Contents/MacOS/EvidenceOverlay"),
  }
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory);token=root/"token";token.write_text("synthetic");token.chmod(0o600)
   for profile,(bundle,executable) in profiles.items():
    output=root/(profile+".json")
    command=[sys.executable,str(Path(__file__).with_name("configure.py")),"--profile",profile,"--endpoint","wss://fixture.invalid/mistt/v1/stream","--token-file",str(token),"--output",str(output)]
    result=subprocess.run(command,capture_output=True,timeout=10)
    self.assertEqual(result.returncode,0,result.stderr)
    data=json.loads(output.read_text());self.assertEqual(data["MISTT_TARGET_BUNDLE_ID"],bundle)
    self.assertEqual(data["MISTT_HELPER_EXECUTABLES"],executable)
    self.assertEqual(output.stat().st_mode&0o777,0o600)
    self.assertNotIn("synthetic",output.read_text())
    self.assertNotEqual(subprocess.run(command,capture_output=True,timeout=10).returncode,0)
    unsafe=command[:-2]+["--helper-executable","Contents/MacOS/Other","--output",str(root/(profile+"-unsafe.json"))]
    self.assertNotEqual(subprocess.run(unsafe,capture_output=True,timeout=10).returncode,0)
    self.assertFalse((root/(profile+"-unsafe.json")).exists())

if __name__=="__main__":unittest.main()
