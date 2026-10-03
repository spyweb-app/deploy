# syntax=docker/dockerfile:1
# ghcr.io/spyweb-app/uptyme - Uptyme setup flow: uptyme release tarball + spyweb -sql binary.
#
# Default base: alpine, Another distro:
#   docker build --build-arg BASE_IMAGE=debian:13-slim -f docker/uptyme/Dockerfile .
#
# Build args:
#   BASE_IMAGE=…         base distro (default alpine:3)
#   UPTYME_VERSION=X|latest  uptyme release to fetch
#   SPYWEB_VERSION=X.Y.Z     pin the deploy-release asset version

ARG BASE_IMAGE=alpine:3

# ── Assemble package (runs under the TARGET arch via qemu/binfmt) ──────────
FROM ${BASE_IMAGE} AS pkg
ARG BASE_IMAGE
COPY scripts/get-spyweb.sh /usr/local/bin/get-spyweb.sh
COPY docker/uptyme/config.lua /opt/uptyme-src/config.lua
ARG UPTYME_VERSION=latest
ARG SPYWEB_VERSION=
RUN set -eux; \
    case "$BASE_IMAGE" in \
      alpine*) apk add --no-cache bash curl tar ca-certificates ;; \
      *) apt-get update; \
         apt-get install -y --no-install-recommends bash curl tar ca-certificates; \
         rm -rf /var/lib/apt/lists/* ;; \
    esac; \
    mkdir -p /opt/package; \
    cp /opt/uptyme-src/config.lua /opt/package/config.lua; \
    if [ "$UPTYME_VERSION" = "latest" ]; then \
      URL="https://github.com/spyweb-app/uptyme/releases/latest/download/uptyme.tar.gz"; \
    else \
      URL="https://github.com/spyweb-app/uptyme/releases/download/${UPTYME_VERSION}/uptyme.tar.gz"; \
    fi; \
    curl -fsSL -o /tmp/uptyme.tar.gz "$URL"; \
    tar -xzf /tmp/uptyme.tar.gz -C /opt/package --strip-components=1; \
    bash /usr/local/bin/get-spyweb.sh --storage sql --out /tmp/spyweb \
         ${SPYWEB_VERSION:+--version "$SPYWEB_VERSION"}; \
    mv /tmp/spyweb/spyweb /opt/package/spyweb; \
    chmod +x /opt/package/spyweb; \
    printf 'uptyme:%s-spyweb:%s\n' \
         "$(sha256sum /tmp/uptyme.tar.gz | cut -d' ' -f1)" \
         "$(sha256sum /opt/package/spyweb | cut -d' ' -f1)" > /opt/package/.image-version; \
    rm -rf /tmp/spyweb /tmp/uptyme.tar.gz /opt/package/spyweb-tray; \
    cat /opt/package/.image-version

# ── Runtime ────────────────────────────────────────────────────────────────
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
LABEL org.opencontainers.image.title="uptyme" \
      org.opencontainers.image.description="Uptyme website uptime monitoring (SQL, alpine by default)" \
      org.opencontainers.image.source="https://github.com/spyweb-app/deploy"
RUN set -eux; \
    case "$BASE_IMAGE" in \
      alpine*) \
        apk add --no-cache bash ca-certificates libstdc++ socat; \
        adduser -D -H -u 1000 -s /sbin/nologin uptyme ;; \
      *) \
        apt-get update; \
        apt-get install -y --no-install-recommends bash ca-certificates libstdc++6 socat; \
        rm -rf /var/lib/apt/lists/*; \
        useradd -u 1000 -m -d /home/uptyme -s /usr/sbin/nologin uptyme ;; \
    esac; \
    mkdir -p /opt/uptyme; \
    chown uptyme:uptyme /opt/uptyme
COPY --from=pkg /opt/package /opt/package
COPY docker/uptyme/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Engine port + container-friendly defaults (config.lua reads these via env_get)
ENV SPYWEB_PORT=7979 \
    SPYWEB_MODE=standalone \
    SPYWEB_LOG_OUTPUT=terminal \
    HOME=/opt/uptyme
EXPOSE 7979
VOLUME ["/opt/uptyme"]
USER uptyme
WORKDIR /opt/uptyme
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
