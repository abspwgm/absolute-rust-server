# Absolute Rust Server

[![E2E Tests](https://github.com/abspwgm/absolute-rust-server/actions/workflows/e2e.yml/badge.svg)](https://github.com/abspwgm/absolute-rust-server/actions/workflows/e2e.yml)
[![Docker Image](https://github.com/abspwgm/absolute-rust-server/actions/workflows/publish.yml/badge.svg)](https://github.com/abspwgm/absolute-rust-server/actions/workflows/publish.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

New to hosting? Start with the [step-by-step install guide](docs/INSTALL.md).

A production-ready Docker image for hosting Rust dedicated servers with optional Oxide/uMod modding support.

## Features

- **Easy Setup**: Run a Rust server with a single `docker compose up -d`
- **Automatic Updates**: Server files update automatically on container start
- **Oxide/uMod Support**: Built-in support for the Oxide modding framework
- **Automated Backups**: Configurable backup system with retention policies
- **RCON Support**: Remote console access via RCON and WebRCON
- **Highly Configurable**: 40+ environment variables for customization
- **Health Monitoring**: Built-in health checks for container orchestration
- **CI/CD Ready**: Full E2E test suite with GitHub Actions

## Quick Start

### Using Docker Compose (Recommended)

The image is published to the GitHub Container Registry, so there is nothing to clone or build.

1. Create a `docker-compose.yml`:
   ```yaml
   services:
     rust-server:
       image: ghcr.io/abspwgm/absolute-rust-server:latest
       container_name: rust-server
       restart: unless-stopped
       ports:
         - "28015:28015/udp"             # Game port
         - "27015:27015/udp"             # Query port (server list)
         - "127.0.0.1:28016:28016/tcp"   # RCON (admin, keep private)
         - "127.0.0.1:28017:28017/tcp"   # WebRCON (admin, keep private)
       volumes:
         - rust-server:/opt/rust/server
         - rust-config:/config
       environment:
         - SERVER_NAME=My Rust Server
         - ENABLE_OXIDE=false

   volumes:
     rust-server:
     rust-config:
   ```

2. Start the server:
   ```bash
   docker compose up -d
   ```

3. View logs:
   ```bash
   docker logs -f rust-server
   ```

The first start downloads the Rust server files (allow 10GB+ of disk), which can take 30-40 minutes. See [Environment Variables](#environment-variables) for everything you can set, and [Building from Source](#building-from-source) if you would rather build the image yourself.

### Using Docker Run

```bash
docker run -d \
  --name rust-server \
  -p 28015:28015/udp \
  -p 28016:28016/tcp \
  -p 28017:28017/tcp \
  -p 27015:27015/udp \
  -v rust-server:/opt/rust/server \
  -v rust-config:/config \
  -e SERVER_NAME="My Rust Server" \
  -e RCON_PASSWORD="your_secure_password" \
  -e ENABLE_OXIDE=true \
  ghcr.io/abspwgm/absolute-rust-server:latest
```

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 28015 | UDP | Game port (player connections) |
| 28016 | TCP | RCON port |
| 28017 | TCP | WebRCON port |
| 27015 | UDP | Steam query port |

## Environment Variables

### Server Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_NAME` | `Rust Server` | Server name shown in browser |
| `SERVER_PORT` | `28015` | Game port |
| `SERVER_IDENTITY` | `rust_server` | Server identity (folder name for saves) |
| `SERVER_SEED` | Random | World seed (leave empty for random) |
| `SERVER_WORLDSIZE` | `4000` | World size (1000-6000) |
| `SERVER_MAXPLAYERS` | `50` | Maximum players |
| `SERVER_LEVEL` | `Procedural Map` | Map type |
| `SERVER_DESCRIPTION` | Empty | Server description |
| `SERVER_URL` | Empty | Server website URL |
| `SERVER_HEADERIMAGE` | Empty | Server header image URL |
| `SERVER_SAVEINTERVAL` | `600` | Auto-save interval in seconds |

### RCON Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `RCON_ENABLED` | `true` | Enable RCON |
| `RCON_PORT` | `28016` | RCON port |
| `RCON_PASSWORD` | Empty | RCON password (required for RCON) |
| `RCON_WEB` | `true` | Enable WebRCON |
| `RCON_WEB_PORT` | `28017` | WebRCON port |

### Modding (Oxide/uMod)

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_OXIDE` | `false` | Enable Oxide/uMod installation |
| `OXIDE_AUTO_UPDATE` | `true` | Auto-update Oxide on start |

### Update Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `UPDATE_ON_START` | `true` | Update server on container start |
| `UPDATE_IF_IDLE` | `true` | Only update when no players online |
| `UPDATE_CRON` | Empty | Cron schedule for updates |
| `UPDATE_TIMEOUT` | `1800` | Update timeout in seconds |

### Backup Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUPS_ENABLED` | `true` | Enable automatic backups |
| `BACKUPS_CRON` | `0 */6 * * *` | Backup schedule (every 6 hours) |
| `BACKUPS_MAX_AGE` | `7` | Delete backups older than N days |
| `BACKUPS_MAX_COUNT` | `0` | Keep only N backups (0 = unlimited) |
| `BACKUPS_IF_IDLE` | `false` | Only backup when no players online |
| `BACKUPS_COMPRESSION` | `zip` | Compression type (zip or tar.gz) |

### System Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | `1000` | User ID for file permissions |
| `PGID` | `1000` | Group ID for file permissions |
| `TZ` | `UTC` | Timezone |
| `CUSTOM_ARGS` | Empty | Additional server arguments |

## Volumes

| Path | Description |
|------|-------------|
| `/opt/rust/server` | Server files (persisted for caching) |
| `/config` | Configuration, saves, and backups |

## Oxide/uMod Modding

### Enabling Oxide

Set `ENABLE_OXIDE=true` in your environment:

```yaml
environment:
  - ENABLE_OXIDE=true
  - OXIDE_AUTO_UPDATE=true
```

### Installing Plugins

1. Plugins are stored in `/config/oxide/plugins/` inside the container
2. Place `.cs` plugin files in this directory
3. Restart the server or use RCON to reload

With Docker Compose volumes:
```bash
# Copy a plugin to the server
docker cp MyPlugin.cs rust-server:/opt/rust/server/oxide/plugins/
```

### Plugin Configuration

Plugin configurations are stored in `/opt/rust/server/oxide/config/`

## Backup and Restore

### Manual Backup

```bash
docker exec rust-server /opt/rust/scripts/rust-backup --force
```

### Restore from Backup

1. Stop the server
2. Extract backup to the appropriate directories
3. Start the server

```bash
docker compose stop
# Extract backup...
docker compose start
```

### Backup Location

Backups are stored in `/config/backups/` with timestamps:
- `rust_20260130_120000.zip`

## RCON Access

### Using RCON Client

Connect to `your-server:28016` with your RCON password.

### WebRCON

Access WebRCON at `http://your-server:28017` (if enabled).

### Common RCON Commands

```
status              # Show server status
players             # List connected players
say "message"       # Broadcast message
save                # Force save
oxide.version       # Check Oxide version
oxide.reload *      # Reload all plugins
```

## Troubleshooting

### Server Won't Start

1. Check logs: `docker logs rust-server`
2. Verify ports are available
3. Ensure sufficient disk space (10GB+)
4. Check memory (4GB+ recommended)

### Can't Connect to Server

1. Verify ports are forwarded: 28015/udp, 28016/tcp
2. Check firewall rules
3. Verify server is fully started (check logs for "Server startup complete")

### Oxide Not Loading

1. Verify `ENABLE_OXIDE=true` is set
2. Check logs for Oxide-related errors
3. Try forcing reinstall:
   ```bash
   docker exec rust-server /opt/rust/scripts/oxide-installer --install --force
   ```

### Performance Issues

1. Reduce world size: `SERVER_WORLDSIZE=3000`
2. Increase container memory limits
3. Use SSD storage for volumes

## Building from Source

The repository's `docker-compose.yml` builds the image locally instead of pulling it:

```bash
git clone https://github.com/abspwgm/absolute-rust-server.git
cd absolute-rust-server
docker compose up -d --build
```

Or build the image on its own:

```bash
docker build -t absolute-rust-server:latest .
```

## Running Tests

```bash
./tests/run_e2e.sh
```

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Acknowledgments

- [Facepunch Studios](https://facepunch.com/) for Rust
- [uMod/Oxide](https://umod.org/) for the modding framework
- [Valve](https://www.valvesoftware.com/) for SteamCMD
