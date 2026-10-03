#!/usr/bin/env bash
# Prepare /opt/spyweb from the image's package template, then exec the engine.
# Ownership split: package files (spyweb, ui, docs, examples, jobs/starter-kit,
# marker) belong to the image; data*, jobs.toml and user job dirs belong to you.
# Sync happens only when the image's package content changed.
set -euo pipefail

TEMPLATE="${SPYWEB_TEMPLATE:-/opt/package}"
RUNTIME="${SPYWEB_DIR:-/opt/spyweb}"
ME="spyweb-entrypoint"

mkdir -p "$RUNTIME"

if ! touch "$RUNTIME/.entrypoint-write-test" 2>/dev/null; then
  echo "$ME: $RUNTIME is not writable by uid $(id -u)" >&2
  echo "$ME: if you bind-mounted a host directory, run: chown -R 1000:1000 <host-dir>" >&2
  exit 1
fi
rm -f "$RUNTIME/.entrypoint-write-test"

sync_package() {
  local src name
  # package files the image owns - replaced wholesale on upgrade
  for name in spyweb ui docs examples; do
    [ -e "$TEMPLATE/$name" ] || continue
    rm -rf "${RUNTIME:?}/$name" 2>/dev/null || true
    cp -a "$TEMPLATE/$name" "$RUNTIME/" 2>/dev/null \
      || echo "$ME: warning: could not update $name (read-only mount?)" >&2
  done
  # starter-kit refreshed, your own jobs preserved (merge)
  if [ -d "$TEMPLATE/jobs" ]; then
    mkdir -p "$RUNTIME/jobs"
    cp -a "$TEMPLATE/jobs/." "$RUNTIME/jobs/" 2>/dev/null \
      || echo "$ME: warning: could not refresh starter-kit jobs" >&2
  fi
  # yours - copied only when absent
  if [ -f "$TEMPLATE/jobs.toml" ] && [ ! -e "$RUNTIME/jobs.toml" ]; then
    cp -a "$TEMPLATE/jobs.toml" "$RUNTIME/jobs.toml"
  fi
  if [ -f "$TEMPLATE/.image-version" ]; then
    cp -a "$TEMPLATE/.image-version" "$RUNTIME/.image-version"
  fi
  echo "$ME: package synced ($(cat "$TEMPLATE/.image-version" 2>/dev/null || echo unknown))"
}

TV="$(cat "$TEMPLATE/.image-version" 2>/dev/null || echo "")"
RV="$(cat "$RUNTIME/.image-version" 2>/dev/null || echo "")"
if [ "$TV" != "$RV" ]; then
  sync_package
fi

cd "$RUNTIME"

# ── Loopback relay ───────────────────────────────────────────────────────────
# The engine binds 127.0.0.1 only; Docker's -p targets the container's eth0
# IP, which would get connection-refused. Bind the SAME port on every
# non-loopback IP (allowed: specific addresses don't overlap the engine's
# 127.0.0.1 bind - only 0.0.0.0 would) and relay to loopback.
# When the engine learns a bind-address option (SPYWEB_HOST=0.0.0.0), set it
# and drop this: a wildcard bind WOULD collide with this relay, which starts
# before the engine.
start_relay() {
  local port="${SPYWEB_PORT:-7979}" prev="" off=0 a ips ip
  for a in "$@"; do
    case "$a" in
      -*n*) off=1 ;;                      # -n / --no-server / -nqq / ...
      --port=*) port="${a#*=}" ;;
    esac
    case "$prev" in
      --port|-p) port="$a" ;;
    esac
    prev="$a"
  done
  [ "$off" = "0" ] || return 0
  [ -z "${SPYWEB_DISABLE_SERVER:-}" ] || return 0
  case "$port" in
    ''|*[!0-9]*) echo "$ME: relay skipped (bad port '$port')"; return 0 ;;
  esac
  command -v socat >/dev/null 2>&1 || { echo "$ME: socat missing - no external relay"; return 0; }
  ips="$(ip addr show 2>/dev/null | awk '/inet /{split($2,x,"/"); if (x[1] !~ /^127\./) print x[1]}')"
  [ -n "$ips" ] || ips="$(hostname -i 2>/dev/null | tr ' ' '\n' | grep -v '^127\.')" || true
  [ -n "$ips" ] || { echo "$ME: no non-loopback IP - no relay"; return 0; }
  for ip in $ips; do
    socat TCP-LISTEN:"$port",bind="$ip",fork,reuseaddr TCP:127.0.0.1:"$port" &
    echo "$ME: relay $ip:$port -> 127.0.0.1:$port"
  done
}

# No args -> start. A flag first -> start with flags. A subcommand -> as-is.
if [ $# -eq 0 ]; then set -- start; fi
case "$1" in
  -*) set -- start "$@" ;;
esac

if [ "$1" = "start" ]; then
  start_relay "$@"
fi

exec ./spyweb "$@"
