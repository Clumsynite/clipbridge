#!/usr/bin/env python3
"""Render docs/doctor.svg: a terminal-style picture of `clipbridge doctor` for the README.

Uses made-up hosts (devbox) so no real infrastructure appears. Rerun after changing doctor's output:
    python3 scripts/make-doctor-svg.py
"""
import html
import os

LINES = [
    ("cmd", "$ clipbridge doctor devbox"),
    ("head", "mac"),
    ("ok", "ClipBridge running"),
    ("ok", "listening on 127.0.0.1:7788 only"),
    ("ok", "signed local request (image)"),
    ("head", "ssh config"),
    ("ok", "remoteforward [127.0.0.1]:23187 [127.0.0.1]:7788"),
    ("ok", "controlmaster auto"),
    ("ok", "controlpath ~/.ssh/cm/%C"),
    ("ok", "setenv LC_CLIPBRIDGE=<session key>"),
    ("ok", "~/.config/clipbridge/ssh_config is 0600"),
    ("head", "remote devbox"),
    ("ok", "clock skew 0s"),
    ("ok", "no key stored on the box"),
    ("ok", "new sessions carry the session key"),
    ("ok", "xclip -> /home/dev/.local/bin/xclip"),
    ("ok", "pbpaste -> /home/dev/.local/bin/pbpaste"),
    ("ok", "a shell without your session key can't read the clipboard"),
    ("ok", "round trip (image) sha256 matches"),
]

COLORS = {"bg": "#1e1f24", "bar": "#2b2d33", "text": "#d7dae0", "dim": "#8b919c", "ok": "#5fd38d",
          "head": "#e5c07b", "cmd": "#61afef"}
LINE_H, PAD, CHAR_W = 20, 18, 8.4
width = int(PAD * 2 + CHAR_W * max(len(t) + (8 if k == "ok" else 0) for k, t in LINES))
height = 36 + PAD + LINE_H * len(LINES) + PAD // 2

out = [
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
    f'<rect width="{width}" height="{height}" rx="10" fill="{COLORS["bg"]}"/>',
    f'<path d="M0 10a10 10 0 0 1 10-10h{width - 20}a10 10 0 0 1 10 10v18H0z" fill="{COLORS["bar"]}"/>',
    '<circle cx="18" cy="14" r="6" fill="#ff5f57"/><circle cx="38" cy="14" r="6" fill="#febc2e"/>'
    '<circle cx="58" cy="14" r="6" fill="#28c840"/>',
    f'<text x="{width / 2}" y="18" fill="{COLORS["dim"]}" font-family="-apple-system, Helvetica, sans-serif" '
    'font-size="12" text-anchor="middle">clipbridge doctor</text>',
    '<g font-family="SFMono-Regular, Menlo, Consolas, monospace" font-size="14" xml:space="preserve">',
]
y = 36 + PAD
for kind, text in LINES:
    t = html.escape(text)
    if kind == "ok":
        out.append(f'<text x="{PAD}" y="{y}"><tspan fill="{COLORS["ok"]}">  ok    </tspan>'
                   f'<tspan fill="{COLORS["text"]}">{t}</tspan></text>')
    else:
        out.append(f'<text x="{PAD}" y="{y}" fill="{COLORS[kind]}">{t}</text>')
    y += LINE_H
out += ["</g>", "</svg>"]

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "doctor.svg")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    f.write("\n".join(out) + "\n")
print(os.path.normpath(path))
