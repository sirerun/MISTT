"""Snapshot a read-only projected Secret into private regular files."""
import os
from pathlib import Path
import stat
import tempfile


def snapshot_credentials(source: Path, parent: Path) -> Path:
    source = source.resolve(strict=True)
    destination = Path(tempfile.mkdtemp(prefix="mistt-credentials-", dir=parent))
    try:
        for name in ("bearer", "tls.crt", "tls.key"):
            target = (source / name).resolve(strict=True)
            target.relative_to(source)
            descriptor = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            with os.fdopen(descriptor, "rb") as handle:
                info = os.fstat(handle.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                    raise ValueError("projected credential must be service-owned and regular")
                if stat.S_IMODE(info.st_mode) & 0o077:
                    raise ValueError("projected credential must be mode 0400 or 0600")
                value = handle.read()
                if not value:
                    raise ValueError("projected credential is empty")
            with (destination / name).open("xb") as handle:
                os.fchmod(handle.fileno(), 0o600)
                handle.write(value)
        return destination
    except BaseException:
        for child in destination.iterdir():
            child.unlink()
        destination.rmdir()
        raise


if __name__ == "__main__":
    import sys
    print(snapshot_credentials(Path(sys.argv[1]), Path(sys.argv[2])))
