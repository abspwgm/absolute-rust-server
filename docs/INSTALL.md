# Install Rust server: step by step

This guide takes you from nothing to a running Rust server your friends can join. You
do not need to have used Docker or a command line before. Plan for about
60 minutes, most of it waiting for the game to download.

If you already know Docker, the short version is in the [README](../README.md).

## What you need

| | Minimum | Comfortable |
|---|---|---|
| Memory (RAM) | 4 GB | 8 GB |
| Free disk space | 10 GB | More, to leave room for backups |

- A computer that can stay switched on while people play. An old PC or a mini PC is fine.
  It does not need a graphics card or a copy of the game.
- Linux (Ubuntu or Debian recommended) or Windows 10/11.
- A wired network connection if you can. Wi-Fi works but causes lag for everyone.

## Step 1: Install Docker

Docker is a free program that runs the server in a sealed box, so it cannot make a mess
of your computer and is easy to remove.

**On Linux**, open a terminal and run these two commands:

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Then log out and back in. Check it worked:

```sh
docker --version
```

You should see something like `Docker version 27.x`.

**On Windows**, install [Docker Desktop](https://www.docker.com/products/docker-desktop/),
accept the prompt to enable WSL 2, and restart when asked. Open Docker Desktop once so it
finishes setting up. Then open **PowerShell** and run `docker --version` as above.

## Step 2: Make a folder for your server

Everything your server saves (your world, settings, backups) lives in this folder. Back
up this folder and you have backed up your server.

```sh
mkdir rust-server
cd rust-server
```

## Step 3: Create the settings file

Create a file named `docker-compose.yml` in that folder and paste this in. On Linux,
`nano docker-compose.yml` opens a simple editor (paste, then Ctrl+O, Enter, Ctrl+X to
save and quit). On Windows, use Notepad and make sure the name does not end in `.txt`.

```yaml
services:
  rust-server:
    image: abspowergaming/absolute-rust-server:latest
    container_name: rust-server
    restart: unless-stopped
    ports:
      - "28015:28015/udp"             # Game
      - "27015:27015/udp"             # Query (server list)
      - "127.0.0.1:28016:28016/tcp"   # RCON (admin, keep private)
      - "127.0.0.1:28017:28017/tcp"   # WebRCON (admin, keep private)
    volumes:
      - ./data/server:/opt/rust/server
      - ./data/config:/config
    environment:
      - SERVER_NAME=My Rust Server
      - SERVER_DESCRIPTION=A Rust server running in Docker
      - SERVER_MAXPLAYERS=50
      - SERVER_WORLDSIZE=4000
      - SERVER_SEED=
      - RCON_PASSWORD=
      - TZ=UTC
```

Change these lines before you go on. Leave everything else alone for now.

| Line | Change it to |
|---|---|
| `SERVER_NAME=My Rust Server` | The name players see in the server list |
| `SERVER_DESCRIPTION=...` | A sentence about your server |
| `SERVER_MAXPLAYERS=50` | The most players allowed on at once |
| `SERVER_WORLDSIZE=4000` | Map size, from 1000 to 6000. Smaller maps start faster and use less memory |
| `TZ=UTC` | Your time zone, for example `Europe/London`, so log times make sense |

Leave `SERVER_SEED=` empty for a random map, and leave `RCON_PASSWORD=` empty. RCON is a
remote control for server admins. When the password is empty the server makes up a strong
one for you; [Admin console (RCON)](#admin-console-rcon) shows how to read it.

> Spaces at the start of each line matter in this file. Keep them exactly as shown.

## Step 4: Start the server

```sh
docker compose up -d
```

The first start downloads the game (about 8 GB), which takes
30 to 40 minutes on a typical connection. Watch it work:

```sh
docker compose logs -f
```

The server is ready when you see:

```
Server startup complete
```

Press Ctrl+C to stop watching. That does not stop the server.

## Step 5: Join from your own network

Do this before involving your router, so you know the server itself works.

1. Find the server computer's address: `hostname -I` on Linux, `ipconfig` on Windows
   (look for **IPv4 Address**). It looks like `192.168.1.50`.
2. Start Rust on your gaming computer and press **F1** to open the console (a box you
   can type commands into).
3. Type this, using your server's address, and press Enter:

   ```
   client.connect 192.168.1.50:28015
   ```

   You should see the loading screen, then be in the game.

## Step 6: Let friends join from the internet

Friends outside your home cannot connect until your router forwards the game's ports to
the server computer. Follow the
[port forwarding guide](https://github.com/abspwgm/absolute-game-servers/blob/main/docs/port-forwarding.md)
and use this table when it asks for ports:

| Port | Protocol | What it is for | Forward it? |
|---|---|---|---|
| 28015 | UDP | Game: players connect here | Yes, forward |
| 27015 | UDP | Query: puts your server in the server list | Yes, forward |
| 28016 | TCP | RCON: admin remote control | No, keep private |
| 28017 | TCP | WebRCON: admin remote control from a browser tool | No, keep private |

The two admin ports are only reachable from the server computer itself (that is what
`127.0.0.1` in the settings file means). Never forward them on your router.

Then give your friends your public address (the port forwarding guide shows how to find
it; it looks like `203.0.113.25`). They press **F1** in Rust and type:

```
client.connect 203.0.113.25:28015
```

## Looking after your server

| I want to | Command |
|---|---|
| See if it is running | `docker compose ps` |
| Watch the log | `docker compose logs -f` |
| Stop it | `docker compose down` |
| Start it again | `docker compose up -d` |
| Update the game right now | `docker compose restart` |
| Make a backup right now | `docker exec rust-server /opt/rust/scripts/rust-backup --force` |
| Get our latest fixes | `docker compose pull` then `docker compose up -d` |

**Updates.** The server updates the game each time it starts, and only then. To get a new
version of Rust, restart the server with `docker compose restart`. Warn your players
first: a restart disconnects everyone.

**Backups.** A backup is made every 6 hours into `data/config/backups` and old ones are
removed after 7 days. Copy that folder somewhere else now and then. A backup
on the same disk does not survive the disk failing.

**Restoring a backup.**

A backup is a zip file named after the date and time it was made, for example
`rust_20260130_120000.zip`. Inside is a folder called `server_data` holding your world.
These commands are for Linux; use your own backup's name in steps 3 and 5.

1. Stop the server:

   ```sh
   docker compose down
   ```

2. List your backups and pick one:

   ```sh
   ls data/config/backups
   ```

3. Unpack it into a new folder called `restore`:

   ```sh
   sudo unzip data/config/backups/rust_20260130_120000.zip -d restore
   ```

   You should see a long list of `inflating:` lines. If you see `unzip: command not
   found`, run `sudo apt install unzip` and try again.

4. Move the current world out of the way (this keeps it, in case you change your mind):

   ```sh
   sudo mv data/server/server/rust_server data/server/server/rust_server.old
   ```

5. Put the backed-up world in its place:

   ```sh
   sudo mv restore/rust_20260130_120000/server_data data/server/server/rust_server
   ```

6. Start the server:

   ```sh
   docker compose up -d
   ```

On Windows, do steps 3 to 5 in File Explorer instead: right-click the zip and choose
**Extract All**, rename `data\server\server\rust_server` to `rust_server.old`, then copy
the extracted `server_data` folder to `data\server\server` and rename it `rust_server`.

## Admin console (RCON)

RCON lets an admin type server commands from a separate tool. Whoever has the RCON
password controls your server, so this setup never uses a guessable one. Because you left
`RCON_PASSWORD=` empty, the server generated a strong password on first start. Read it
with:

```sh
docker exec rust-server cat /config/rcon_password
```

You should see one line of 32 letters and numbers. Keep it secret. It stays the same
across restarts. The [README](../README.md#rcon-access) explains how to connect an RCON
tool safely.

## When something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `docker: command not found` | Docker is not installed, or you have not logged out and in since Step 1 | Redo Step 1 |
| `permission denied` talking to Docker | Your user is not in the `docker` group yet | Log out and back in, or put `sudo` in front |
| `yaml:` error on start | The spacing in `docker-compose.yml` was changed | Paste the file again from Step 3 |
| Log stops at "downloading" for a long time | The first download is large | Wait. It resumes if interrupted |
| `port is already allocated` | Another program is using the game's port | Stop the other server, or change the left-hand number of the port pair |
| I can join, my friends cannot | Port forwarding | Work through the table at the end of the port forwarding guide |
| The server is slow or laggy | The map is too big for the computer | Lower `SERVER_WORLDSIZE` to `3000` in `docker-compose.yml`, then run `docker compose up -d` |
| Log says `Server update timed out` | The download took longer than 30 minutes | Wait. The server restarts by itself and the download carries on from where it stopped |
| My server is not in the in-game server list | Port 27015/udp is not forwarded | Check the port table in Step 6. Joining with `client.connect` uses the game port, so try that too |

Still stuck? [Open an issue](https://github.com/abspwgm/absolute-rust-server/issues/new) and paste the last 50 lines of
`docker compose logs`. Remove your server password first.

## Words used in this guide

- **Container:** the sealed box Docker runs the server in.
- **Image:** the download that a container is started from. Ours is `abspowergaming/absolute-rust-server:latest`.
- **Compose file:** `docker-compose.yml`, the one file holding all your server's settings.
- **Volume:** a folder on your computer that the container saves into, so your world
  survives updates and restarts.
- **Port:** a numbered door on a network address. Games listen on specific ones.
- **UDP / TCP:** two ways of sending data. A forwarding rule must use the one the game uses.
