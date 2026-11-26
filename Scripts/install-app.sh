#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_NAME="RouteWeaver.app"
SOURCE_APP="$DIST_DIR/$APP_NAME"
TARGET_APP="$INSTALL_DIR/$APP_NAME"

DEPLOY_TARGET="${DEPLOY_TARGET:-remote}"
REMOTE_HOST="${REMOTE_HOST:-mac.monlor.cn}"
REMOTE_PORT="${REMOTE_PORT:-1022}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-1}"
SKIP_TESTS="${SKIP_TESTS:-1}"
SYNC_TUN="${SYNC_TUN:-0}"
SETUP_SUDOERS="${SETUP_SUDOERS:-0}"

usage() {
  cat <<'EOF'
Usage: ./Scripts/install-app.sh [options]

Options:
  --local             Install to local /Applications instead of remote Mac mini
  --host <host>       Remote SSH host (default: mac.monlor.cn)
  --port <port>       Remote SSH port (default: 1022)
  --with-tests        Run swift test before building (default: SKIP_TESTS=1)
  --no-build          Deploy existing dist/RouteWeaver.app without rebuilding
  --no-open           Do not relaunch RouteWeaver.app after installing
  --sync-tun          Sync privileged TUN helper & Mihomo via SSH sudo (no GUI dialog needed)
  --setup-sudoers     Install minimal root sync script + /etc/sudoers.d/routeweaver so future deploys sync passwordlessly
  -h, --help          Show this help message
EOF
}

NO_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      DEPLOY_TARGET="local"
      shift
      ;;
    --host)
      REMOTE_HOST="${2:?Missing value for --host}"
      shift 2
      ;;
    --port)
      REMOTE_PORT="${2:?Missing value for --port}"
      shift 2
      ;;
    --with-tests)
      SKIP_TESTS="0"
      shift
      ;;
    --no-build)
      NO_BUILD=1
      shift
      ;;
    --no-open)
      OPEN_AFTER_INSTALL="0"
      shift
      ;;
    --sync-tun)
      SYNC_TUN=1
      shift
      ;;
    --setup-sudoers)
      SETUP_SUDOERS=1
      SYNC_TUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

stop_running_ui_app() {
  if pgrep -f "[R]outeWeaver\.app/Contents/MacOS/RouteWeaver" >/dev/null 2>&1; then
    pkill -TERM -f "[R]outeWeaver\.app/Contents/MacOS/RouteWeaver" || true
    for _ in $(seq 1 30); do
      pgrep -f "[R]outeWeaver\.app/Contents/MacOS/RouteWeaver" >/dev/null 2>&1 || break
      sleep 0.1
    done
    pkill -KILL -f "[R]outeWeaver\.app/Contents/MacOS/RouteWeaver" 2>/dev/null || true
  fi
}

if [[ "$DEPLOY_TARGET" == "local" ]]; then
  if [[ "$NO_BUILD" != "1" ]]; then
    SKIP_TESTS="$SKIP_TESTS" "$ROOT_DIR/Scripts/build-app.sh"
  fi

  if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Built app not found at: $SOURCE_APP" >&2
    exit 1
  fi

  stop_running_ui_app
  rm -rf "$TARGET_APP"
  ditto "$SOURCE_APP" "$TARGET_APP"
  codesign --verify --strict "$TARGET_APP"

  if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
    open -g "$TARGET_APP"
  fi

  echo "Installed $APP_NAME locally to $TARGET_APP"
  exit 0
fi

CTL_PATH="/tmp/rw-deploy-ssh-$$"
SSH_OPTS=(
  -p "$REMOTE_PORT"
  -o ConnectTimeout=10
  -o ControlMaster=auto
  -o "ControlPath=$CTL_PATH"
  -o ControlPersist=300s
)

