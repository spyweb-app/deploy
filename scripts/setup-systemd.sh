#!/usr/bin/env bash
# setup-systemd.sh - install + enable the SpyWeb systemd service.
# One job: service files + enable/start. The package itself must already be in
# place (get-spyweb.sh, fetchable from this repo). Host machines only - refuses
# where systemd isn't running (containers, plain chroots).
set -euo pipefail

ME="setup-systemd"
fail() { echo "$ME: error: $*" >&2; exit 1; }
note() { echo "$ME: $*"; }

usage() {
  cat <<'EOF'
Usage: setup-systemd.sh [options]   (run from your spyweb dir, or pass --dir; requires root)

Options:
  --dir DIR        spyweb directory, must contain ./spyweb (default: current directory)
  --port N         dashboard/API port (default: SPYWEB_PORT env, else /etc/spyweb/env, else 7979)
  --user NAME      service user, created if missing (default: spyweb)
  --api-key SECRET SPYWEB_API_KEY (default: generated)
  --threads N      SPYWEB_THREADS (default: engine default)
  --log LEVEL      SPYWEB_LOG: info|warn|error (default: engine default)
  --no-server      set SPYWEB_DISABLE_SERVER=1 (scraping only, no dashboard)
  --no-start       install + enable but do not start now
  --uninstall      remove the unit and env file (keeps package + user)
  --dry-run        print the unit + env file instead of installing
  -h, --help       show this help
EOF
}

DIR=""
PORT=""
USER_NAME="spyweb"
API_KEY=""
THREADS=""
LOG_LEVEL=""
NO_SERVER=0
NO_START=0
UNINSTALL=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --dir=*) DIR="${1#*=}"; shift ;;
    --port) PORT="$2"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --user=*) USER_NAME="${1#*=}"; shift ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --api-key=*) API_KEY="${1#*=}"; shift ;;
    --threads) THREADS="$2"; shift 2 ;;
    --threads=*) THREADS="${1#*=}"; shift ;;
    --log) LOG_LEVEL="$2"; shift 2 ;;
    --log=*) LOG_LEVEL="${1#*=}"; shift ;;
    --no-server) NO_SERVER=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

UNIT_PATH="/etc/systemd/system/spyweb.service"
ENV_DIR="/etc/spyweb"
ENV_PATH="$ENV_DIR/env"

# ── Port: --port > SPYWEB_PORT env > /etc/spyweb/env > 7979 ─────────────────
PORT_SOURCE="--port"
if [ -z "$PORT" ]; then
  PORT_SOURCE=""
  if [ -n "${SPYWEB_PORT:-}" ]; then
    PORT="$SPYWEB_PORT"
    PORT_SOURCE="SPYWEB_PORT env"
  elif [ -r "$ENV_PATH" ]; then
    PORT="$(sed -n 's/^SPYWEB_PORT=//p' "$ENV_PATH" | tail -n1)"
    [ -n "$PORT" ] && PORT_SOURCE="$ENV_PATH"
  fi
fi
PORT="${PORT:-7979}"
PORT_SOURCE="${PORT_SOURCE:-default}"
case "$PORT" in
  ''|*[!0-9]*) fail "port must be a number (got '$PORT' from $PORT_SOURCE)" ;;
esac
PORT=$((10#$PORT))
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  fail "port must be 1-65535 (got '$PORT' from $PORT_SOURCE)"
fi
[ -z "$LOG_LEVEL" ] || case "$LOG_LEVEL" in
  info|warn|error) ;;
  *) fail "--log must be info|warn|error (got '$LOG_LEVEL')" ;;
esac

# ── Resolve base dir: CWD by default; must contain the spyweb binary ────────
DIR="${DIR:-.}"
[ -d "$DIR" ] || fail "not a directory: $DIR"
case "$DIR" in
  *' '*) fail "directory must not contain spaces: $DIR" ;;
