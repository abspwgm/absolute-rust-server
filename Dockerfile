# =============================================================================
# Absolute Rust Server - Dockerfile
# =============================================================================
# Multi-stage build for Rust dedicated server with Oxide/uMod support
# Based on debian:bookworm-slim for minimal footprint
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Base image with common dependencies
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    lib32gcc-s1 \
    lib32stdc++6 \
    ca-certificates \
    curl \
    wget \
    procps \
    jq \
    zip \
    unzip \
    cron \
    tini \
    supervisor \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Stage 2: SteamCMD installation
# -----------------------------------------------------------------------------
FROM base AS steamcmd

RUN mkdir -p /opt/steamcmd \
    && cd /opt/steamcmd \
    && curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxvf - \
    && chmod +x /opt/steamcmd/steamcmd.sh \
    && /opt/steamcmd/steamcmd.sh +quit || true

# -----------------------------------------------------------------------------
# Stage 3: Runtime image
# -----------------------------------------------------------------------------
FROM base AS runtime

# Copy SteamCMD from builder
COPY --from=steamcmd /opt/steamcmd /opt/steamcmd
COPY --from=steamcmd /root/Steam /root/Steam

# Create rust user and group
RUN groupadd -g 1000 rust \
    && useradd -u 1000 -g rust -m -s /bin/bash rust

# Create required directories
RUN mkdir -p /opt/rust/server \
    && mkdir -p /config/settings \
    && mkdir -p /config/backups \
    && mkdir -p /config/oxide \
    && mkdir -p /var/log/rust \
    && mkdir -p /var/run/rust \
    && chown -R rust:rust /opt/rust \
    && chown -R rust:rust /config \
    && chown -R rust:rust /var/log/rust \
    && chown -R rust:rust /var/run/rust

# Give the server user its own Steam SDK.
#
# RustDedicated loads steamclient.so from $HOME/.steam/sdk{64,32}. SteamCMD
# puts its copy under /root, which the unprivileged `rust` user cannot even
# traverse, so Steam initialisation failed on every start and the watchdog
# restarted the server every 35 seconds forever (#14). The files are copied
# rather than symlinked into /root so nothing here depends on root's home
# staying readable.
RUN mkdir -p /home/rust/.steam/sdk64 /home/rust/.steam/sdk32 \
    && cp /opt/steamcmd/linux64/steamclient.so /home/rust/.steam/sdk64/steamclient.so \
    && cp /opt/steamcmd/linux32/steamclient.so /home/rust/.steam/sdk32/steamclient.so \
    && chown -R rust:rust /home/rust \
    && chmod 0755 /home/rust

# Copy scripts
COPY scripts/ /opt/rust/scripts/

# Fix line endings and make scripts executable
RUN find /opt/rust/scripts -type f -exec sed -i 's/\r$//' {} \; \
    && chmod +x /opt/rust/scripts/*

# Copy supervisor configuration
COPY config/supervisord.conf /etc/supervisor/conf.d/rust.conf
RUN sed -i 's/\r$//' /etc/supervisor/conf.d/rust.conf

# =============================================================================
# Environment Variables
# =============================================================================

# Server Settings
ENV SERVER_NAME="Rust Server" \
    SERVER_PORT=28015 \
    SERVER_IDENTITY="rust_server" \
    SERVER_SEED="" \
    SERVER_WORLDSIZE=4000 \
    SERVER_MAXPLAYERS=50 \
    SERVER_LEVEL="Procedural Map" \
    SERVER_DESCRIPTION="" \
    SERVER_URL="" \
    SERVER_HEADERIMAGE="" \
    SERVER_TAGS="" \
    SERVER_SAVEINTERVAL=600

# RCON Settings
ENV RCON_ENABLED=true \
    RCON_PORT=28016 \
    RCON_PASSWORD="" \
    RCON_WEB=true \
    RCON_WEB_PORT=28017

# Query Settings
ENV QUERY_PORT=27015

# Modding - Oxide/uMod
ENV ENABLE_OXIDE=false \
    OXIDE_AUTO_UPDATE=true

# Update Settings
ENV UPDATE_ON_START=true \
    UPDATE_IF_IDLE=true \
    UPDATE_CRON="" \
    UPDATE_TIMEOUT=1800

# Backup Settings
ENV BACKUPS_ENABLED=true \
    BACKUPS_CRON="0 */6 * * *" \
    BACKUPS_MAX_AGE=7 \
    BACKUPS_MAX_COUNT=0 \
    BACKUPS_IF_IDLE=false \
    BACKUPS_COMPRESSION=zip

# System Settings
ENV PUID=1000 \
    PGID=1000 \
    UMASK=022 \
    TZ=UTC

# Logging
ENV LOG_FILTER_ENABLED=true \
    LOG_FILTER_EMPTY_LINES=true \
    LOG_FILTER_CONTAINS=""

# Custom Server Arguments
ENV CUSTOM_ARGS=""

# =============================================================================
# Ports and Volumes
# =============================================================================

EXPOSE 28015/udp
EXPOSE 28016/tcp
EXPOSE 28017/tcp
EXPOSE 27015/udp

VOLUME ["/config", "/opt/rust/server"]

# =============================================================================
# Health Check
# =============================================================================

HEALTHCHECK --interval=60s --timeout=10s --start-period=600s --retries=3 \
    CMD /opt/rust/scripts/healthcheck || exit 1

# =============================================================================
# Entry Point
# =============================================================================

WORKDIR /opt/rust

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/rust/scripts/bootstrap"]
