"""Verify and stage the pinned upstream VibeVoice source without clobbering cache."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tarfile
import tempfile
from typing import BinaryIO


SOURCE_COMMIT = "1541f590c7099820f10ea012f48d2399282df69f"
ARCHIVE_SHA256 = "cbd51f4539a709cb2ddc1f92406e69278af00f064ee420f1eda28f8b385a18e0"
ARCHIVE_ROOT = f"VibeVoice-{SOURCE_COMMIT}"
ARCHIVE_NAME = f"vibevoice-{SOURCE_COMMIT}-{ARCHIVE_SHA256}.tar.gz"
CHUNK_SIZE = 1024 * 1024


class SourceIntegrityError(RuntimeError):
    """The archive or an existing staged tree does not match the pinned source."""


def _hash_stream(stream: BinaryIO) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    while True:
        block = stream.read(CHUNK_SIZE)
        if not block:
            break
        digest.update(block)
        size += len(block)
    return digest.hexdigest(), size


def _archive_digest(path: Path) -> str:
    with path.open("rb") as archive:
        return _hash_stream(archive)[0]


def _safe_relative(member_name: str, root_name: str) -> PurePosixPath:
    if not member_name or "\\" in member_name:
        raise SourceIntegrityError("unsafe archive path")
    raw_parts = member_name.split("/")
    if any(part in ("", ".", "..") for part in raw_parts):
        raise SourceIntegrityError("unsafe archive path")
    path = PurePosixPath(member_name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise SourceIntegrityError("unsafe archive path")
    if not path.parts or path.parts[0] != root_name:
        raise SourceIntegrityError("unexpected archive root")
    relative = PurePosixPath(*path.parts[1:])
    if not relative.parts:
        return relative
    if any(part in ("", ".", "..") for part in relative.parts):
        raise SourceIntegrityError("unsafe relative path")
    return relative


def _canonical_mode(mode: int, *, is_dir: bool) -> int:
    if is_dir:
        return 0o755
    return 0o755 if mode & 0o111 else 0o644


def _member_path(member: tarfile.TarInfo, root_name: str) -> PurePosixPath:
    name = member.name
    if member.isdir() and name.endswith("/"):
        name = name[:-1]
    return _safe_relative(name, root_name)


def inventory_archive(
    archive_path: Path,
    *,
    expected_sha256: str | None = None,
    root_name: str | None = None,
) -> dict[str, object]:
    """Validate archive bytes and return a complete canonical source inventory."""
    expected_sha256 = expected_sha256 or ARCHIVE_SHA256
    root_name = root_name or ARCHIVE_ROOT
    actual_sha = _archive_digest(archive_path)
    if actual_sha != expected_sha256:
        raise SourceIntegrityError("upstream archive digest mismatch")

    files: dict[str, dict[str, object]] = {}
    directories: dict[str, int] = {}
    seen_members: set[str] = set()
    seen_root = False
    try:
        with tarfile.open(archive_path, "r:gz") as tar:
            for member in tar:
                relative = _member_path(member, root_name)
                if not relative.parts:
                    if seen_root:
                        raise SourceIntegrityError("duplicate archive root")
                    seen_root = True
                    if not member.isdir():
                        raise SourceIntegrityError("archive root is not a directory")
                    directories["."] = _canonical_mode(member.mode, is_dir=True)
                    continue
                name = relative.as_posix()
                if name in seen_members:
                    raise SourceIntegrityError("duplicate archive member")
                seen_members.add(name)
                if member.isdir():
                    if name in files:
                        raise SourceIntegrityError("archive path changes member type")
                    directories[name] = _canonical_mode(member.mode, is_dir=True)
                    continue
                if not member.isfile():
                    raise SourceIntegrityError("unsupported archive member type")
                if name in files or name in directories:
                    raise SourceIntegrityError("duplicate archive member")
                if any(parent.as_posix() in files for parent in relative.parents if parent.parts):
                    raise SourceIntegrityError("archive path descends through a file")
                source = tar.extractfile(member)
                if source is None:
                    raise SourceIntegrityError("archive member has no data")
                digest, size = _hash_stream(source)
                if size != member.size:
                    raise SourceIntegrityError("archive member size mismatch")
                files[name] = {
                    "size": size,
                    "sha256": digest,
                    "mode": _canonical_mode(member.mode, is_dir=False),
                }
                parent = relative.parent
                while parent.parts:
                    directories.setdefault(parent.as_posix(), 0o755)
                    parent = parent.parent
    except (OSError, tarfile.TarError) as exc:
        raise SourceIntegrityError("invalid upstream archive") from exc

    if not files or not directories:
        raise SourceIntegrityError("upstream source inventory is empty")
    return {
        "archive_sha256": actual_sha,
        "files": files,
        "directories": directories,
    }


def _tree_inventory(source: Path) -> dict[str, object]:
    files: dict[str, dict[str, object]] = {}
    directories: dict[str, int] = {
        ".": stat.S_IMODE(source.stat(follow_symlinks=False).st_mode),
    }
    if source.is_symlink() or not source.is_dir():
        raise SourceIntegrityError("source path is not a regular directory")
    for current, dirnames, filenames in os.walk(source, topdown=True, followlinks=False):
        current_path = Path(current)
        rel_dir = current_path.relative_to(source)
        for dirname in list(dirnames):
            path = current_path / dirname
            if path.is_symlink() or not path.is_dir():
                raise SourceIntegrityError("source tree contains a non-directory entry")
            rel = path.relative_to(source).as_posix()
            directories[rel] = stat.S_IMODE(path.stat(follow_symlinks=False).st_mode)
        for filename in filenames:
            path = current_path / filename
            if path.is_symlink() or not path.is_file():
                raise SourceIntegrityError("source tree contains a non-regular file")
            relative = path.relative_to(source).as_posix()
            mode = stat.S_IMODE(path.stat(follow_symlinks=False).st_mode)
            with path.open("rb") as stream:
                digest, size = _hash_stream(stream)
            files[relative] = {"size": size, "sha256": digest, "mode": mode}
    return {"files": files, "directories": directories}


def verify_source_tree(source: Path, expected: dict[str, object]) -> None:
    actual = _tree_inventory(source)
    if actual["files"] != expected["files"] or actual["directories"] != expected["directories"]:
        raise SourceIntegrityError("existing upstream source tree differs from pinned inventory")


def verify_import_source(source: Path) -> None:
    """Require imports to resolve from the verified source, never a legacy edit."""
    spec = importlib.util.find_spec("vibevoice")
    if spec is None or spec.origin is None:
        raise SourceIntegrityError("upstream package import origin is unavailable")
    origin = Path(spec.origin).resolve()
    expected = source.resolve()
    try:
        origin.relative_to(expected)
    except ValueError as exc:
        raise SourceIntegrityError("upstream package import resolved outside verified source") from exc


def _extract_verified(archive_path: Path, staging: Path, expected: dict[str, object]) -> None:
    expected_files = expected["files"]
    assert isinstance(expected_files, dict)
    with tarfile.open(archive_path, "r:gz") as tar:
        for member in tar:
            relative = _member_path(member, ARCHIVE_ROOT)
            if not relative.parts:
                continue
            destination = staging.joinpath(*relative.parts)
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True, mode=0o755)
                os.chmod(destination, 0o755)
                continue
            record = expected_files.get(relative.as_posix())
            if not isinstance(record, dict) or not member.isfile():
                raise SourceIntegrityError("archive changed during extraction")
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            source = tar.extractfile(member)
            if source is None:
                raise SourceIntegrityError("archive member has no data")
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            fd = os.open(destination, flags, int(record["mode"]))
            digest = hashlib.sha256()
            size = 0
            try:
                with os.fdopen(fd, "wb") as output:
                    while True:
                        block = source.read(CHUNK_SIZE)
                        if not block:
                            break
                        output.write(block)
                        digest.update(block)
                        size += len(block)
            except BaseException:
                raise
            if size != record["size"] or digest.hexdigest() != record["sha256"]:
                raise SourceIntegrityError("archive member changed during extraction")
            os.chmod(destination, int(record["mode"]))
    directories = expected["directories"]
    assert isinstance(directories, dict)
    for relative, mode in sorted(directories.items(), key=lambda item: item[0].count("/"), reverse=True):
        os.chmod(staging if relative == "." else staging / relative, int(mode))


def _install_archive(downloaded: Path, archive_path: Path) -> None:
    if not downloaded.is_file() or downloaded.is_symlink():
        raise SourceIntegrityError("downloaded archive is not a regular file")
    if _archive_digest(downloaded) != ARCHIVE_SHA256:
        raise SourceIntegrityError("downloaded upstream archive digest mismatch")
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    if archive_path.exists() or archive_path.is_symlink():
        if archive_path.is_symlink() or not archive_path.is_file() or _archive_digest(archive_path) != ARCHIVE_SHA256:
            raise SourceIntegrityError("existing pinned archive is invalid; preserving it")
        return
    try:
        os.link(downloaded, archive_path)
    except FileExistsError:
        if archive_path.is_symlink() or not archive_path.is_file() or _archive_digest(archive_path) != ARCHIVE_SHA256:
            raise SourceIntegrityError("concurrent pinned archive is invalid; preserving it")
    os.chmod(archive_path, 0o644)


def ensure_source(source: Path, archive_path: Path, downloaded: Path | None = None) -> None:
    """Ensure exact verified source exists; never replace an existing archive/tree."""
    if archive_path.exists():
        if archive_path.is_symlink() or not archive_path.is_file() or _archive_digest(archive_path) != ARCHIVE_SHA256:
            raise SourceIntegrityError("existing pinned archive is invalid; preserving it")
    elif downloaded is not None:
        _install_archive(downloaded, archive_path)
    else:
        raise SourceIntegrityError("pinned source archive is missing")

    expected = inventory_archive(archive_path)
    if source.exists() or source.is_symlink():
        verify_source_tree(source, expected)
        return

    source.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{source.name}.stage-", dir=source.parent))
    try:
        _extract_verified(archive_path, staging, expected)
        verify_source_tree(staging, expected)
        try:
            os.rename(staging, source)
        except FileExistsError:
            verify_source_tree(source, expected)
        verify_source_tree(source, expected)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--downloaded", type=Path)
    args = parser.parse_args()
    try:
        ensure_source(args.source, args.archive, args.downloaded)
    except SourceIntegrityError as exc:
        parser.exit(1, f"upstream source verification failed: {exc}\n")
    print(json.dumps({"source_commit": SOURCE_COMMIT, "archive_sha256": ARCHIVE_SHA256, "status": "verified"}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
