#!/usr/bin/env bash
# get-spyweb.sh - fetch a complete SpyWeb package (binary + ui + jobs/starter-kit
# + docs + examples) for THIS machine. Pure download + extract: nothing is
# compiled, installed, or cleaned up. Needs bash + curl + tar.
#
# Source rule:
#   x86_64  + glibc >= 2.39 -> https://dl.spyweb.app/linux[-sql]   (official release)
#   everything else         -> <deploy-releases>/spyweb-linux-musl-<arch>[-sql].tar.gz
#                              (static musl - runs on ANY distro/libc)
#   --musl forces the second path (dl outage, exotic distro, parity check).
set -euo pipefail

ME="get-spyweb"
DEPLOY_REPO="spyweb-app/deploy"
GLIBC_FLOOR="2.39"   # official releases are built on ubuntu-latest; measured GLIBC_2.39

fail() { echo "$ME: error: $*" >&2; exit 1; }
note() { echo "$ME: $*"; }

usage() {
  cat <<'EOF'
Usage: get-spyweb.sh [options]

Options:
  --storage kv|sql   storage backend (default: kv = redb; sql = SQLite)
  --out DIR          target directory (default: ./spyweb)
  --version X.Y.Z    pin the deploy-release version (default: latest release)
                     note: dl.spyweb.app always serves the latest official
                     release, so --version only affects the musl sources
  --musl             force the static musl build even if this host could use dl
  --no-verify        skip the post-fetch `spyweb version` test
  --dry-run          print the source + URL that would be used and exit
  -h, --help         show this help
EOF
}

STORAGE="kv"
OUT="./spyweb"
VERSION=""
FORCE_MUSL=0
VERIFY=1
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --storage) [ $# -ge 2 ] || fail "--storage needs a value"; STORAGE="$2"; shift 2 ;;
    --storage=*) STORAGE="${1#*=}"; shift ;;
    --out) [ $# -ge 2 ] || fail "--out needs a value"; OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --version) [ $# -ge 2 ] || fail "--version needs a value"; VERSION="$2"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --musl) FORCE_MUSL=1; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

case "$STORAGE" in
  kv) SQL_SUFFIX="" ;;
  sql) SQL_SUFFIX="-sql" ;;
  *) fail "--storage must be kv or sql (got '$STORAGE')" ;;
esac

[ "$(uname -s)" = "Linux" ] || fail "Linux only (got $(uname -s))"

case "$(uname -m)" in
  x86_64) ARCH="x86_64" ;;
  aarch64 | arm64) ARCH="aarch64" ;;
  *) fail "unsupported architecture: $(uname -m) (need x86_64 or aarch64)" ;;
esac

# true if $1 >= $2 (dotted numeric versions)
gte() {
  local IFS=. i x y
  local -a a=($1) b=($2)
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  return 0
}

# prints: musl | glibc:<version> | unknown
detect_libc() {
  if command -v ldd >/dev/null 2>&1; then
    local out ver
    out="$(ldd --version 2>&1 | head -n1 || true)"
    case "$out" in
      *musl*) echo "musl"; return 0 ;;
      *GLIBC* | *glibc* | *GNU*)
        ver="$(printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+' | tail -n1 || true)"
        echo "glibc:${ver:-0}"
        return 0
        ;;
    esac
  fi
  # loader probes (busybox ldd prints no version)
  if ls /lib/ld-musl-*.so.1 /usr/lib/ld-musl-*.so.1 >/dev/null 2>&1; then
    echo "musl"; return 0
  fi
  if ls /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-*.so.2 /lib/ld-linux-aarch64.so.1 >/dev/null 2>&1; then
    echo "glibc:0"; return 0
  fi
  echo "unknown"
}
LIBC="$(detect_libc)"

# ── Pick the source ────────────────────────────────────────────────────────
if [ "$FORCE_MUSL" = "1" ]; then
  KIND="musl"; REASON="--musl (forced)"
elif [ "$ARCH" = "x86_64" ]; then
  case "$LIBC" in
    glibc:*)
      GLIBC_VER="${LIBC#glibc:}"
      if gte "$GLIBC_VER" "$GLIBC_FLOOR"; then
        KIND="dl"; REASON="x86_64 + glibc $GLIBC_VER >= $GLIBC_FLOOR"
      else
        KIND="musl"; REASON="x86_64 + glibc $GLIBC_VER < $GLIBC_FLOOR"
      fi
      ;;
    musl) KIND="musl"; REASON="x86_64 + musl" ;;
    *) KIND="musl"; REASON="libc unknown -> static musl (runs anywhere)" ;;
  esac
else
  KIND="musl"; REASON="$ARCH -> static musl (no glibc arm builds)"
fi

if [ "$KIND" = "dl" ]; then
  URL="https://dl.spyweb.app/linux${SQL_SUFFIX}"
  if [ -n "$VERSION" ]; then
    note "note: --version ignored for dl.spyweb.app (always serves the latest release)"
  fi
else
  ASSET="spyweb-linux-musl-${ARCH}${SQL_SUFFIX}.tar.gz"
  if [ -n "$VERSION" ]; then
    BASE="https://github.com/${DEPLOY_REPO}/releases/download/spyweb-${VERSION}"
  else
    BASE="https://github.com/${DEPLOY_REPO}/releases/latest/download"
  fi
  URL="${BASE}/${ASSET}"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "storage: $STORAGE  arch: $ARCH  libc: $LIBC"
  echo "source:  $REASON"
  echo "url:     $URL"
  exit 0
fi

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

note "fetching $URL ($REASON)"
curl -fsSL -o "$TMP/pkg.tar.gz" "$URL" ||
  fail "download failed: $URL (check --storage/--version, and that a release exists for this arch)"

mkdir -p "$TMP/x"
tar -xzf "$TMP/pkg.tar.gz" -C "$TMP/x" || fail "not a valid tar.gz: $URL"
TOP="$(ls -A "$TMP/x")"
[ -n "$TOP" ] || fail "empty archive: $URL"

mkdir -p "$OUT"
if [ -d "$TMP/x/$TOP" ]; then
  cp -a "$TMP/x/$TOP/." "$OUT/"
else
  cp -a "$TMP/x/$TOP" "$OUT/" 2>/dev/null || cp -a "$TMP/x"/. "$OUT/"
fi

[ -e "$OUT/spyweb" ] || fail "package is missing the 'spyweb' binary"
chmod +x "$OUT/spyweb"

if [ "$VERIFY" = "1" ]; then
  if ! VER_OUT="$("$OUT/spyweb" version 2>&1)"; then
    case "$VER_OUT" in
      *GLIBC_*)
        fail "host glibc is older than the dl binary requires ($VER_OUT) - rerun with --musl" ;;
      *)
        fail "version test failed: $OUT/spyweb version -> $VER_OUT" ;;
    esac
  fi
  case "$STORAGE:$VER_OUT" in
    kv:*"DB: redb"*) ;;
    sql:*"DB: SQLite"*) ;;
    *) fail "storage mismatch: requested '$STORAGE' but got: $VER_OUT" ;;
  esac
  note "verified: $VER_OUT"
fi

note "done -> $OUT (run '$OUT/spyweb start')"
