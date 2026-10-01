#!/usr/bin/env python3
"""Signed request to the local ClipBridge app.

Usage: dev-request.py --host <alias> {targets|image|text} [-o FILE] [--port 7788]
Prints "<status> <sha256-of-body> <bytes>" after verifying the response signature.
Exit 0 on a verified 200, 1 otherwise. The token is read from
~/.config/clipbridge/hosts/<alias>.json, never from argv.
"""
import argparse
import hashlib
import hmac
import http.client
import json
import os
import secrets
import sys
import time

p = argparse.ArgumentParser()
p.add_argument("--host", required=True)
p.add_argument("--port", type=int, default=7788)
p.add_argument("kind", choices=["targets", "image", "text"])
p.add_argument("-o", dest="out")
a = p.parse_args()

cfg = json.load(open(os.path.expanduser(f"~/.config/clipbridge/hosts/{a.host}.json")))
key = bytes.fromhex(cfg["token_hex"])
path = f"/v1/{a.kind}"
ts, nonce = str(int(time.time())), secrets.token_hex(16)
mac = hmac.new(key, f"req|{path}|{a.host}|{ts}|{nonce}".encode(), hashlib.sha256).hexdigest()
c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=10)
c.request("GET", f"{path}?host={a.host}&ts={ts}&nonce={nonce}", headers={"X-CB-Auth": mac})
r = c.getresponse()
body = r.read()
digest = hashlib.sha256(body).hexdigest()
want = hmac.new(key, f"resp|{nonce}|{r.status}|{digest}".encode(), hashlib.sha256).hexdigest()
if not hmac.compare_digest(want, r.getheader("X-CB-Sig") or ""):
    print(f"{r.status} bad-signature")
    sys.exit(1)
print(r.status, digest, len(body))
if a.out and r.status == 200:
    open(a.out, "wb").write(body)
sys.exit(0 if r.status == 200 else 1)
