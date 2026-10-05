from __future__ import annotations

import ssl
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from dgx.gateway.probe_tls import probe_health


def issue_leaf(directory: Path, stem: str, ca_cert: Path, ca_key: Path) -> tuple[Path, Path]:
    key = directory / f"{stem}.key"
    request = directory / f"{stem}.csr"
    cert = directory / f"{stem}.crt"
    extensions = directory / f"{stem}.ext"
    extensions.write_text(
        "subjectAltName=IP:192.0.2.10\n"
        "basicConstraints=critical,CA:FALSE\n"
        "keyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\n",
        encoding="ascii",
    )
    subprocess.run(
        ["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(key), "-out", str(request), "-subj", f"/CN={stem}"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["openssl", "x509", "-req", "-in", str(request), "-CA", str(ca_cert),
         "-CAkey", str(ca_key), "-CAcreateserial", "-out", str(cert),
         "-days", "1", "-extfile", str(extensions)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return cert, key


class ProbeTLSVerificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.ca_cert = self.directory / "test-ca.crt"
        self.ca_key = self.directory / "test-ca.key"
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(self.ca_key), "-out", str(self.ca_cert), "-days", "1",
             "-subj", "/CN=MISTT Probe Test CA",
             "-addext", "basicConstraints=critical,CA:TRUE",
             "-addext", "keyUsage=critical,keyCertSign,cRLSign"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.cert, self.key = issue_leaf(
            self.directory, "server", self.ca_cert, self.ca_key
        )
        self.other_ca_cert = self.directory / "other-ca.crt"
        self.other_ca_key = self.directory / "other-ca.key"
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(self.other_ca_key), "-out", str(self.other_ca_cert),
             "-days", "1", "-subj", "/CN=Other Probe Test CA",
             "-addext", "basicConstraints=critical,CA:TRUE",
             "-addext", "keyUsage=critical,keyCertSign,cRLSign"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.other_cert, self.other_key = issue_leaf(
            self.directory, "other-server", self.other_ca_cert, self.other_ca_key
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def serve(self, cert: Path, key: Path) -> tuple[HTTPServer, threading.Thread]:
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                status = 200 if self.path == "/mistt/healthz" else 404
                self.send_response(status)
                self.end_headers()
                self.wfile.write(b"ok")

            def log_message(self, *_args: object) -> None:
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=str(cert), keyfile=str(key))
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        return server, thread

    def test_probe_trusts_exact_mounted_leaf_and_verifies_ip_san(self) -> None:
        server, thread = self.serve(self.cert, self.key)
        try:
            probe_health("192.0.2.10", str(self.cert), server.server_port)
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_probe_rejects_wrong_ip_san(self) -> None:
        server, thread = self.serve(self.cert, self.key)
        try:
            with self.assertRaises(ssl.SSLCertVerificationError):
                probe_health("192.0.2.11", str(self.cert), server.server_port)
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_probe_rejects_a_different_leaf_even_with_matching_ip_san(self) -> None:
        server, thread = self.serve(self.other_cert, self.other_key)
        try:
            with self.assertRaises(ssl.SSLCertVerificationError):
                probe_health("192.0.2.10", str(self.cert), server.server_port)
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()
