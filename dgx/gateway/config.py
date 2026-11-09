from __future__ import annotations

import os
import stat
import math
from dataclasses import dataclass
from pathlib import Path


MODEL_ID = "microsoft/VibeVoice-ASR-Streaming-7B"
MODEL_REVISION = "60d858b518b4e19d404af3737f848fc185b30177"
SOURCE_COMMIT = "1541f590c7099820f10ea012f48d2399282df69f"
IMAGE = "nvcr.io/nvidia/pytorch@sha256:bbc2b67e2533edd63ff1496bb1ed00a00338cdc1478af6c1a0bf9f4b369977e7"
MAX_AUDIO_SAMPLES = 1_920_000
MAX_WS_MESSAGE_BYTES = 64 * 1024
MAX_START_MESSAGE_BYTES = 4096
MAX_NEW_TOKENS_PER_WINDOW = 256
TRANSPORT_RATE = 16_000
TRANSPORT_CHANNELS = 1


def read_restricted_secret(path: str | Path) -> str:
    """Read a root/current-user-owned credential without following symlinks."""
    secret_path = Path(path)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(secret_path, flags)
    with os.fdopen(descriptor, "r", encoding="utf-8") as secret_file:
        info = os.fstat(secret_file.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("credential path must be a regular file")
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError("credential file must be owned by the service user and mode 0600 or 0400")
        value = secret_file.read().strip()
    if not value or "\n" in value or "\r" in value:
        raise ValueError("credential file is empty or malformed")
    return value


def validate_tls_files(certificate_path: str | Path, private_key_path: str | Path) -> tuple[Path, Path]:
    """Require real readable TLS files and a service-owned private key."""
    paths = (Path(certificate_path), Path(private_key_path))
    infos = []
    for path in paths:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor, "rb") as file:
            info = os.fstat(file.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("TLS files must be regular files")
            infos.append(info)
    key_info = infos[1]
    if key_info.st_uid != os.geteuid() or stat.S_IMODE(key_info.st_mode) & 0o077:
        raise ValueError("TLS private key must be service-owned and mode 0600 or 0400")
    return paths


@dataclass(frozen=True)
class GatewaySettings:
    token: str
    model_id: str = MODEL_ID
    model_revision: str = MODEL_REVISION
    source_commit: str = SOURCE_COMMIT
    max_audio_samples: int = MAX_AUDIO_SAMPLES
    startup_timeout_seconds: float = 180.0
    session_timeout_seconds: float = 300.0
    message_timeout_seconds: float = 30.0
    drain_timeout_seconds: float = 5.0
    idle_unload_seconds: float = 60.0
    unload_poll_seconds: float = 1.0
    runtime_profile: str = "vibevoice"
    nemotron_cache_directory: str | None = None

    def __post_init__(self) -> None:
        if self.runtime_profile not in ("vibevoice", "nemotron3_5"):
            raise ValueError("unsupported gateway runtime profile")
        if self.runtime_profile == "nemotron3_5":
            from .nemotron import MODEL_ID as N_ID, MODEL_REVISION as N_REV, SOURCE_COMMIT as N_SOURCE
            if (self.model_id, self.model_revision, self.source_commit) != (N_ID, N_REV, N_SOURCE) or not self.nemotron_cache_directory:
                raise ValueError("explicit pinned Nemotron identity/cache required")
        if not self.token or "\n" in self.token or "\r" in self.token:
            raise ValueError("gateway bearer token is empty or malformed")
        if type(self.max_audio_samples) is not int or self.max_audio_samples <= 0:
            raise ValueError("MISTT_MAX_AUDIO_SAMPLES must be a positive integer")
        for name in ("startup_timeout_seconds", "session_timeout_seconds", "message_timeout_seconds",
                     "drain_timeout_seconds", "idle_unload_seconds", "unload_poll_seconds"):
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise ValueError(f"{name} must be a positive finite duration")

    @classmethod
    def from_env(cls) -> "GatewaySettings":
        token_path = os.environ.get("MISTT_TOKEN_FILE")
        if not token_path:
            raise ValueError("MISTT_TOKEN_FILE is required")
        try:
            profile = os.environ.get("MISTT_RUNTIME", "vibevoice")
            identity = {}
            if profile == "nemotron3_5":
                from .nemotron import MODEL_ID as N_ID, MODEL_REVISION as N_REV, SOURCE_COMMIT as N_SOURCE
                identity = dict(model_id=N_ID, model_revision=N_REV, source_commit=N_SOURCE)
            return cls(
                token=read_restricted_secret(token_path),
                runtime_profile=profile,
                nemotron_cache_directory=os.environ.get("MISTT_NEMOTRON_CACHE_DIR"),
                **identity,
                max_audio_samples=int(os.environ.get("MISTT_MAX_AUDIO_SAMPLES", MAX_AUDIO_SAMPLES)),
                startup_timeout_seconds=float(os.environ.get("MISTT_STARTUP_TIMEOUT_SECONDS", "180")),
                session_timeout_seconds=float(os.environ.get("MISTT_SESSION_TIMEOUT_SECONDS", "300")),
                message_timeout_seconds=float(os.environ.get("MISTT_MESSAGE_TIMEOUT_SECONDS", "30")),
                drain_timeout_seconds=float(os.environ.get("MISTT_DRAIN_TIMEOUT_SECONDS", "5")),
                idle_unload_seconds=float(os.environ.get("MISTT_IDLE_UNLOAD_SECONDS", "60")),
            )
        except (TypeError, ValueError, OSError) as error:
            raise ValueError("invalid gateway settings") from error