esac
DIR="$(cd "$DIR" && pwd)"
if [ "$UNINSTALL" != "1" ]; then
  [ -x "$DIR/spyweb" ] || fail "no spyweb binary at $DIR/spyweb - run this on the spyweb dir, or provide the path to the spyweb dir: --dir /path/to/spyweb (no package yet? wget https://raw.githubusercontent.com/spyweb-app/deploy/main/scripts/get-spyweb.sh)"
fi

render_env() {
  echo "SPYWEB_PORT=$PORT"
  [ -n "$API_KEY" ] && echo "SPYWEB_API_KEY=$API_KEY"
  [ -n "$THREADS" ] && echo "SPYWEB_THREADS=$THREADS"
  [ -n "$LOG_LEVEL" ] && echo "SPYWEB_LOG=$LOG_LEVEL"
  [ "$NO_SERVER" = "1" ] && echo "SPYWEB_DISABLE_SERVER=1"
  return 0
}

render_unit() {
  cat <<EOF
[Unit]
Description=SpyWeb scraping/monitoring engine
Documentation=https://docs.spyweb.app/api-and-server/deployment/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER_NAME
Group=$USER_NAME
WorkingDirectory=$DIR
EnvironmentFile=$ENV_PATH
Environment=HOME=$DIR
ExecStart=$DIR/spyweb start
Restart=always
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGTERM

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$DIR
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
}

# ── Uninstall ────────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "would run: systemctl disable --now spyweb.service"
    echo "would remove: $UNIT_PATH"
    echo "would remove: $ENV_DIR/"
    echo "would run: systemctl daemon-reload"
    echo "note: package ($DIR) and user ($USER_NAME) are kept"
    exit 0
  fi
  [ "$(id -u)" -eq 0 ] || fail "--uninstall requires root"
  command -v systemctl >/dev/null 2>&1 || fail "systemctl not found"
  systemctl disable --now spyweb.service 2>/dev/null || true
  rm -f "$UNIT_PATH"
  rm -rf "$ENV_DIR"
  systemctl daemon-reload
  note "uninstalled unit + env; package ($DIR) and user ($USER_NAME) kept"
  exit 0
fi

# ── Generate an API key if not provided ──────────────────────────────────────
if [ -z "$API_KEY" ]; then
  if command -v openssl >/dev/null 2>&1; then
    API_KEY="$(openssl rand -hex 16)"
  else
    API_KEY="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  note "port: $PORT ($PORT_SOURCE)"
  echo "# --- would install: $ENV_PATH ---"
  render_env
  echo "# --- would install: $UNIT_PATH ---"
  render_unit
  exit 0
fi

# ── Preconditions (real run) ────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || fail "must run as root (try: sudo $0 ...)"
command -v systemctl >/dev/null 2>&1 || fail "systemctl not found - not a systemd host"
[ -d /run/systemd/system ] || fail "systemd is not running here (containers/chroots don't count)"

# ── Service user ────────────────────────────────────────────────────────────
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  NOLOGIN="/usr/sbin/nologin"
  [ -x "$NOLOGIN" ] || NOLOGIN="/sbin/nologin"
  useradd --system --home-dir "$DIR" --no-create-home --shell "$NOLOGIN" "$USER_NAME"
  note "created system user $USER_NAME"
fi
chown -R "$USER_NAME:$USER_NAME" "$DIR"

# ── Install ─────────────────────────────────────────────────────────────────
install -d -m 0755 "$ENV_DIR"
render_env > "$ENV_PATH"
chmod 0640 "$ENV_PATH"
render_unit > "$UNIT_PATH"
systemctl daemon-reload
systemctl enable spyweb.service
if [ "$NO_START" = "0" ]; then
  systemctl restart spyweb.service
fi

note "installed $UNIT_PATH + $ENV_PATH"
note "package: $DIR   user: $USER_NAME   port: $PORT ($PORT_SOURCE)"
if [ "$NO_START" = "1" ]; then
  note "enabled but not started (--no-start); start with: systemctl start spyweb"
else
  sleep 1
  systemctl --no-pager --lines=15 status spyweb.service || true
  note "logs: journalctl -u spyweb -f"
fi
