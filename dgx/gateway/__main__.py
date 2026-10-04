from __future__ import annotations

import os
from pathlib import Path

import uvicorn

from .app import create_app
from .config import GatewaySettings, validate_tls_files


def main() -> None:
    settings = GatewaySettings.from_env()
    cert_path = os.environ.get("MISTT_TLS_CERT_FILE")
    key_path = os.environ.get("MISTT_TLS_KEY_FILE")
    if not cert_path or not key_path:
        raise SystemExit("MISTT_TLS_CERT_FILE and MISTT_TLS_KEY_FILE must point to provisioned TLS files")
    try:
        cert_path, key_path = validate_tls_files(cert_path, key_path)
    except (OSError, ValueError) as error:
        raise SystemExit("provisioned TLS certificate/key files are invalid") from error
    host = os.environ.get("MISTT_LISTEN_HOST", "0.0.0.0")
    port = int(os.environ.get("MISTT_LISTEN_PORT", "7870"))
    uvicorn.run(
        create_app(settings),
        host=host,
        port=port,
        ssl_certfile=str(cert_path),
        ssl_keyfile=str(key_path),
        access_log=False,
        log_level=os.environ.get("MISTT_LOG_LEVEL", "info"),
        ws_max_size=64 * 1024,
        ws_ping_interval=20.0,
        ws_ping_timeout=20.0,
    )


if __name__ == "__main__":
    main()
