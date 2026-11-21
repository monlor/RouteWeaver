#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This package script requires macOS and Xcode Command Line Tools.' >&2
  exit 1
fi
swift test
swift build -c release --product RouteWeaver
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/RouteWeaver.app"
mkdir -p "$APP/Contents/MacOS"
install -m 0755 "$BIN_DIR/RouteWeaver" "$APP/Contents/MacOS/RouteWeaver"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>RouteWeaver</string>
    <key>CFBundleIdentifier</key><string>local.routeweaver.mac</string>
    <key>CFBundleName</key><string>RouteWeaver</string>
    <key>CFBundleDisplayName</key><string>RouteWeaver</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '\n%s\n' "$APP"