REMOTE_STAGE_DIR=""
cleanup() {
  if [[ -n "$REMOTE_STAGE_DIR" ]]; then
    ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "rm -rf '$REMOTE_STAGE_DIR'" >/dev/null 2>&1 || true
  fi
  ssh -p "$REMOTE_PORT" -O exit -o "ControlPath=$CTL_PATH" "$REMOTE_HOST" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Checking remote host $REMOTE_HOST:$REMOTE_PORT ..."
REMOTE_ARCH="$(ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "set -euo pipefail
if [[ \"\$(uname -s)\" != 'Darwin' ]]; then
  echo 'Remote host is not macOS.' >&2
  exit 1
fi
if [[ ! -w '$INSTALL_DIR' ]]; then
  echo 'Remote directory is not writable: $INSTALL_DIR' >&2
  exit 1
fi
uname -m
")"

if [[ -z "$REMOTE_ARCH" ]]; then
  echo "Failed to detect architecture on $REMOTE_HOST" >&2
  exit 1
fi

if [[ "$NO_BUILD" != "1" ]]; then
  echo "==> Building $APP_NAME for $REMOTE_ARCH (SKIP_TESTS=$SKIP_TESTS) ..."
  SKIP_TESTS="$SKIP_TESTS" TARGET_ARCH="$REMOTE_ARCH" "$ROOT_DIR/Scripts/build-app.sh"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Built app not found at: $SOURCE_APP" >&2
  exit 1
fi

echo "==> Preparing staging bundle on $REMOTE_HOST ..."
REMOTE_STAGE_DIR="$(ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "set -euo pipefail
STAGE=\"\$(mktemp -d /tmp/routeweaver-deploy.XXXXXX)\"
if [[ -d '$TARGET_APP' ]]; then
  cp -cR '$TARGET_APP' \"\$STAGE/$APP_NAME\" 2>/dev/null || cp -a '$TARGET_APP' \"\$STAGE/$APP_NAME\"
else
  mkdir -p \"\$STAGE/$APP_NAME\"
fi
printf '%s\n' \"\$STAGE\"
")"
REMOTE_STAGE_APP="$REMOTE_STAGE_DIR/$APP_NAME"

echo "==> Incremental syncing $APP_NAME to $REMOTE_HOST ..."
RSYNC_SSH="ssh -p $REMOTE_PORT -o ControlMaster=auto -o ControlPath=$CTL_PATH"
rsync -acz --delete-after -e "$RSYNC_SSH" "$SOURCE_APP/" "${REMOTE_HOST}:${REMOTE_STAGE_APP}/"

echo "==> Verifying signature and installing to $REMOTE_HOST:$TARGET_APP ..."
ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "set -euo pipefail
STAGE_DIR='$REMOTE_STAGE_DIR'
STAGE_APP='$REMOTE_STAGE_APP'
TARGET_APP='$TARGET_APP'
OPEN_AFTER_INSTALL='$OPEN_AFTER_INSTALL'

xattr -dr com.apple.quarantine \"\$STAGE_APP\" 2>/dev/null || true
codesign --verify --strict \"\$STAGE_APP\"

if pgrep -f '[R]outeWeaver\\.app/Contents/MacOS/RouteWeaver' >/dev/null 2>&1; then
  pkill -TERM -f '[R]outeWeaver\\.app/Contents/MacOS/RouteWeaver' || true
  for _ in \$(seq 1 30); do
    pgrep -f '[R]outeWeaver\\.app/Contents/MacOS/RouteWeaver' >/dev/null 2>&1 || break
    sleep 0.1
  done
  pkill -KILL -f '[R]outeWeaver\\.app/Contents/MacOS/RouteWeaver' 2>/dev/null || true
fi

BACKUP_APP=\"\${TARGET_APP}.bak.\$\$\"
if [[ -d \"\$TARGET_APP\" ]]; then
  mv \"\$TARGET_APP\" \"\$BACKUP_APP\"
fi
if mv \"\$STAGE_APP\" \"\$TARGET_APP\"; then
  rm -rf \"\$BACKUP_APP\" \"\$STAGE_DIR\"
else
  if [[ -d \"\$BACKUP_APP\" ]]; then
    mv \"\$BACKUP_APP\" \"\$TARGET_APP\"
  fi
  rm -rf \"\$STAGE_DIR\"
  exit 1
fi

codesign --verify --strict \"\$TARGET_APP\"

INSTALLED_DIR='/Library/Application Support/RouteWeaver'
INSTALLED_HELPER=\"\$INSTALLED_DIR/tun-helper\"
INSTALLED_MIHOMO=\"\$INSTALLED_DIR/mihomo\"
SYNC_SCRIPT=\"\$INSTALLED_DIR/sync-from-bundle.sh\"
BUNDLED_HELPER=\"\$TARGET_APP/Contents/Resources/bin/RouteWeaverTunHelper\"
BUNDLED_MIHOMO=\"\$TARGET_APP/Contents/Resources/bin/mihomo\"

NEEDS_PRIV_SYNC=0
if [[ -x \"\$INSTALLED_HELPER\" && -x \"\$BUNDLED_HELPER\" ]]; then
  V1=\"\$(\"\$INSTALLED_HELPER\" --version 2>/dev/null || true)\"
  V2=\"\$(\"\$BUNDLED_HELPER\" --version 2>/dev/null || true)\"
  if [[ \"\$V1\" != \"\$V2\" ]]; then
    NEEDS_PRIV_SYNC=1
  fi
fi

if [[ \"\$NEEDS_PRIV_SYNC\" == '1' ]]; then
  if [[ -x \"\$SYNC_SCRIPT\" ]] && sudo -n \"\$SYNC_SCRIPT\" >/dev/null 2>&1; then
    echo '==> Auto-synced privileged TUN helper & Mihomo via sudoers (zero gateway downtime).'
    NEEDS_PRIV_SYNC=0
  elif sudo -n true >/dev/null 2>&1; then
    sudo -n /bin/mkdir -p \"\$INSTALLED_DIR\"
    sudo -n /usr/sbin/chown root:wheel \"\$INSTALLED_DIR\"
    sudo -n /bin/chmod 0755 \"\$INSTALLED_DIR\"
    if [[ -x \"\$BUNDLED_MIHOMO\" ]]; then
      sudo -n /usr/bin/install -o root -g wheel -m 0755 \"\$BUNDLED_MIHOMO\" \"\$INSTALLED_MIHOMO.new\"
      sudo -n /usr/bin/xattr -d com.apple.quarantine \"\$INSTALLED_MIHOMO.new\" 2>/dev/null || true
      sudo -n /bin/mv -f \"\$INSTALLED_MIHOMO.new\" \"\$INSTALLED_MIHOMO\"
    fi
    sudo -n /usr/bin/install -o root -g wheel -m 4755 \"\$BUNDLED_HELPER\" \"\$INSTALLED_HELPER.new\"
    sudo -n /usr/bin/xattr -d com.apple.quarantine \"\$INSTALLED_HELPER.new\" 2>/dev/null || true
    sudo -n /bin/mv -f \"\$INSTALLED_HELPER.new\" \"\$INSTALLED_HELPER\"
    if /bin/launchctl print system/local.routeweaver.mihomo-tun >/dev/null 2>&1; then
      sudo -n /bin/launchctl kickstart -k system/local.routeweaver.mihomo-tun >/dev/null 2>&1 || true
    fi
    echo '==> Auto-synced privileged TUN helper & Mihomo via passwordless sudo.'
    NEEDS_PRIV_SYNC=0
  else
    echo 'Note: RouteWeaverTunHelper protocol version upgraded; existing gateway continues running uninterrupted.'
    echo '      Run ./Scripts/install-app.sh --no-build --setup-sudoers once to sync via SSH and enable future zero-prompt updates.'
  fi
fi

if [[ \"\$OPEN_AFTER_INSTALL\" == '1' ]]; then
  USER_UID=\"\$(id -u)\"
  launchctl asuser \"\$USER_UID\" open -g \"\$TARGET_APP\" 2>/dev/null || open -g \"\$TARGET_APP\"
fi
"
REMOTE_STAGE_DIR=""

if [[ "$SYNC_TUN" == "1" ]]; then
  echo "==> Syncing privileged TUN helper & Mihomo on $REMOTE_HOST via interactive SSH sudo ..."
  ssh -t "${SSH_OPTS[@]}" "$REMOTE_HOST" "set -euo pipefail
TARGET_APP='$TARGET_APP'
SETUP_SUDOERS='$SETUP_SUDOERS'
INSTALLED_DIR='/Library/Application Support/RouteWeaver'
SYNC_SCRIPT=\"\$INSTALLED_DIR/sync-from-bundle.sh\"
REMOTE_USER=\"\$(id -un)\"

sudo /bin/mkdir -p \"\$INSTALLED_DIR\"
sudo /usr/sbin/chown root:wheel \"\$INSTALLED_DIR\"
sudo /bin/chmod 0755 \"\$INSTALLED_DIR\"

sudo /bin/sh -c 'cat > \"/Library/Application Support/RouteWeaver/sync-from-bundle.sh.tmp\" <<\"EOS\"
#!/bin/sh
set -eu
DIR=\"/Library/Application Support/RouteWeaver\"
APP=\"/Applications/RouteWeaver.app\"
HELPER_SRC=\"\$APP/Contents/Resources/bin/RouteWeaverTunHelper\"
MIHOMO_SRC=\"\$APP/Contents/Resources/bin/mihomo\"

/bin/mkdir -p \"\$DIR\"
/usr/sbin/chown root:wheel \"\$DIR\"
/bin/chmod 0755 \"\$DIR\"

if [ -f \"\$MIHOMO_SRC\" ] && [ ! -L \"\$MIHOMO_SRC\" ]; then
  /usr/bin/install -o root -g wheel -m 0755 \"\$MIHOMO_SRC\" \"\$DIR/mihomo.new\"
  /usr/bin/xattr -d com.apple.quarantine \"\$DIR/mihomo.new\" 2>/dev/null || true
  /bin/mv -f \"\$DIR/mihomo.new\" \"\$DIR/mihomo\"
fi

if [ -f \"\$HELPER_SRC\" ] && [ ! -L \"\$HELPER_SRC\" ]; then
  /usr/bin/install -o root -g wheel -m 4755 \"\$HELPER_SRC\" \"\$DIR/tun-helper.new\"
  /usr/bin/xattr -d com.apple.quarantine \"\$DIR/tun-helper.new\" 2>/dev/null || true
  /bin/mv -f \"\$DIR/tun-helper.new\" \"\$DIR/tun-helper\"
fi

if /bin/launchctl print system/local.routeweaver.mihomo-tun >/dev/null 2>&1; then
  /bin/launchctl kickstart -k system/local.routeweaver.mihomo-tun >/dev/null 2>&1 || true
fi
EOS
/usr/sbin/chown root:wheel \"/Library/Application Support/RouteWeaver/sync-from-bundle.sh.tmp\"
/bin/chmod 0755 \"/Library/Application Support/RouteWeaver/sync-from-bundle.sh.tmp\"
/bin/mv -f \"/Library/Application Support/RouteWeaver/sync-from-bundle.sh.tmp\" \"/Library/Application Support/RouteWeaver/sync-from-bundle.sh\"'

sudo \"\$SYNC_SCRIPT\"
echo '==> Privileged TUN helper & Mihomo synced successfully.'

if [[ \"\$SETUP_SUDOERS\" == '1' ]]; then
  SUDOERS_TMP='/tmp/routeweaver-sudoers.\$\$'
  printf '%s ALL=(root) NOPASSWD: /Library/Application\\\\ Support/RouteWeaver/sync-from-bundle.sh\n' \"\$REMOTE_USER\" > \"\$SUDOERS_TMP\"
  if sudo /usr/sbin/visudo -cf \"\$SUDOERS_TMP\" >/dev/null; then
    sudo /usr/bin/install -o root -g wheel -m 0440 \"\$SUDOERS_TMP\" /etc/sudoers.d/routeweaver
    rm -f \"\$SUDOERS_TMP\"
    echo '==> Installed /etc/sudoers.d/routeweaver (future deploys will sync passwordlessly).'
  else
    rm -f \"\$SUDOERS_TMP\"
    echo 'Error: visudo validation failed; /etc/sudoers.d/routeweaver was not modified.' >&2
    exit 1
  fi
fi
"
fi

echo "==> Deployed $APP_NAME to $REMOTE_HOST:$TARGET_APP"
