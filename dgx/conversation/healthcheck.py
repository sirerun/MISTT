#!/usr/bin/env python3
"""Authenticated local health probe; emits no credential or response body."""
import json
import urllib.request
from serve import read_token

request = urllib.request.Request("http://127.0.0.1:8793/healthz",
    headers={"Authorization": "Bearer " + read_token("/run/mistt/token")})
with urllib.request.urlopen(request, timeout=2) as response:
    if not json.load(response).get("ready"):
        raise SystemExit(1)
