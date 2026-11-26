#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_DIR="$IOS_DIR/MihomoKitBridge"
FRAMEWORKS_DIR="$IOS_DIR/Frameworks"
OUTPUT_XCFRAMEWORK="$FRAMEWORKS_DIR/MihomoKit.xcframework"

if ! command -v go >/dev/null 2>&1; then
    echo "Error: 'go' is not installed or not in PATH." >&2
    echo "Install Go (e.g. 'brew install go') and re-run this script." >&2
    exit 1
fi

GOPATH_BIN="$(go env GOPATH)/bin"
export PATH="$GOPATH_BIN:$PATH"

NEED_GOMOBILE_INIT=false
if ! command -v gomobile >/dev/null 2>&1; then
    echo "==> Installing golang.org/x/mobile/cmd/gomobile..."
    go install golang.org/x/mobile/cmd/gomobile@latest
    NEED_GOMOBILE_INIT=true
fi

if ! command -v gobind >/dev/null 2>&1; then
    echo "==> Installing golang.org/x/mobile/cmd/gobind..."
    go install golang.org/x/mobile/cmd/gobind@latest
    NEED_GOMOBILE_INIT=true
fi

if [ "$NEED_GOMOBILE_INIT" = true ]; then
    echo "==> Running gomobile init..."
    gomobile init
fi

echo "==> Tidying Go module dependencies in $BRIDGE_DIR..."
cd "$BRIDGE_DIR"
go mod tidy

mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$OUTPUT_XCFRAMEWORK"

echo "==> Building MihomoKit.xcframework (ios, iossimulator)..."
gomobile bind \
    -v \
    -target=ios,iossimulator \
    -iosversion=16.0 \
    -tags with_gvisor \
    -ldflags="-s -w" \
    -o "$OUTPUT_XCFRAMEWORK" \
    .

echo ""
echo "==> Build complete: $OUTPUT_XCFRAMEWORK"
echo ""
echo "Next steps:"
echo "  1. cd iOS && xcodegen generate"
echo "  2. Open RouteWeaver.xcodeproj in Xcode, configure Signing & App Group, and run."
