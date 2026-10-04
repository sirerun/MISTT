#!/usr/bin/env python3
"""Fail-closed release assembly. No command is run merely by importing this module."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

SPARKLE_VERSION = "2.10.0"
SPARKLE_TOOLS_SHA256 = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)
ROOT = Path(__file__).resolve().parents[1]


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"Required release input is missing: {name}")
    return value


def run(*args: str, **kwargs) -> str:
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=kwargs.pop("timeout", 1800), **kwargs).stdout.strip()


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_version(version: str, build: str) -> None:
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d{0,9}", build):
        raise ValueError("Release requires a numeric major.minor.patch and positive monotonic build")


def validate_repository(repo: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", repo):
        raise ValueError("Invalid owner/repository")


def validate_https(url: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError("Release/feed URL must be HTTPS without credentials or fragment")


def artifact_root(path: Path) -> Path:
    path = path.resolve()
    allowed = Path(required("RUNNER_TEMP")) if os.environ.get("GITHUB_ACTIONS") == "true" else Path("/Volumes/BuildOffload")
    if not path.is_relative_to(allowed.resolve()):
        raise ValueError("Artifacts and caches must be on the external SSD (or CI runner temporary volume)")
    path.mkdir(parents=True, exist_ok=True)
    return path


def generate_metadata(archive: Path, signature: str, version: str, build: str,
                      repo: str, output: Path) -> dict:
    validate_version(version, build)
    validate_repository(repo)
    try:
        decoded = base64.b64decode(signature, validate=True)
    except ValueError as exc:
        raise ValueError("Invalid Ed25519 archive signature") from exc
    if len(decoded) != 64 or not archive.is_file() or archive.stat().st_size == 0:
        raise ValueError("Require a nonempty archive and a 64-byte Ed25519 signature")
    filename = f"MISTT-{version}-arm64.zip"
    if archive.name != filename:
        raise ValueError("Archive name must match the release version/architecture")
    url = f"https://github.com/{repo}/releases/download/v{version}/{filename}"
    output.mkdir(parents=True, exist_ok=True)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "MISTT stable updates"
    ET.SubElement(channel, "link").text = f"https://github.com/{repo}"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"MISTT {version}"
    for key, value in [("version", build), ("shortVersionString", version),
                       ("minimumSystemVersion", "14.2.0"), ("hardwareRequirements", "arm64")]:
        ET.SubElement(item, f"{{{SPARKLE_NS}}}{key}").text = value
    ET.SubElement(item, "enclosure", {"url": url, "length": str(archive.stat().st_size),
                  "type": "application/octet-stream", f"{{{SPARKLE_NS}}}edSignature": signature})
    ET.ElementTree(rss).write(output / "appcast.xml", encoding="utf-8", xml_declaration=True)
    sha = digest(archive)
    cask = f'''cask "mistt" do
  version "{version}"
  sha256 "{sha}"
  url "{url}"
  name "MISTT"
  desc "Native paired microphone and app-audio transcription relay"
  homepage "https://github.com/{repo}"
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"
  app "MISTT.app"
  caveats "MISTT requires macOS 14.2 or later. User configuration is preserved on uninstall."
end
'''
    (output / "mistt.rb").write_text(cask)
    manifest = {"version": version, "build": build, "architecture": "arm64", "minimum_macos": "14.2",
                "archive": filename, "sha256": sha, "length": archive.stat().st_size,
                "archive_signature": signature, "download_url": url, "repository": repo}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def build(version: str, build_number: str, output: Path) -> Path:
    validate_version(version, build_number)
    output = artifact_root(output)
    identity = required("MISTT_SIGN_IDENTITY")
    if not identity.startswith("Developer ID Application:"):
        raise ValueError("Public release requires a Developer ID Application identity")
    key = required("MISTT_SPARKLE_PUBLIC_KEY")
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("Sparkle public key must be exactly 32 bytes")
    feed = required("MISTT_FEED_URL")
    validate_https(feed)
    app = output / "MISTT.app"
    if app.exists():
        raise ValueError("Refusing to overwrite an existing application artifact")
    cache = output / "cache"
    cache.mkdir(exist_ok=True)
    env = dict(os.environ, GOCACHE=str(cache / "go"), GOMODCACHE=str(cache / "gomod"),
               TMPDIR=str(cache), CLANG_MODULE_CACHE_PATH=str(cache / "clang"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(cache / "swift-module"), CGO_ENABLED="0", GOARCH="arm64", GOOS="darwin")
    relay = output / "mistt"
    run("go", "build", "-trimpath", "-o", str(relay), "./cmd/mistt", cwd=ROOT, env=env)
    scratch = cache / "swiftpm"
    run("swift", "build", "--package-path", str(ROOT / "desktop"), "--scratch-path", str(scratch),
        "--configuration", "release", "--arch", "arm64", "--jobs", "2", "--product", "MISTTDesktop", env=env)
    bins = Path(run("swift", "build", "--package-path", str(ROOT / "desktop"), "--scratch-path", str(scratch),
                    "--configuration", "release", "--arch", "arm64", "--show-bin-path", env=env))
    frameworks = list((scratch / "artifacts").rglob("Sparkle.framework"))
    frameworks = [p for p in frameworks if "macos" in str(p.parent).lower()]
    if len(frameworks) != 1:
        raise ValueError("Expected one resolved macOS Sparkle framework")
    for folder in ["MacOS", "Resources", "Frameworks"]:
        (app / "Contents" / folder).mkdir(parents=True, exist_ok=True)
    shutil.copy2(bins / "MISTTDesktop", app / "Contents/MacOS/MISTTDesktop")
    shutil.copy2(relay, app / "Contents/MacOS/mistt")
    for name in ["logo-3.svg", "logo-3-muted.svg"]:
        shutil.copy2(ROOT / "desktop/Resources" / name, app / "Contents/Resources" / name)
    framework = app / "Contents/Frameworks/Sparkle.framework"
    shutil.copytree(frameworks[0], framework, symlinks=True)
    info = plistlib.loads((ROOT / "desktop/Resources/Info.plist").read_bytes())
    info.update(CFBundleVersion=build_number, CFBundleShortVersionString=version,
                LSMinimumSystemVersion="14.2", SUFeedURL=feed, SUPublicEDKey=key,
                SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                SUEnableInstallerLauncherService=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    executable = app / "Contents/MacOS/MISTTDesktop"
    if "@executable_path/../Frameworks" not in run("otool", "-l", str(executable)):
        run("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable))
    entitlements = str(ROOT / "desktop/Resources/MISTT.entitlements")
    # Preserve Sparkle framework symlinks; sign deepest nested bundles before the app.
    bundles = sorted([p for p in framework.rglob("*") if p.suffix in (".xpc", ".app") and not p.is_symlink()],
                     key=lambda p: len(p.parts), reverse=True)
    for nested in bundles:
        run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(nested))
    autoupdate = framework / "Versions/B/Autoupdate"
    if autoupdate.exists():
        run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(autoupdate))
    run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(framework))
    for executable in [app / "Contents/MacOS/mistt", app / "Contents/MacOS/MISTTDesktop"]:
        run("lipo", "-verify_arch", "arm64", str(executable))
        run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(executable))
    run("codesign", "--force", "--options", "runtime", "--timestamp", "--entitlements", entitlements,
        "--sign", identity, str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    zip_path = output / f"MISTT-{version}-arm64.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(zip_path))
    keychain_args = ("--keychain", os.environ["MISTT_NOTARY_KEYCHAIN"]) if os.environ.get("MISTT_NOTARY_KEYCHAIN") else ()
    notarization = json.loads(run("xcrun", "notarytool", "submit", str(zip_path), "--keychain-profile", required("MISTT_NOTARY_PROFILE"),
        *keychain_args, "--wait", "--output-format", "json", timeout=3600))
    if notarization.get("status") != "Accepted":
        raise ValueError("Apple did not accept this exact release archive for notarization")
    run("xcrun", "stapler", "staple", str(app))
    run("xcrun", "stapler", "validate", str(app))
    run("spctl", "--assess", "--type", "execute", str(app))
    zip_path.unlink()  # This exact disposable artifact was created above in this invocation.
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(zip_path))
    sign_tool = required("MISTT_SPARKLE_SIGN_TOOL")
    key_args = ("--ed-key-file", required("MISTT_SPARKLE_KEY_FILE"))
    signature = run(sign_tool, *key_args, "-p", str(zip_path))
    run("swift", str(ROOT / "release/verify_sparkle.swift"), key, signature, str(zip_path))
    generate_metadata(zip_path, signature, version, build_number, required("MISTT_RELEASE_REPOSITORY"), output)
    run(sign_tool, *key_args, str(output / "appcast.xml"))
    run(sign_tool, *key_args, "--verify", str(output / "appcast.xml"))
    run(sign_tool, *key_args, "--verify", str(zip_path), signature)
    manifest_path = output / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest.update(notarization_id=notarization["id"], notarization_status="Accepted",
                    source_sha=run("git", "rev-parse", "HEAD", cwd=ROOT))
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    return zip_path


def publish(directory: Path) -> None:
    manifest = json.loads((directory / "manifest.json").read_text())
    validate_version(manifest["version"], manifest["build"])
    repo = manifest["repository"]
    validate_repository(repo)
    archive = directory / manifest["archive"]
    if archive.name != f'MISTT-{manifest["version"]}-arm64.zip' or digest(archive) != manifest["sha256"]:
        raise ValueError("Release artifact was modified or renamed")
    sign_tool = required("MISTT_SPARKLE_SIGN_TOOL")
    key_args = ("--ed-key-file", required("MISTT_SPARKLE_KEY_FILE"))
    run(sign_tool, *key_args, "--verify", str(archive), manifest["archive_signature"])
    run(sign_tool, *key_args, "--verify", str(directory / "appcast.xml"))
    # Reassess the actual downloadable bundle; metadata alone is not acceptance.
    with tempfile.TemporaryDirectory(prefix="mistt-reassess-", dir=directory) as temporary:
        run("ditto", "-x", "-k", str(archive), temporary)
        app = Path(temporary) / "MISTT.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != ("com.sirerun.mistt", manifest["version"], manifest["build"]):
            raise ValueError("Published metadata does not identify the assessed app")
        run("swift", str(ROOT / "release/verify_sparkle.swift"), info.get("SUPublicEDKey", ""),
            manifest["archive_signature"], str(archive))
        run("codesign", "--verify", "--deep", "--strict", str(app))
        run("xcrun", "stapler", "validate", str(app))
        run("spctl", "--assess", "--type", "execute", str(app))
    tap = required("MISTT_TAP_REPOSITORY")
    validate_repository(tap)
    tap_env = dict(os.environ, GH_TOKEN=required("MISTT_TAP_TOKEN"))
    permissions = json.loads(run("gh", "api", f"repos/{tap}", env=tap_env))
    if not permissions.get("permissions", {}).get("push"):
        raise ValueError("Tap publication credential lacks write access")
    existing = json.loads(run("gh", "api", f"repos/{repo}/releases?per_page=100"))
    stable = next((r for r in existing if not r["draft"] and not r["prerelease"]), None)
    if stable:
        old_asset = next((a for a in stable["assets"] if a["name"] == "manifest.json"), None)
        if old_asset is None:
            raise ValueError("Previous stable release has no build manifest; explicit migration required")
        previous = json.loads(run("gh", "api", old_asset["url"], "-H", "Accept: application/octet-stream"))
        if int(manifest["build"]) <= int(previous["build"]):
            raise ValueError("Release build number must increase over the previous stable release")
    # Existing tags/releases are never clobbered. Draft assets exist before stable feed visibility.
    tag = f'v{manifest["version"]}'
    if subprocess.run(["gh", "release", "view", tag, "--repo", repo], capture_output=True, timeout=30).returncode == 0:
        raise ValueError("Release already exists; refusing replacement")
    cask_endpoint = f"repos/{tap}/contents/Casks/mistt.rb"
    lookup = subprocess.run(["gh", "api", cask_endpoint], env=tap_env, text=True, capture_output=True, timeout=30)
    if lookup.returncode and "(HTTP 404)" not in lookup.stderr:
        raise ValueError("Cannot establish current tap revision")
    source_sha = manifest.get("source_sha", "")
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("Missing exact reviewed source revision")
    ref_endpoint = f"repos/{repo}/git/ref/tags/{tag}"
    tag_lookup = subprocess.run(["gh", "api", ref_endpoint], text=True, capture_output=True, timeout=30)
    if tag_lookup.returncode == 0:
        ref = json.loads(tag_lookup.stdout)["object"]
        if ref.get("type") != "commit" or ref.get("sha") != source_sha:
            raise ValueError("Existing release tag identifies a different source revision")
    elif "(HTTP 404)" in tag_lookup.stderr:
        run("gh", "api", f"repos/{repo}/git/refs", "--method", "POST",
            "-f", f"ref=refs/tags/{tag}", "-f", f"sha={source_sha}")
    else:
        raise ValueError("Cannot establish release tag ownership")
    run("gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--draft", "--prerelease", "--title", f"MISTT {manifest['version']}",
        "--notes", "Signed Apple Silicon release. Starts muted; requires macOS 14.2+.", str(archive),
        str(directory / "appcast.xml"), str(directory / "manifest.json"), str(directory / "mistt.rb"))
    # Archives become public before the cask references them; stable feed is exposed last.
    run("gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--prerelease=true", "--latest=false")
    payload = {"message": f"Update MISTT to {manifest['version']}",
               "content": base64.b64encode((directory / "mistt.rb").read_bytes()).decode()}
    if lookup.returncode == 0:
        payload["sha"] = json.loads(lookup.stdout)["sha"]
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", dir=directory) as request:
        json.dump(payload, request); request.flush()
        run("gh", "api", cask_endpoint, "--method", "PUT", "--input", request.name, env=tap_env)
    run("gh", "release", "edit", tag, "--repo", repo, "--prerelease=false", "--latest")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    make = sub.add_parser("build")
    make.add_argument("--version", required=True)
    make.add_argument("--build", required=True)
    make.add_argument("--output", type=Path, required=True)
    push = sub.add_parser("publish")
    push.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "build":
        print(build(args.version, args.build, args.output))
    else:
        publish(args.directory)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise SystemExit(f"Release failed: {exc}") from None
