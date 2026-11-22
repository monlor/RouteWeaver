#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This package script requires macOS and Xcode Command Line Tools.' >&2
  exit 1
fi

HOST_ARCH="$(uname -m)"
TARGET_ARCH="${TARGET_ARCH:-$HOST_ARCH}"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
DIST_DIR="${DIST_DIR:-$PWD/dist}"

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  swift test
fi

SWIFT_ARCH_ARGS=()
if [[ "$TARGET_ARCH" != "$HOST_ARCH" ]]; then
  SWIFT_ARCH_ARGS=(--arch "$TARGET_ARCH")
fi

swift build -c release ${SWIFT_ARCH_ARGS[@]+"${SWIFT_ARCH_ARGS[@]}"} --product RouteWeaver
swift build -c release ${SWIFT_ARCH_ARGS[@]+"${SWIFT_ARCH_ARGS[@]}"} --product RouteWeaverTunHelper
BIN_DIR="$(swift build -c release ${SWIFT_ARCH_ARGS[@]+"${SWIFT_ARCH_ARGS[@]}"} --show-bin-path)"
APP="$DIST_DIR/RouteWeaver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
install -m 0755 "$BIN_DIR/RouteWeaver" "$APP/Contents/MacOS/RouteWeaver"
install -m 0755 "$BIN_DIR/RouteWeaverTunHelper" "$APP/Contents/Resources/bin/RouteWeaverTunHelper"
codesign --force --sign - "$APP/Contents/Resources/bin/RouteWeaverTunHelper"

# Compile and bundle Liquid Glass AppIcon (Assets.car + AppIcon.icns)
if [[ "${SKIP_ICON_COMPILE:-0}" != "1" && -d "$PWD/Icon/AppIcon.icon" && -x "$PWD/tools/make_icon.sh" ]]; then
  if [[ ! -f "$PWD/Resources/Assets.car" || ! -f "$PWD/Resources/AppIcon.icns" ]] || \
     [[ -n "$(find "$PWD/Icon/AppIcon.icon" -type f -newer "$PWD/Resources/Assets.car" 2>/dev/null)" ]]; then
    if ! "$PWD/tools/make_icon.sh"; then
      if [[ -f "$PWD/Resources/Assets.car" && -f "$PWD/Resources/AppIcon.icns" ]]; then
        echo "Warning: actool icon compilation failed; reusing existing precompiled Resources icon assets." >&2
      else
        exit 1
      fi
    fi
  fi
fi
if [[ -f "$PWD/Resources/Assets.car" ]]; then
  install -m 0644 "$PWD/Resources/Assets.car" "$APP/Contents/Resources/Assets.car"
fi
if [[ -f "$PWD/Resources/AppIcon.icns" ]]; then
  install -m 0644 "$PWD/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Resolve and bundle Mihomo core binary into Contents/Resources/bin/mihomo
