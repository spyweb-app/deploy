# syntax=docker/dockerfile:1
# ghcr.io/spyweb-app/spyweb - SpyWeb in a container.
#
# Default base: alpine. Another distro:
#   docker build --build-arg BASE_IMAGE=debian:13-slim -f docker/spyweb/Dockerfile .
#
# Build args:
#   BASE_IMAGE=…         base distro (default alpine:3)
#   STORAGE=kv|sql       storage backend (default kv = redb)
#   SPYWEB_VERSION=X.Y.Z pin the deploy-release asset version
#
# The fetch is scripts/get-spyweb.sh - identical to a bare-metal install:
# x86_64+glibc>=2.39 gets the main repo dl release, everything else gets the
# static musl build, so the image works on any base.

ARG BASE_IMAGE=alpine:3

# ── Fetch the package (runs under the TARGET arch via qemu/binfmt) ──────────
FROM ${BASE_IMAGE} AS pkg
ARG BASE_IMAGE
COPY scripts/get-spyweb.sh /usr/local/bin/get-spyweb.sh
ARG STORAGE=kv
ARG SPYWEB_VERSION=
RUN set -eux; \
    case "$BASE_IMAGE" in \
      alpine*) apk add --no-cache bash curl tar ca-certificates ;; \
      *) apt-get update; \
         apt-get install -y --no-install-recommends bash curl tar ca-certificates; \
         rm -rf /var/lib/apt/lists/* ;; \
    esac; \
    bash /usr/local/bin/get-spyweb.sh --storage "$STORAGE" --out /opt/package \
         ${SPYWEB_VERSION:+--version "$SPYWEB_VERSION"}; \
    rm -f /opt/package/spyweb-tray; \
    printf '%s-%s\n' "${SPYWEB_VERSION:-latest}" \
         "$(sha256sum /opt/package/spyweb | cut -d' ' -f1)" > /opt/package/.image-version; \
    cat /opt/package/.image-version

# ── Runtime ────────────────────────────────────────────────────────────────
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
LABEL org.opencontainers.image.title="spyweb" \
      org.opencontainers.image.description="SpyWeb scraping/monitoring engine (headless, alpine by default)" \
      org.opencontainers.image.source="https://github.com/spyweb-app/deploy"
RUN set -eux; \
    case "$BASE_IMAGE" in \
      alpine*) \
        apk add --no-cache bash ca-certificates libstdc++ socat; \
        adduser -D -H -u 1000 -s /sbin/nologin spyweb ;; \
      *) \
        apt-get update; \
        apt-get install -y --no-install-recommends bash ca-certificates libstdc++6 socat; \
        rm -rf /var/lib/apt/lists/*; \
        useradd -u 1000 -m -d /home/spyweb -s /usr/sbin/nologin spyweb ;; \
    esac; \
    mkdir -p /opt/spyweb; \
    chown spyweb:spyweb /opt/spyweb
COPY --from=pkg /opt/package /opt/package
COPY docker/spyweb/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV SPYWEB_PORT=7979 \
    HOME=/opt/spyweb
EXPOSE 7979
VOLUME ["/opt/spyweb"]
USER spyweb
WORKDIR /opt/spyweb
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
