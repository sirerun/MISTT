#!/usr/bin/env python3
"""Create owner-controlled desktop configuration; never read or store token contents."""
import argparse
import json
import os
from pathlib import Path
import stat
import urllib.parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--ca-file", type=Path)
    parser.add_argument("--target-bundle-id", default="com.tiktok.livestudio.desktop")
    parser.add_argument("--helper-executable", type=Path, action="append", required=True)
    parser.add_argument("--microphone-device", default="default")
    parser.add_argument("--output", type=Path, default=Path.home() / "Library/Application Support/MISTT/config.json")
    args = parser.parse_args()
    url = urllib.parse.urlsplit(args.endpoint)
    if url.scheme != "wss" or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError("Endpoint must be a credential-free wss URL")
    token = args.token_file
    if not token.is_absolute() or token.is_symlink():
        raise ValueError("Token path must be an absolute direct regular file")
    info = token.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid != os.getuid():
        raise ValueError("Token file must be owner-owned and inaccessible to other users")
    if any(not p.is_absolute() or "," in str(p) for p in args.helper_executable):
        raise ValueError("Each helper executable must be a separate absolute path")
    if not args.target_bundle_id or any(c.isspace() for c in args.target_bundle_id):
        raise ValueError("Provide the qualified target bundle identifier")
    values = {
        "MISTT_DGX_ENDPOINT": args.endpoint,
        "MISTT_TOKEN_FILE": str(token),
        "MISTT_TARGET_BUNDLE_ID": args.target_bundle_id,
        "MISTT_HELPER_EXECUTABLES": ",".join(map(str, args.helper_executable)),
        "MISTT_MICROPHONE_DEVICE": args.microphone_device,
        "MISTT_LANGUAGE": "en",
    }
    if args.ca_file:
        if not args.ca_file.is_absolute() or not args.ca_file.is_file():
            raise ValueError("CA file must be an absolute existing file")
        values["MISTT_CA_FILE"] = str(args.ca_file)
    args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Exclusive creation preserves any prior configuration, including symlinks.
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(values, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    print("Desktop configuration created. Existing configuration was not replaced.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as exc:
        raise SystemExit(f"Configuration stopped: {exc}") from None