resolve_mihomo() {
  if [[ -n "${MIHOMO_BIN:-}" && -x "${MIHOMO_BIN}" ]]; then
    echo "$MIHOMO_BIN"
    return 0
  fi

  local mihomo_arch
  if [[ "$TARGET_ARCH" == "arm64" ]]; then
    mihomo_arch="arm64"
  else
    mihomo_arch="amd64"
  fi

  if [[ "${MIHOMO_FORCE_DOWNLOAD:-0}" != "1" && "$TARGET_ARCH" == "$HOST_ARCH" ]]; then
    if [[ -x "$PWD/Vendor/mihomo" ]]; then
      echo "$PWD/Vendor/mihomo"
      return 0
    fi
    for candidate in /opt/homebrew/bin/mihomo /usr/local/bin/mihomo /usr/bin/mihomo; do
      if [[ -x "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done
    if command -v mihomo >/dev/null 2>&1; then
      command -v mihomo
      return 0
    fi
  fi

  local cache_dir="$PWD/.build/mihomo-cache"
  local cached_bin="$cache_dir/mihomo-darwin-$mihomo_arch"
  if [[ -x "$cached_bin" ]]; then
    echo "$cached_bin"
    return 0
  fi

  if [[ "${SKIP_MIHOMO_DOWNLOAD:-0}" == "1" ]]; then
    return 1
  fi

  echo "Downloading latest Mihomo ($mihomo_arch) for bundling..." >&2
  mkdir -p "$cache_dir"
  local auth_args=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  local release_json
  release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: RouteWeaver-Build' ${auth_args[@]+"${auth_args[@]}"} \
    'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest')" || return 1

  local download_url
  download_url="$(python3 -c '
import json, sys
arch = sys.argv[1]
data = json.load(sys.stdin)
prefix = f"mihomo-darwin-{arch}-"
assets = [a for a in data.get("assets", []) if a.get("name", "").lower().startswith(prefix) and a.get("name", "").lower().endswith(".gz")]
def pick(items):
    for a in items:
        name = a["name"].lower()
        suffix = name[len(prefix):]
        if suffix.startswith("v") and "compatible" not in name and "-go" not in name:
            return a["browser_download_url"]
    for a in items:
        if "-go" not in a["name"].lower():
            return a["browser_download_url"]
    return items[0]["browser_download_url"] if items else ""
print(pick(assets))
' "$mihomo_arch" <<< "$release_json")"

  if [[ -z "$download_url" ]]; then
    return 1
  fi

  local tmp_gz="$cache_dir/mihomo-$mihomo_arch.gz"
  curl -fL --progress-bar "$download_url" -o "$tmp_gz" || return 1
  gzip -dc "$tmp_gz" > "$cached_bin.tmp"
  rm -f "$tmp_gz"
  chmod 0755 "$cached_bin.tmp"
  mv "$cached_bin.tmp" "$cached_bin"
  echo "$cached_bin"
}

if BUNDLED_MIHOMO="$(resolve_mihomo)"; then
  install -m 0755 "$BUNDLED_MIHOMO" "$APP/Contents/Resources/bin/mihomo"
  codesign --force --sign - "$APP/Contents/Resources/bin/mihomo"
  echo "Bundled Mihomo: $BUNDLED_MIHOMO"
else
  echo "Warning: Mihomo binary not bundled (offline or unavailable). Users can update in-app." >&2
  rm -f "$APP/Contents/Resources/bin/mihomo"
fi

# Bundle minimal Geo databases (Country.mmdb + geosite.dat) for offline first boot
BUNDLED_DIR="$APP/Contents/Resources/bundled"
GEO_CACHE_DIR="$PWD/.build/geo-cache"
mkdir -p "$BUNDLED_DIR" "$GEO_CACHE_DIR"

fetch_geo_asset() {
  local filename="$1"
  local mirror_url="$2"
  local upstream_url="$3"
  local cached="$GEO_CACHE_DIR/$filename"

  if [[ -s "$cached" ]]; then
    echo "$cached"
    return 0
  fi
  if [[ "${SKIP_GEO_DOWNLOAD:-0}" == "1" ]]; then
    return 1
  fi
  echo "Downloading $filename for offline bundling..." >&2
  local tmp="$cached.tmp"
  if curl -fsSL --connect-timeout 15 --max-time 60 "$mirror_url" -o "$tmp" || \
     curl -fsSL --connect-timeout 15 --max-time 60 "$upstream_url" -o "$tmp"; then
    mv "$tmp" "$cached"
    echo "$cached"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

MMDB_FILE=""
GEOSITE_FILE=""
if MMDB_FILE="$(fetch_geo_asset "Country.mmdb" \
  "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb" \
  "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb")"; then
  install -m 0644 "$MMDB_FILE" "$BUNDLED_DIR/Country.mmdb"
fi
if GEOSITE_FILE="$(fetch_geo_asset "geosite.dat" \
  "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat" \
  "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat")"; then
  install -m 0644 "$GEOSITE_FILE" "$BUNDLED_DIR/geosite.dat"
fi

python3 - "$BUNDLED_DIR" <<'PYEOF'
import datetime, hashlib, json, os, sys

bundled_dir = sys.argv[1]
generated_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
specs = [
    {
        "id": "country-mmdb",
        "relativePath": "Country.mmdb",
        "kind": "mmdb",
        "sourceURL": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb",
        "mirrorURLs": ["https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"],
        "license": "GPL-3.0",
        "attribution": "MetaCubeX/meta-rules-dat",
    },
    {
        "id": "geosite-dat",
        "relativePath": "geosite.dat",
        "kind": "dat",
        "sourceURL": "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat",
        "mirrorURLs": ["https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"],
        "license": "GPL-3.0",
        "attribution": "MetaCubeX/meta-rules-dat",
    },
]

entries = []
for s in specs:
    path = os.path.join(bundled_dir, s["relativePath"])
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        continue
    data = open(path, "rb").read()
    # Basic integrity sanity check during packaging
    if s["kind"] == "mmdb" and b"\xab\xcd\xefMaxMind.com" not in data[-131072:]:
        os.remove(path)
        sys.stderr.write(f"Warning: {s['relativePath']} failed MMDB marker check, skipped.\n")
        continue
    if s["kind"] == "dat" and (len(data) < 1024 or data[0] != 0x0A):
        os.remove(path)
        sys.stderr.write(f"Warning: {s['relativePath']} failed protobuf header check, skipped.\n")
        continue
    entries.append({
        **s,
        "version": generated_at[:10],
        "sha256": hashlib.sha256(data).hexdigest(),
        "sizeBytes": len(data),
    })

manifest = {
    "schemaVersion": 1,
    "generatedAt": generated_at,
    "entries": entries,
}
with open(os.path.join(bundled_dir, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)

with open(os.path.join(bundled_dir, "LICENSES.txt"), "w", encoding="utf-8") as f:
    f.write(
        "RouteWeaver Bundled Third-Party Components\n"
        "==========================================\n\n"
        "1. Mihomo (MetaCubeX/mihomo)\n"
        "   License: GNU General Public License v3.0 (GPL-3.0)\n"
        "   Source:  https://github.com/MetaCubeX/mihomo\n\n"
        "2. Geo Databases (Country.mmdb, geosite.dat — MetaCubeX/meta-rules-dat)\n"
        "   License: GNU General Public License v3.0 (GPL-3.0)\n"
        "   Source:  https://github.com/MetaCubeX/meta-rules-dat\n"
    )
print(f"Bundled Geo manifest generated with {len(entries)} entries.")
PYEOF

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>RouteWeaver</string>
    <key>CFBundleIdentifier</key><string>local.routeweaver.mac</string>
    <key>CFBundleName</key><string>RouteWeaver</string>
    <key>CFBundleDisplayName</key><string>RouteWeaver</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
    <key>CFBundleVersion</key><string>${APP_BUILD}</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '\n%s\n' "$APP"
