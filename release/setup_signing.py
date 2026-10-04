#!/usr/bin/env python3
"""Configure a job-scoped keychain from explicit CI secrets; never print their values."""
import base64
import hashlib
import os
from pathlib import Path
import secrets
import subprocess
import tarfile
import urllib.request

from release import SPARKLE_TOOLS_SHA256, SPARKLE_VERSION, required


def run(*args):
    try:
        subprocess.run(args, check=True, capture_output=True, timeout=120)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        # Arguments include certificate/keychain passwords. Never let Python's
        # default exception rendering print the command or captured diagnostics.
        raise SystemExit("Credential setup command failed; secret arguments and diagnostics are suppressed.") from None


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("This helper is CI-only. Local release uses an existing qualified keychain profile.")
    temporary = Path(required("RUNNER_TEMP"))
    secrets_dir = temporary / "mistt-signing"
    secrets_dir.mkdir(mode=0o700, exist_ok=False)
    password = secrets.token_urlsafe(32)
    print(f"::add-mask::{password}")
    keychain = secrets_dir / "release.keychain-db"
    certificate = secrets_dir / "developer-id.p12"
    certificate.write_bytes(base64.b64decode(required("MISTT_CERTIFICATE_BASE64"), validate=True))
    certificate.chmod(0o600)
    run("security", "create-keychain", "-p", password, str(keychain))
    (secrets_dir / "owned-keychain").write_text(required("GITHUB_RUN_ID") + ":" + required("GITHUB_RUN_ATTEMPT"))
    run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
    run("security", "unlock-keychain", "-p", password, str(keychain))
    run("security", "import", str(certificate), "-k", str(keychain), "-P", required("MISTT_CERTIFICATE_PASSWORD"), "-T", "/usr/bin/codesign")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, str(keychain))
    # The CI runner is disposable; preserve its existing search list alongside this job keychain.
    prior = subprocess.run(["security", "list-keychains", "-d", "user"], check=True, text=True, capture_output=True).stdout
    import shlex
    run("security", "list-keychains", "-d", "user", "-s", str(keychain), *shlex.split(prior))
    notary_key = secrets_dir / "AuthKey.p8"
    notary_key.write_text(required("MISTT_NOTARY_KEY")); notary_key.chmod(0o600)
    run("xcrun", "notarytool", "store-credentials", "MISTT-Release", "--keychain", str(keychain),
        "--key", str(notary_key), "--key-id", required("MISTT_NOTARY_KEY_ID"), "--issuer", required("MISTT_NOTARY_ISSUER"))
    sparkle_key = secrets_dir / "sparkle.key"
    sparkle_key.write_text(required("MISTT_SPARKLE_PRIVATE_KEY")); sparkle_key.chmod(0o600)
    archive = temporary / f"Sparkle-{SPARKLE_VERSION}.tar.xz"
    urllib.request.urlretrieve(f"https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/{archive.name}", archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SPARKLE_TOOLS_SHA256:
        raise SystemExit("Pinned Sparkle tool archive checksum mismatch")
    tools = temporary / "mistt-sparkle-tools"
    tools.mkdir(exist_ok=False)
    with tarfile.open(archive) as tar:
        tar.extractall(tools, filter="data")
    sign_tools = [p for p in tools.rglob("sign_update") if p.is_file() and os.access(p, os.X_OK)]
    if len(sign_tools) != 1:
        raise SystemExit("Pinned tool bundle has an ambiguous sign_update executable")
    with Path(required("GITHUB_ENV")).open("a") as env:
        env.write(f"MISTT_NOTARY_PROFILE=MISTT-Release\nMISTT_NOTARY_KEYCHAIN={keychain}\n")
        env.write(f"MISTT_SPARKLE_KEY_FILE={sparkle_key}\nMISTT_SPARKLE_SIGN_TOOL={sign_tools[0]}\n")


if __name__ == "__main__":
    main()
