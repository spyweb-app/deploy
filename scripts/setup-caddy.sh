#!/usr/bin/env bash
# setup-caddy.sh - install caddy if needed, render a SpyWeb site block,
# append it to /etc/caddy/Caddyfile, validate, reload.
# One job: reverse proxy config. No nginx, no firewall.
set -euo pipefail

ME="setup-caddy"
fail() { echo "$ME: error: $*" >&2; exit 1; }
note() { echo "$ME: $*"; }

usage() {
  cat <<'EOF'
Usage: setup-caddy.sh --domain NAME [options]   (must run as root, --dry-run excepted)

Options:
  --domain NAME        public hostname (required), e.g. scrape.example.com
  --basicauth U:P      protect the dashboard with basic auth (hashed via caddy)
  --email ADDR         ACME email for TLS (optional; Caddy can do without)
  --port N             local port to proxy to (default: SPYWEB_PORT env, else /etc/spyweb/env, else 7979)
  --no-install         never install caddy - fail with instructions if missing
  --dry-run            print the rendered Caddyfile instead of installing
  -h, --help           show this help

Caddy: installed when missing (apt/apk/dnf/yum), or refused with --no-install.
Caddyfile: the site block is APPENDED (existing sites preserved); refuses if
this domain is already configured; an existing file is backed up and restored
if the result does not validate.
EOF
}

DOMAIN=""
BASICAUTH=""
EMAIL=""
PORT=""
NO_INSTALL=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --domain=*) DOMAIN="${1#*=}"; shift ;;
    --basicauth) BASICAUTH="$2"; shift 2 ;;
    --basicauth=*) BASICAUTH="${1#*=}"; shift ;;
    --email) EMAIL="$2"; shift 2 ;;
    --email=*) EMAIL="${1#*=}"; shift ;;
    --port) PORT="$2"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

[ -n "$DOMAIN" ] || { usage >&2; fail "--domain is required"; }
case "$DOMAIN" in
  *[!A-Za-z0-9.-]*) fail "invalid domain: $DOMAIN" ;;
esac

# ── Port: --port > SPYWEB_PORT env > /etc/spyweb/env > 7979 ─────────────────
PORT_SOURCE="--port"
if [ -z "$PORT" ]; then
  PORT_SOURCE=""
  if [ -n "${SPYWEB_PORT:-}" ]; then
    PORT="$SPYWEB_PORT"
    PORT_SOURCE="SPYWEB_PORT env"
  elif [ -r /etc/spyweb/env ]; then
    PORT="$(sed -n 's/^SPYWEB_PORT=//p' /etc/spyweb/env | tail -n1)"
    [ -n "$PORT" ] && PORT_SOURCE="/etc/spyweb/env"
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

CADDY_BIN=""
command -v caddy >/dev/null 2>&1 && CADDY_BIN="caddy"

# ── Real run: root + caddy binary (install it when missing) ─────────────────
if [ "$DRY_RUN" != "1" ]; then
  [ "$(id -u)" -eq 0 ] || fail "must run as root (try: sudo $0 ...)"
  if [ -z "$CADDY_BIN" ]; then
    if [ "$NO_INSTALL" = "1" ]; then
      fail "caddy not found - install it first (--no-install given)
  Debian/Ubuntu: apt install caddy      (https://caddyserver.com/docs/install)"
    fi
    note "caddy not found - installing"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y caddy
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache caddy
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y caddy
    elif command -v yum >/dev/null 2>&1; then
      yum install -y caddy
    else
      fail "caddy not found and no supported package manager (apt/apk/dnf/yum)
  install manually: https://caddyserver.com/docs/install"
    fi
    command -v caddy >/dev/null 2>&1 && CADDY_BIN="caddy"
    [ -n "$CADDY_BIN" ] || fail "caddy install finished but no caddy binary on PATH"
    note "installed: $("$CADDY_BIN" version 2>/dev/null | sed -n 1p)"
  fi
fi

BASIC_AUTH_BLOCK=""
if [ -n "$BASICAUTH" ]; then
  case "$BASICAUTH" in
    *:*) ;;
    *) fail "--basicauth must be user:password" ;;
  esac
  BASIC_USER="${BASICAUTH%%:*}"
  BASIC_PASS="${BASICAUTH#*:}"
  [ -n "$BASIC_USER" ] && [ -n "$BASIC_PASS" ] || fail "--basicauth must be user:password"
  if [ -n "$CADDY_BIN" ]; then
    HASH="$("$CADDY_BIN" hash-password --plaintext "$BASIC_PASS" 2>/dev/null)" ||
      fail "caddy hash-password failed"
  else
    [ "$DRY_RUN" = "1" ] || fail "caddy not found - needed to hash the password"
    HASH='<caddy-hash-of-your-password>'
    note "caddy not found: using placeholder hash (real run would install + compute)" >&2
  fi
  BASIC_AUTH_BLOCK="$(printf '	basic_auth {\n		%s %s\n	}\n' "$BASIC_USER" "$HASH")"
