#!/usr/bin/env bash
# Package a release: dist/ClipBridge-<version>.zip + dist/SHA256SUMS.txt.
#
# The zip is a ready-to-run kit, no Xcode needed:
#   ClipBridge-<version>/
#     ClipBridge.app            prebuilt menu-bar app
#     bin/clipbridge            the CLI (install / add / doctor / …)
#     remote/                   shim + tmux helper copied to your boxes
#     scripts/dev-request.py    used by doctor
#     scripts/spike/            the live Claude Code paste test
#     README.md, HOW-IT-WORKS.md, VERSION
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
version=$(tr -d '[:space:]' < VERSION)
name=ClipBridge-$version
app=$("$root/scripts/bundle.sh" --no-install)

stage=$root/.build/stage
rm -rf "$stage" "$root/dist"
mkdir -p "$stage/$name/scripts/spike" "$stage/$name/bin" "$stage/$name/remote" "$root/dist"
ditto "$app" "$stage/$name/ClipBridge.app"
cp bin/clipbridge "$stage/$name/bin/"
cp remote/clipbridge-shim remote/clipbridge-attach "$stage/$name/remote/"
cp scripts/dev-request.py "$stage/$name/scripts/"
cp scripts/spike/run.sh scripts/spike/run-remote.sh scripts/spike/stub-xclip "$stage/$name/scripts/spike/"
cp README.md HOW-IT-WORKS.md VERSION "$stage/$name/"
[[ -d docs ]] && cp -R docs "$stage/$name/"
(cd "$stage" && ditto -c -k --norsrc --noextattr --keepParent "$name" "$root/dist/$name.zip")
(cd "$root/dist" && shasum -a 256 "$name.zip" > SHA256SUMS.txt)
ls -la "$root/dist"
