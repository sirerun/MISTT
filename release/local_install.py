#!/usr/bin/env python3
"""Explicit reversible cask operations; default is read-only inspection."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

BUNDLE_ID = "com.sirerun.mistt"


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=300).stdout


def inspect(cask, app):
    info = json.loads(run("brew", "info", "--cask", "--json=v2", cask))
    entries = info.get("casks", [])
    if len(entries) != 1:
        raise ValueError("Expected exactly the requested cask")
    installed = bool(entries[0].get("installed"))
    result = {"cask": cask, "cask_installed": installed, "app_present": app.is_dir()}
    if app.is_dir():
        plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        result.update(bundle_id=plist.get("CFBundleIdentifier"), version=plist.get("CFBundleShortVersionString"),
                      build=plist.get("CFBundleVersion"))
        if result["bundle_id"] != BUNDLE_ID:
            raise ValueError("Existing application path belongs to another bundle; refusing changes")
    return result


def require_signed_app(app, team):
    if not re.fullmatch(r"[A-Z0-9]{10}", team or ""):
        raise ValueError("Provide the qualified owner Developer ID team with --team-id")
    requirement = ('anchor apple generic and identifier "com.sirerun.mistt" and '
                   'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
                   f'certificate leaf[subject.OU] = "{team}"')
    run("codesign", "--verify", "--deep", "--strict", "-R", requirement, str(app))
    run("xcrun", "stapler", "validate", str(app))
    run("spctl", "--assess", "--type", "execute", str(app))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["inspect", "install", "launch", "reinstall", "uninstall"], nargs="?", default="inspect")
    parser.add_argument("--cask", default="sirerun/tap/mistt")
    parser.add_argument("--app", type=Path, default=Path("/Applications/MISTT.app"))
    parser.add_argument("--team-id")
    args = parser.parse_args()
    if args.app != Path("/Applications/MISTT.app") or args.app.is_symlink():
        raise ValueError("This qualified cask workflow requires the direct /Applications/MISTT.app path")
    if not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/mistt", args.cask):
        raise ValueError("Use an explicit owner-controlled mistt cask")
    state = inspect(args.cask, args.app)
    if args.operation == "inspect":
        print(json.dumps(state, indent=2)); return
    if state["app_present"] and not state["cask_installed"]:
        raise ValueError("Existing app is not managed by the requested cask; refusing replacement")
    if args.operation == "install":
        if not state["cask_installed"]:
            run("brew", "install", "--cask", args.cask)
        require_signed_app(args.app, args.team_id)
    elif args.operation == "launch":
        if not state["cask_installed"]:
            raise ValueError("Install the requested cask before launch")
        require_signed_app(args.app, args.team_id)
        run("open", str(args.app))
    else:
        if not state["cask_installed"]:
            raise ValueError("Requested cask is not installed; no operation performed")
        require_signed_app(args.app, args.team_id)
        # Normal quit uses the app's closure/drain path. Never force-kill unrelated processes.
        subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to quit'],
                       check=True, capture_output=True, text=True, timeout=30)
        still_running = subprocess.run(["pgrep", "-f", re.escape(str(args.app / "Contents/MacOS"))],
                                       capture_output=True, text=True, timeout=10)
        if still_running.returncode == 0:
            raise ValueError("App remains running; stop/closure must be qualified before cask replacement")
        run("brew", args.operation, "--cask", args.cask)
    print(json.dumps(inspect(args.cask, args.app), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise SystemExit(f"Local cask operation stopped: {exc}") from None