fi

render() {
  if [ -n "$EMAIL" ]; then
    printf '{\n\temail %s\n}\n\n' "$EMAIL"
  fi
  printf '%s {\n' "$DOMAIN"
  printf '	encode gzip\n'
  [ -n "$BASIC_AUTH_BLOCK" ] && printf '%s\n' "$BASIC_AUTH_BLOCK"
  printf '	reverse_proxy 127.0.0.1:%s\n' "$PORT"
  printf '}\n'
}

if [ "$DRY_RUN" = "1" ]; then
  [ -n "$CADDY_BIN" ] || note "caddy not found - real run would install it (apt/apk/dnf/yum)"
  echo "# --- would install: /etc/caddy/Caddyfile ---"
  note "proxy target: 127.0.0.1:$PORT ($PORT_SOURCE)"
  render
  exit 0
fi

TARGET="/etc/caddy/Caddyfile"
DOMAIN_RE="$(printf '%s' "$DOMAIN" | sed 's/\./\\./g')"
BACKUP=""

if [ -e "$TARGET" ]; then
  # duplicate guard: this domain already a site address (comments ignored)
  if grep -qE "^[^#]*${DOMAIN_RE}([.,[:space:]]|[{])" "$TARGET"; then
    fail "$DOMAIN is already configured in $TARGET - edit or remove that block first"
  fi
  BACKUP="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$TARGET" "$BACKUP"
  note "backed up existing config -> $BACKUP"
  # clean block separation: trailing newline if missing, then a blank line
  if [ -s "$TARGET" ] && [ -n "$(tail -c1 "$TARGET")" ]; then
    printf '\n' >> "$TARGET"
  fi
  printf '\n' >> "$TARGET"
  note "appending site block to existing $TARGET"
  render >> "$TARGET"
else
  install -d -m 0755 /etc/caddy
  render > "$TARGET"
fi
chmod 0644 "$TARGET"

if ! "$CADDY_BIN" validate --config "$TARGET"; then
  if [ -n "$BACKUP" ]; then
    cp -a "$BACKUP" "$TARGET"
    note "validation failed; restored previous config"
  else
    rm -f "$TARGET"
    note "validation failed; removed new config (nothing was there before)"
  fi
  fail "rendered Caddyfile did not validate"
fi

RELOADED=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy 2>/dev/null; then
  systemctl reload caddy && RELOADED=1
fi
if [ "$RELOADED" = "0" ] && "$CADDY_BIN" reload --config "$TARGET" 2>/dev/null; then
  RELOADED=1
fi

note "installed + validated: $TARGET"
note "proxy target: 127.0.0.1:$PORT ($PORT_SOURCE)"
if [ "$RELOADED" = "1" ]; then
  note "caddy reloaded - https://$DOMAIN"
else
  note "caddy is not running: config is ready; start it with: caddy run --config $TARGET"
fi
