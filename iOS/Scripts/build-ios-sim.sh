#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS_DIR="$ROOT_DIR/iOS"
DERIVED_DIR="$ROOT_DIR/.build/ios-sim"
TARGET_DEVICE="${LUMZEL_DEVICE:-}"

if [[ -z "$TARGET_DEVICE" ]]; then
  echo "error: LUMZEL_DEVICE is not set (must be invoked by Lumzel iOS preview)." >&2
  exit 1
fi

cd "$IOS_DIR"

echo "[RouteWeaver iOS] Generating Xcode project via xcodegen..."
xcodegen generate

echo "[RouteWeaver iOS] Building RouteWeaveriOS for simulator $TARGET_DEVICE..."
xcodebuild \
  -project "$IOS_DIR/RouteWeaveriOS.xcodeproj" \
  -scheme RouteWeaveriOS \
  -destination "id=$TARGET_DEVICE" \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DIR/Build/Products/Debug-iphonesimulator/RouteWeaver.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: Built app not found at $APP_PATH" >&2
  exit 1
fi

echo "[RouteWeaver iOS] Installing $APP_PATH onto $TARGET_DEVICE..."
xcrun simctl install "$TARGET_DEVICE" "$APP_PATH"
echo "[RouteWeaver iOS] Build and install complete."
