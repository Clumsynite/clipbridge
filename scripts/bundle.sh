#!/usr/bin/env bash
# Build ClipBridge.app (menu-bar app) into .build/ClipBridge.app and, unless --no-install,
# copy it to ~/Applications. Prints the path of the installed (or built) app.
#
#   scripts/bundle.sh               build + install (what `clipbridge install` runs)
#   scripts/bundle.sh --no-install  build only (CI, packaging)
#
# Version comes from VERSION; the build number is the commit count.
# Signing: CB_SIGN_ID, else the first "Apple Development" identity, else ad-hoc.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
install=1
[[ ${1:-} == --no-install ]] && install=0

version=$(tr -d '[:space:]' < VERSION)
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c release --product ClipBridge >/dev/null
bin=$(swift build -c release --show-bin-path)/ClipBridge
app=$root/.build/ClipBridge.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/ClipBridge"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.clumsyknight.clipbridge</string>
  <key>CFBundleName</key><string>ClipBridge</string>
  <key>CFBundleExecutable</key><string>ClipBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# A real identity keeps notifications and the paste permission stable across rebuilds;
# ad-hoc works but macOS refuses notifications for it.
sign_id=${CB_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}
codesign -s "${sign_id:--}" --force --deep "$app" 2>/dev/null

if (( install )); then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/ClipBridge.app"
  cp -R "$app" "$HOME/Applications/ClipBridge.app"
  echo "$HOME/Applications/ClipBridge.app"
else
  echo "$app"
fi
