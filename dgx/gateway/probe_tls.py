"""Probe the local HTTPS listener with the mounted certificate pinned and checked."""

from __future__ import annotations

import ipaddress
import os
import socket
import ssl
import sys


def probe_health(server_name: str, cert_file: str, port: int = 7870) -> None:
    # The deployment uses a private IP SAN. Restrict the value interpolated
    # into the HTTP Host header to an IP literal as well.
    server_name = str(ipaddress.ip_address(server_name))
    context = ssl.create_default_context(cafile=cert_file)
    context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    with socket.create_connection(("127.0.0.1", port), timeout=3) as raw:
        with context.wrap_socket(raw, server_hostname=server_name) as connection:
            connection.settimeout(3)
            connection.sendall(
                f"GET /mistt/healthz HTTP/1.1\r\nHost: {server_name}\r\n"
                "Connection: close\r\n\r\n".encode("ascii")
            )
            with connection.makefile("rb") as response:
                status_line = response.readline()
            status = status_line.split()
            if len(status) < 2 or status[1] != b"200":
                raise RuntimeError("local HTTPS health endpoint did not return 200")


def main() -> int:
    try:
        server_name = os.environ["MISTT_TLS_PROBE_SERVER_NAME"]
        cert_file = os.environ["MISTT_TLS_CERT_FILE"]
        probe_health(server_name, cert_file)
        return 0
    except Exception:
        return 1


if __name__ == "__main__":
    sys.exit(main())
