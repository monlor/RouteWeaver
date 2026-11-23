#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
SOURCE_APP="$DIST_DIR/RouteWeaver.app"
TARGET_APP="$INSTALL_DIR/RouteWeaver.app"

"$ROOT_DIR/Scripts/build-app.sh"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Built app not found at: $SOURCE_APP" >&2
  exit 1
fi

rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --verify --strict "$TARGET_APP"

echo "Installed RouteWeaver.app to $TARGET_APP"
