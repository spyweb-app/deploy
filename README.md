# DEPLOYMENT GUIDE

SpyWeb / Uptyme deployment for Docker and headless Linux (x86_64 + aarch64, musl).

When the main spyweb repo has a new version, this repo also builds the release artifacts for it: musl, x86_64 + aarch64, KV and SQL (see §7).

> **Linux/containers-only.** This repo is for Linux hosts/Docker containers. For a native macOS or Windows install, use the official getting started guide: https://docs.spyweb.app/getting-started/

**Quick links:**

- [1. Fetch a package](#1-get-a-spyweb-package-manually-x86_64-aarch64-musl-any-linux)
- [2. systemd service](#2-run-as-a-systemd-service-host)
- [3. Caddy proxy](#3-put-it-behind-caddy-host)
- [4. Docker: SpyWeb](#4-docker-spyweb)
- [5. Docker: Uptyme](#5-docker-uptyme)
- [6. Compile from source](#6-compile-from-source)
- [7. CI builds](#7-ci-builds)

Everything here does **one job per script**:

| artifact | one job |
|---|---|
| `scripts/get-spyweb.sh` | manually fetch a complete SpyWeb package (KV or SQL) - x86_64 / aarch64 / musl / old-glibc path |
| `scripts/setup-systemd.sh` | install + enable the SpyWeb systemd service (host only) |
| `scripts/setup-caddy.sh` | install caddy if missing, append the SpyWeb site block for proxy setup, reload (host only) |
| `scripts/build-package.sh` | compile the SpyWeb engine from source (local or CI) |
| `ghcr.io/spyweb-app/spyweb` | run SpyWeb in a container, storage selectable at build |
| `ghcr.io/spyweb-app/uptyme` | run Uptyme in a container |
| CI releases | static-musl SpyWeb packages: x86_64 + aarch64, in KV and SQL |

No clone needed except for build-package.sh or Docker build - each script is fetched on its own and run in place.

Host scripts are for **host machines** (VPS, Cloud, bare metal). They should not be run inside Docker

---

## 1. Get a SpyWeb package manually (x86_64, aarch64, musl, any Linux)
> if you are running x86_64 with glibc ≥ 2.39, just get the release asset from dl.spyweb.app/linux (-sql)
>
> if you runing a desktop on aarch64 or glibc < 2.39 and need a tray binary, compile from source with the main repo's release.sh

```bash
wget https://raw.githubusercontent.com/spyweb-app/deploy/main/scripts/get-spyweb.sh   # or: curl -O <same url>
chmod +x get-spyweb.sh

./get-spyweb.sh                                       # KV (redb)
./get-spyweb.sh --storage sql --out /path/to/spyweb   # SQL (SQLite)

# See what it would fetch, without fetching
./get-spyweb.sh --dry-run

# Force the static (musl build)
./get-spyweb.sh --musl
```

Source selection is automatic:

| environment | source |
|---|---|
| x86_64 + glibc ≥ 2.39 | `dl.spyweb.app/linux[-sql]` (main repo release) |
| x86_64 otherwise (older glibc, musl) | `spyweb-linux-musl-x86_64[-sql].tar.gz` (static) |
| aarch64 - any libc | `spyweb-linux-musl-aarch64[-sql].tar.gz` (static) |

> **glibc note:** main repo binaries are built on `ubuntu-latest` and require
> **glibc ≥ 2.39** - hosts below that (debian 12, ubuntu 22.04) automatically
> get the **static musl** build instead, which runs on any distro. `--musl`
> forces it regardless.

Verify what you got

```bash
cd spyweb
./spyweb version         # prints engine + storage: "DB: redb" or "DB: SQLite"
./spyweb check config    # validates jobs + Lua syntax, exit 1 on errors
```

## 2. Run as a systemd service (host)

Run it **from your spyweb directory** (it must contain `./spyweb`), or pass `--dir`

```bash
wget https://raw.githubusercontent.com/spyweb-app/deploy/main/scripts/setup-systemd.sh
chmod +x setup-systemd.sh
sudo ./setup-systemd.sh

# if not run on the spyweb dir - pass it explicitly:
sudo ./setup-systemd.sh --dir /path/to/spyweb
```

Hard-fails if no `spyweb` binary is found in the base dir

What it does (the manual version is in the [deployment docs](https://docs.spyweb.app/api-and-server/deployment/))

- creates a dedicated system user (`spyweb`)
- writes a hardened unit: `Restart=always`, `RestartSec=5`,
  `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`
- writes `/etc/spyweb/env` with `SPYWEB_PORT`, `SPYWEB_LOG`, `SPYWEB_THREADS`,
  `SPYWEB_API_KEY`, `SPYWEB_DISABLE_SERVER`
- `daemon-reload` + `enable --now` (unless told otherwise)

Flags:

| flag | default | meaning |
|---|---|---|
| `--dir` | current directory | the spyweb dir, must contain `./spyweb` |
| `--port` | `SPYWEB_PORT` → `/etc/spyweb/env` → `7979` | dashboard/API port |
| `--user` | `spyweb` (created) | service user |
| `--api-key` | auto-generated | `X-SpyWeb-Key` secret |
| `--no-server` | off | scraping only, no dashboard/API |
| `--log` | engine default | `info` / `warn` / `error` |
| `--threads` | engine default | executor threads |
| `--no-start` | off | install + enable but do not start now |
| `--uninstall` | - | stop + remove unit and env file |
| `--dry-run` | - | print everything, change nothing |

Preconditions: root + `systemctl`. Refuses with a clear error when run on a container.

## 3. Put it behind Caddy (host)

```bash
wget https://raw.githubusercontent.com/spyweb-app/deploy/main/scripts/setup-caddy.sh
chmod +x setup-caddy.sh
sudo ./setup-caddy.sh --domain scrape.example.com --basicauth admin:secret --dry-run
sudo ./setup-caddy.sh --domain scrape.example.com
```

Installs caddy first when missing, renders a site block (reverse proxy to `127.0.0.1:PORT`, optional basic auth), and **appends** it to `/etc/caddy/Caddyfile`
existing config is preserved; refuses if the domain is already configured; the file is backed up first and restored if the result fails `caddy validate`, then caddy
is reloaded.

Port resolution (both host scripts): `--port` → `SPYWEB_PORT` env → `SPYWEB_PORT` in `/etc/spyweb/env` (written by `setup-systemd.sh`) → `7979`.
Under sudo, plain env vars are stripped: pass it as
`sudo SPYWEB_PORT=8123 ./setup-caddy.sh --domain …` or use `sudo -E`.

Flags:

| flag | default | meaning |
|---|---|---|
| `--domain` | required | public hostname, e.g. `scrape.example.com` |
| `--basicauth` | off | `user:password`, hashed via caddy, protects the dashboard |
| `--email` | Caddy default | ACME email for TLS (optional; Caddy can do without) |
| `--port` | `SPYWEB_PORT` → `/etc/spyweb/env` → `7979` | local port to proxy to |
| `--no-install` | off | never install caddy - fail with instructions if missing |
| `--dry-run` | - | print the rendered Caddyfile instead of installing |
| `-h`, `--help` | - | show this help |

## 4. Docker: SpyWeb

```bash
docker run -d --name spyweb \
  -p 7979:7979 \
  -e SPYWEB_API_KEY=secret \
  -v spyweb-data:/opt/spyweb \
  ghcr.io/spyweb-app/spyweb:latest
```

Default base is **alpine**. Another distro is one build-arg:

```bash
docker build --build-arg BASE_IMAGE=debian:13-slim -f docker/spyweb/Dockerfile -t spyweb:local .
docker build --build-arg BASE_IMAGE=ubuntu:24.04  -f docker/uptyme/Dockerfile -t uptyme:local .
```

You need to clone this repo for building your own image (the build context can't be a single file) - the published images above already cover the default.

Storage is a **build-time** feature, so it's chosen by the tag:

| tag | storage |
|---|---|
| `ghcr.io/spyweb-app/spyweb:<version>`, `:latest` | KV (redb) |
| `ghcr.io/spyweb-app/spyweb:<version>-sql`, `:latest-sql` | SQL (SQLite) |

Config - env for knobs, volumes for files:

| env | default | meaning |
|---|---|---|
| `SPYWEB_PORT` | `7979` | dashboard/API port |
| `SPYWEB_LOG` | engine default | `info` / `warn` / `error` |
| `SPYWEB_THREADS` | `2` | executor threads |
| `SPYWEB_DISABLE_SERVER` | unset | set `1` for scraping-only (no dashboard) |
| `SPYWEB_API_KEY` | unset | requires `X-SpyWeb-Key` on all API calls |

| volume | contents |
|---|---|
| `/opt/spyweb` | runtime dir: package files (synced from the image on upgrade), `data*`, `jobs/`, `jobs.toml` |

Extra args pass through: `docker run … ghcr.io/spyweb-app/spyweb --no-server`.

The engine binds `127.0.0.1` only, so the image starts a small `socat` relay on the container IP (same port) to make `-p 7979:7979` work from the host. The relay is skipped for `--no-server` / `SPYWEB_DISABLE_SERVER`.

The `compose/` stacks pass your `.env` via `env_file`, so commented-out variables stay **unset**. Never leave one empty (an empty value still counts as set), and `SPYWEB_DISABLE_SERVER` is presence-triggered: any value - `0`, `false`, even empty - disables the dashboard, so comment it out entirely to keep it on.

## 5. Docker: Uptyme

```bash
# Standalone (the default): no cluster config needed
docker run -d --name uptyme \
  -p 7979:7979 \
  -v uptyme-data:/opt/uptyme \
  ghcr.io/spyweb-app/uptyme:latest

# Central: the node that holds the data + perform consensus
docker run -d --name uptyme \
  -p 7979:7979 \
  -e SPYWEB_MODE=central \
  -v uptyme-data:/opt/uptyme \
  ghcr.io/spyweb-app/uptyme:latest

# Checker: runs parallel checks from its own network location and reports to central
docker run -d --name uptyme \
  -e SPYWEB_MODE=checker \
  -e SPYWEB_DISABLE_SERVER=1 \
  -e SPYWEB_CENTRAL_URL=https://central.example.com \
  -e SPYWEB_AUTH_TOKEN=<node-key-from-central> \
  -e SPYWEB_NODE_NAME=vps-1 \
  -v uptyme-data:/opt/uptyme \
  ghcr.io/spyweb-app/uptyme:latest
```

> **Setup order for checker:** start the central node first. Add a checker there to issue an auth token, then pass that token to the checker container as
> `-e SPYWEB_AUTH_TOKEN=<token>` along with the central address as
> `-e SPYWEB_CENTRAL_URL=https://central.example.com` (as shown in the checker command above).

- Default mode is **standalone** (no cluster config needed)
- Same loopback relay as the spyweb image - `-p 7979:7979` reaches the engine (`socat` on the container IP → `127.0.0.1:7979`)
- The checker command also sets `SPYWEB_DISABLE_SERVER` - checkers only report to central, so no local dashboard starts (nothing listens, no port published)

The image's `config.lua` reads these via `env_get`, so on the host they are always **`SPYWEB_`-prefixed** (the sandbox exposes no other namespace - see
[Sandboxing & Security](https://docs.spyweb.app/security/)):

| env | default | meaning |
|---|---|---|
| `SPYWEB_MODE` | `standalone` | `standalone` \| `central` \| `checker` |
| `SPYWEB_ROLE` | - | `central` \| `checker`, optional override of the mode-derived role |
| `SPYWEB_CENTRAL_URL` | - | checker → central endpoint |
| `SPYWEB_AUTH_TOKEN` | - | node key issued by central |
| `SPYWEB_NODE_NAME` | - | this node's name |
| `SPYWEB_LOG_OUTPUT` | `file` (image: `terminal`) | `file` \| `terminal` \| `both` \| `none` |
| `SPYWEB_PORT` | `7979` | HTTP port |

Tags follow **uptyme's** version (`<version>` / `latest`), not spyweb's.

## 6. Compile from source

Clone the **engine** repo (not this one), fetch the build script, run it:

```bash
git clone https://github.com/spyweb-app/spyweb.git && cd spyweb
wget https://raw.githubusercontent.com/spyweb-app/deploy/main/scripts/build-package.sh
chmod +x build-package.sh

./build-package.sh            # KV (redb)   → dist/spyweb-linux-x86_64.tar.gz
./build-package.sh -sql       # SQL (SQLite) → dist/spyweb-linux-x86_64-sql.tar.gz

tar -xzf dist/spyweb-linux-x86_64.tar.gz   # → ./spyweb/ package
```

Needs `git` + `cargo` (rustc) + `tar`.

## 7. CI builds

- **Static-musl packages** (x86_64 + aarch64, × KV/SQL): runs on a `v*` tag push (matching the spyweb release) or manually via `workflow_dispatch` with a spyweb version - builds the package (CLI only, no tray), asserts static linking, runs the two tests, publishes `spyweb-linux-musl-<arch>[-sql].tar.gz` as a release.
- **Images**: manual `workflow_dispatch` only (not part of the spyweb release cycle): CI matrix `storage {kv, sql}` × `x86_64/aarch64` → GHCR, tagged on spyweb/uptyme versions.

## Layout

```
scripts/get-spyweb.sh     # manually fetch a complete SpyWeb package (kv|sql) -
                          # x86_64 / aarch64 / musl / old-glibc path
scripts/build-package.sh  # build + assemble + test a package
                          # (local or CI; native or static musl)
scripts/setup-systemd.sh  # systemd install (host)
scripts/setup-caddy.sh    # caddy install + Caddyfile append (host)
docker/spyweb/            # image build (storage via build arg/tag)
docker/uptyme/            # image build (SQL locked)
compose/                  # example stacks + .env.example
systemd/spyweb.service    # unit template (also written by setup-systemd.sh)
.github/workflows/        # artifacts.yml (static-musl packages),
                          # docker.yml (GHCR)
```
