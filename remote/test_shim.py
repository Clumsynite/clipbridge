"""Tests for remote/clipbridge-shim. Runs the shim as a subprocess (via xclip/xsel/pbpaste
symlinks in a temp dir) against a fake ClipBridge server speaking the real protocol.

    python3 -m unittest discover -s remote -p 'test_*.py'
"""
import hashlib
import hmac
import http.server
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
SHIM = os.path.join(HERE, "clipbridge-shim")
KEY = bytes(range(32))
PNG = bytes.fromhex("89504e470d0a1a0a") + b"fake-png-body" * 10
TEXT = "héllo ✓".encode()


def sign_resp(nonce, status, body, key=KEY):
    msg = "resp|%s|%d|%s" % (nonce, status, hashlib.sha256(body).hexdigest())
    return hmac.new(key, msg.encode(), hashlib.sha256).hexdigest()


class FakeServer:
    """mode: ok | empty | badsig | unsigned | hang | slow | closer"""

    def __init__(self, mode="ok"):
        self.mode = mode
        self.requests = []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_GET(self):
                u = urllib.parse.urlparse(self.path)
                q = dict(urllib.parse.parse_qsl(u.query))
                outer.requests.append((u.path, q, dict(self.headers)))
                msg = "req|%s|%s|%s|%s" % (u.path, q.get("host"), q.get("ts"), q.get("nonce"))
                good = hmac.compare_digest(
                    hmac.new(KEY, msg.encode(), hashlib.sha256).hexdigest(), self.headers.get("X-CB-Auth", ""))
                nonce = q.get("nonce", "")
                if outer.mode == "hang":
                    time.sleep(30)
                    return
                if not good:
                    status, body = 401, b""
                elif outer.mode == "empty":
                    status, body = 204, b""
                elif u.path == "/v1/image":
                    status, body = 200, (b"\x00" * (10 * 1024 * 1024) if outer.mode == "slow" else PNG)
                elif u.path == "/v1/text":
                    status, body = 200, TEXT
                elif u.path == "/v1/targets":
                    status, body = 200, b"image/png\ntext/plain\nUTF8_STRING\nSTRING\n"
                else:
                    status, body = 404, b""
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                if outer.mode == "badsig":
                    self.send_header("X-CB-Sig", "0" * 64)
                elif outer.mode != "unsigned":
                    self.send_header("X-CB-Sig", sign_resp(nonce, status, body))
                self.send_header("Connection", "close")
                self.end_headers()
                if outer.mode == "slow":
                    for i in range(0, len(body), 1024 * 1024):
                        self.wfile.write(body[i:i + 1024 * 1024])
                        self.wfile.flush()
                        time.sleep(0.2)
                else:
                    self.wfile.write(body)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class ShimTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.bin = os.path.join(self.tmp.name, "bin")
        self.realbin = os.path.join(self.tmp.name, "real")
        os.makedirs(self.bin)
        os.makedirs(self.realbin)
        shim = os.path.join(self.bin, "clipbridge-shim")
        with open(SHIM, "rb") as src, open(shim, "wb") as dst:
            dst.write(src.read())
        os.chmod(shim, 0o755)
        for name in ("xclip", "xsel", "pbpaste"):
            os.symlink("clipbridge-shim", os.path.join(self.bin, name))
        self.server = None
        self.cfg = os.path.join(self.tmp.name, "config.json")

    def tearDown(self):
        if self.server:
            self.server.close()
        self.tmp.cleanup()

    def serve(self, mode="ok"):
        self.server = FakeServer(mode)
        self.write_cfg(self.server.port)

    def write_cfg(self, port):
        with open(self.cfg, "w") as f:
            json.dump({"host": "selftest", "port": port, "token_hex": KEY.hex()}, f)

    def fake_real(self, name):
        p = os.path.join(self.realbin, name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\necho REAL-%s \"$@\"\n" % name)
        os.chmod(p, 0o755)

    def run_shim(self, name, *args, real=True, timeout=30):
        path = self.bin + (os.pathsep + self.realbin if real else "") + os.pathsep + "/usr/bin:/bin"
        env = {"PATH": path, "CLIPBRIDGE_CONFIG": self.cfg, "HOME": self.tmp.name}
        return subprocess.run([name, *args], env=env, capture_output=True, timeout=timeout)

    def free_port(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    # --- happy paths

    def test_image(self):
        self.serve()
        r = self.run_shim("xclip", "-selection", "clipboard", "-t", "image/png", "-o")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, PNG)
        self.assertEqual(self.server.requests[0][0], "/v1/image")

    def test_any_image_type_maps_to_png(self):
        self.serve()
        r = self.run_shim("xclip", "-selection", "clipboard", "-t", "image/bmp", "-o")
        self.assertEqual(r.stdout, PNG)

    def test_targets(self):
        self.serve()
        r = self.run_shim("xclip", "-selection", "clipboard", "-t", "TARGETS", "-o")
        self.assertEqual(r.returncode, 0)
        self.assertIn(b"image/png", r.stdout)

    def test_text_variants_exact_bytes(self):
        self.serve()
        cases = [
            ("xclip", "-o", "-selection", "clipboard"),
            ("xclip", "-sel", "c", "-o", "-t", "UTF8_STRING"),
            ("xclip", "-selection", "clipboard", "-t", "text/plain", "-o"),
            ("xsel", "-b", "-o"),
            ("xsel", "-bo"),
            ("xsel", "--clipboard", "--output"),
            ("pbpaste",),
            ("pbpaste", "-Prefer", "txt"),
        ]
        for c in cases:
            r = self.run_shim(*c)
            self.assertEqual((r.returncode, r.stdout), (0, TEXT), c)

    # --- no content / verification

    def test_204_exits_1_silently(self):
        self.serve("empty")
        r = self.run_shim("xclip", "-selection", "clipboard", "-t", "image/png", "-o")
        self.assertEqual((r.returncode, r.stdout), (1, b""))

    def test_bad_signature(self):
        self.serve("badsig")
        r = self.run_shim("pbpaste")
        self.assertEqual((r.returncode, r.stdout), (1, b""))

    def test_squatter_unsigned_png_rejected(self):
        self.serve("unsigned")
        self.fake_real("xclip")
        r = self.run_shim("xclip", "-selection", "clipboard", "-t", "image/png", "-o")
        self.assertEqual((r.returncode, r.stdout), (1, b""))

    def test_wrong_token_rejected(self):
        self.serve()
        with open(self.cfg, "w") as f:
            json.dump({"host": "selftest", "port": self.server.port, "token_hex": "11" * 32}, f)
        r = self.run_shim("pbpaste")
        self.assertEqual((r.returncode, r.stdout), (1, b""))

    # --- unreachable / timeouts

    def test_refused_falls_through_to_real(self):
        self.write_cfg(self.free_port())
        self.fake_real("xclip")
        r = self.run_shim("xclip", "-selection", "clipboard", "-t", "image/png", "-o")
        self.assertEqual(r.returncode, 0)
        self.assertTrue(r.stdout.startswith(b"REAL-xclip"))

    def test_refused_without_real_exits_1(self):
        self.write_cfg(self.free_port())
        r = self.run_shim("xsel", "-b", "-o", real=False)
        self.assertEqual((r.returncode, r.stdout), (1, b""))

    def test_missing_config_falls_through(self):
        self.fake_real("pbpaste")
        r = self.run_shim("pbpaste")
        self.assertTrue(r.stdout.startswith(b"REAL-pbpaste"))

    def test_hung_server_gives_up_within_deadline(self):
        self.serve("hang")
        t = time.monotonic()
        r = self.run_shim("pbpaste", timeout=40)
        self.assertLess(time.monotonic() - t, 21.5)
        self.assertEqual((r.returncode, r.stdout), (1, b""))

    def test_slow_10mb_body_ok(self):
        self.serve("slow")
        r = self.run_shim("xclip", "-selection", "clipboard", "-t", "image/png", "-o")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(len(r.stdout), 10 * 1024 * 1024)

    # --- passthrough and argv handling

    def test_passthrough_cases(self):
        self.serve()
        for name in ("xclip", "xsel"):
            self.fake_real(name)
        cases = [
            ("xclip", "-i"),
            ("xclip", "-selection", "clipboard", "-i"),
            ("xclip", "-o"),  # primary selection
            ("xclip", "-selection", "primary", "-o"),
            ("xsel", "-i"),
            ("xsel", "-p", "-o"),
            ("xsel", "-o"),
        ]
        for c in cases:
            r = self.run_shim(*c)
            self.assertTrue(r.stdout.startswith(b"REAL-" + c[0].encode()), c)
        self.assertEqual(self.server.requests, [])

    def test_unknown_target_exits_1(self):
        self.serve()
        r = self.run_shim("xclip", "-selection", "clipboard", "-t", "foo/bar", "-o")
        self.assertEqual((r.returncode, r.stdout), (1, b""))
        self.assertEqual(self.server.requests, [])

    def test_does_not_exec_itself(self):
        # Only the shim is on PATH as xclip: passthrough must not loop.
        r = self.run_shim("xclip", "-i", real=False, timeout=10)
        self.assertEqual(r.returncode, 1)

    # --- secrets

    def test_token_not_in_process_args(self):
        self.serve("hang")
        path = self.bin + os.pathsep + "/usr/bin:/bin"
        env = {"PATH": path, "CLIPBRIDGE_CONFIG": self.cfg, "HOME": self.tmp.name}
        p = subprocess.Popen(["pbpaste"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(1.0)
            ps = subprocess.run(["ps", "-ww", "-o", "args", "-p", str(p.pid)], capture_output=True, text=True).stdout
            self.assertIn("pbpaste", ps)
            self.assertNotIn(KEY.hex(), ps)
            # Request MAC and the request line also never carry the token.
            for _, q, headers in self.server.requests:
                self.assertNotIn(KEY.hex(), json.dumps([q, headers]))
        finally:
            p.kill()
            p.communicate()


if __name__ == "__main__":
    unittest.main()
