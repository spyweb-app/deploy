#!/usr/bin/env bash
# build-package.sh - build the SpyWeb CLI (no tray) and assemble a release
# package identical to release.sh's layout, then test it.
#
# Used by .github/workflows/artifacts.yml to produce the assets that
# dl.spyweb.app does not serve (static musl: x86_64 + aarch64, in kv and sql).
set -euo pipefail

ME="build-package"
fail() { echo "$ME: error: $*" >&2; exit 1; }
note() { echo "$ME: $*"; }

usage() {
  cat <<'EOF'
Usage: build-package.sh [options]

Options:
  --repo DIR     spyweb checkout to build (default: .)
  --target T     rust triple, or 'native' (default: native)
  --cross        build via `cross` instead of cargo (needs docker);
                 requires --target (cross ships the musl C++ toolchain)
  --storage kv|sql  storage backend (default: kv)
  -kv, -sql         shorthand for --storage kv|sql
  --asset NAME   asset label for the tarball name, e.g. aarch64,
                 musl-x86_64, musl-aarch64 (default: uname -m)
  --out DIR      output directory for the tarball (default: dist)
  -h, --help     show this help
EOF
}

REPO="."
TARGET="native"
STORAGE="kv"
ASSET=""
OUT="dist"
CROSS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    --target) TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --cross) CROSS=1; shift ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --storage=*) STORAGE="${1#*=}"; shift ;;
    -kv) STORAGE="kv"; shift ;;
    -sql) STORAGE="sql"; shift ;;
    --asset) ASSET="$2"; shift 2 ;;
    --asset=*) ASSET="${1#*=}"; shift ;;
    --out) OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

case "$STORAGE" in
  kv) FEATURES=""; SUFFIX=""; EXPECTED_DB="redb" ;;
  sql) FEATURES="--features sqlite"; SUFFIX="-sql"; EXPECTED_DB="SQLite" ;;
  *) fail "--storage must be kv or sql (got '$STORAGE')" ;;
esac
[ -n "$ASSET" ] || ASSET="$(uname -m)"

cd "$REPO"
[ -f Cargo.toml ] || fail "not a spyweb checkout (no Cargo.toml in $REPO)"
[ -f release.sh ] || fail "not a spyweb checkout (no release.sh in $REPO)"

CARGO_TARGET_FLAG=()
BIN="target/release/spyweb"
RUNNER="cargo"
if [ "$TARGET" != "native" ]; then
  CARGO_TARGET_FLAG=(--target "$TARGET")
  BIN="target/$TARGET/release/spyweb"
  if [ "$CROSS" = "1" ]; then
    command -v cross >/dev/null 2>&1 ||
      fail "cross not found - install it: cargo install cross --locked"
  else
    command -v rustup >/dev/null 2>&1 || fail "rustup required to build for $TARGET"
    note "adding rust target $TARGET"
    rustup target add "$TARGET"
  fi
else
  [ "$CROSS" = "0" ] || fail "--cross requires --target (musl cross build)"
fi
[ "$CROSS" = "1" ] && RUNNER="cross"

note "$RUNNER build --release --bin spyweb $FEATURES${TARGET:+ [$TARGET]}"
# shellcheck disable=SC2086
"$RUNNER" build --release --bin spyweb $FEATURES "${CARGO_TARGET_FLAG[@]}"
[ -x "$BIN" ] || fail "binary not found at $BIN"

# musl builds must be fully static - should run any distro
if [[ "$TARGET" == *musl* ]]; then
  command -v readelf >/dev/null 2>&1 || fail "readelf (binutils) required for the static check"
  if readelf -d "$BIN" 2>/dev/null | grep -q 'NEEDED'; then
    fail "musl build is NOT fully static - dynamic deps found:
$(readelf -d "$BIN" | grep NEEDED)"
  fi
  note "verify no dynamic dependencies"
fi

# ── Assemble (mirrors release.sh assemble_package, minus the tray) ──
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/spyweb"
mkdir -p "$PKG/jobs/starter-kit"

cp -r examples/starter-kit/. "$PKG/jobs/starter-kit/"
[ -f jobs.toml.example ] && cp jobs.toml.example "$PKG/jobs.toml"
if [ -d docs ]; then
  cp -r docs "$PKG/"
  cp LICENSE-MIT "$PKG/docs/" 2>/dev/null || true
  cp LICENSE-APACHE "$PKG/docs/" 2>/dev/null || true
fi
[ -d examples ] && cp -r examples "$PKG/"
[ -d ui ] && cp -r ui "$PKG/"
cp "$BIN" "$PKG/spyweb"

# ── Test: version prints the right DB, config validates ──
note "test: spyweb version"
VER_OUT="$("$PKG/spyweb" version)" || fail "spyweb version failed"
echo "  $VER_OUT"
case "$VER_OUT" in
  *"DB: $EXPECTED_DB"*) ;;
  *) fail "expected DB: $EXPECTED_DB for storage '$STORAGE', got: $VER_OUT" ;;
esac
note "test: spyweb check config"
( cd "$PKG" && ./spyweb check config ) || fail "check config failed"
note "test: OK"

# ── Tarball (top dir 'spyweb/', strip-components=1 friendly) ──
mkdir -p "$OUT"
TARBALL="$OUT/spyweb-linux-${ASSET}${SUFFIX}.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" spyweb
note "created $TARBALL ($(du -h "$TARBALL" | cut -f1))"
