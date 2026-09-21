#!/bin/bash
# =============================================================================
# Unit test: rcon_command, get_player_count, and what the idle guard and the
# backup schedule do when the count cannot be read
# =============================================================================
# Needs no Docker and no game server. A stand-in WebRCON endpoint behaves the way
# RustDedicated's does where it matters: the password is the path, the console
# is broadcast to every client before (and between) replies, and a serverinfo
# reply is long enough to need the 16-bit frame length.
#
# get_player_count was a placeholder that always said 0: the idle guard never
# held an update and "skip backups while players are on" never skipped.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
FAKE_PID=""
cleanup() {
    [[ -n "${FAKE_PID}" ]] && kill "${FAKE_PID}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

PASSWORD='correct horse/battery#1'
PLAYERS=3

cat > "${WORK}/fake_rcon.py" <<'FAKE'
import base64, hashlib, json, os, socket, threading, urllib.parse

password = os.environ["FAKE_RCON_PASSWORD"]
players = int(os.environ["FAKE_PLAYERS"])


def frame(obj):
    data = json.dumps(obj).encode()
    n = len(data)
    head = bytes([0x81, n]) if n < 126 else bytes([0x81, 126, n >> 8, n & 0xFF])
    return head + data


def handle(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return
        data += chunk
    head, _, buf = data.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    if lines[0].split(" ")[1] != "/" + urllib.parse.quote(password, safe=""):
        conn.sendall(b"HTTP/1.1 401 Unauthorized\r\n\r\n")
        conn.close()
        return
    key = next(l.split(":", 1)[1].strip() for l in lines[1:]
               if l.lower().startswith("sec-websocket-key:"))
    accept = base64.b64encode(hashlib.sha1(
        (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                  f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())

    def need(n):
        nonlocal buf
        while len(buf) < n:
            chunk = conn.recv(4096)
            if not chunk:
                raise EOFError
            buf += chunk
        out, buf = buf[:n], buf[n:]
        return out

    try:
        b0, b1 = need(2)
        length = b1 & 0x7F
        if length == 126:
            length = int.from_bytes(need(2), "big")
        mask = need(4)
        request = json.loads(bytes(c ^ mask[i % 4] for i, c in enumerate(need(length))))
    except EOFError:
        return
    # Console chatter reaches every client first, as it does on the real server.
    conn.sendall(frame({"Message": "Invalidate Network Cache took 0.00 seconds",
                        "Identifier": 0, "Type": "Generic", "Stacktrace": ""}))
    if request.get("Message") == "serverinfo":
        info = {"Hostname": "E2E Test Server", "MaxPlayers": 4, "Players": players,
                "Queued": 0, "Joining": 0, "EntityCount": 974, "GameTime": "09/21/2026 12:00:00",
                "Uptime": 120, "Map": "Procedural Map", "Framerate": 256.0, "Memory": 3200,
                "Collections": 12, "NetworkIn": 0, "NetworkOut": 0, "Restarting": False,
                "SaveCreatedTime": "2026-09-21T12:00:00"}
        message = json.dumps(info, indent=2)
    else:
        message = "Command not found"
    conn.sendall(frame({"Message": message, "Identifier": request.get("Identifier"),
                        "Type": "Generic", "Stacktrace": ""}))
    try:
        need(2)
    except EOFError:
        pass
    conn.close()


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen()
with open(os.environ["FAKE_PORT_FILE"] + ".tmp", "w") as f:
    f.write(str(srv.getsockname()[1]))
os.replace(os.environ["FAKE_PORT_FILE"] + ".tmp", os.environ["FAKE_PORT_FILE"])
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
FAKE

FAKE_RCON_PASSWORD="${PASSWORD}" FAKE_PLAYERS="${PLAYERS}" FAKE_PORT_FILE="${WORK}/port" \
    python3 "${WORK}/fake_rcon.py" > /dev/null 2>&1 &
FAKE_PID=$!
for _ in $(seq 1 50); do [[ -s "${WORK}/port" ]] && break; sleep 0.1; done
PORT="$(cat "${WORK}/port" 2>/dev/null)"
[[ -n "${PORT}" ]] || { echo "[FAIL] the stand-in never opened its port"; exit 1; }

# in_image <port> <password> <command...> ; runs a command with common sourced
in_image() {
    local port="$1" password="$2"
    shift 2
    (
        export TEST_ROOT="${WORK}" RUST_SCRIPTS_PATH="${REPO_ROOT}/scripts"
        export RCON_ENABLED=true RCON_WEB=true RCON_PORT="${port}" RCON_PASSWORD="${password}"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/scripts/common"
        "$@"
    )
}

# --- a real reply, past the chatter, through a 16-bit frame length -------
out="$(in_image "${PORT}" "${PASSWORD}" rcon_command serverinfo 2>/dev/null)"
if [[ "$(jq -r '.Hostname' <<< "${out}" 2>/dev/null)" == "E2E Test Server" ]]; then
    pass "rcon_command returns the reply to its own request, not the broadcast before it"
else
    fail "expected the serverinfo reply, got: ${out:0:200}"
fi

count="$(in_image "${PORT}" "${PASSWORD}" get_player_count 2>/dev/null)"
if [[ "${count}" == "${PLAYERS}" ]]; then
    pass "get_player_count reads the live count (${PLAYERS}), not the old constant 0"
else
    fail "expected ${PLAYERS} players, got '${count}'"
fi

# --- unknown is not zero -------------------------------------------------
if count="$(in_image 1 "${PASSWORD}" get_player_count 2>/dev/null)"; then
    fail "an unreachable WebRCON produced a count: '${count}'"
else
    [[ -z "${count}" ]] && pass "an unreachable WebRCON is unknown: no count, and a non-zero exit" \
        || fail "an unreachable WebRCON printed '${count}'"
fi
if in_image "${PORT}" "not-the-password" get_player_count >/dev/null 2>&1; then
    fail "a refused password produced a count"
else
    pass "a refused password is unknown too"
fi

# --- what the callers do with each answer --------------------------------
updater_decision() {
    # should_skip_update returns 0 to skip. main runs only when executed.
    in_image "$1" "${PASSWORD}" bash -c "
        FORCE_UPDATE=false UPDATE_IF_IDLE=true
        source '${REPO_ROOT}/scripts/rust-updater' >/dev/null 2>&1 || true
        should_skip_update >/dev/null 2>&1 && echo hold || echo update"
}
backup_decision() {
    in_image "$1" "${PASSWORD}" bash -c "
        BACKUPS_ENABLED=true BACKUPS_IF_IDLE=true
        source '${REPO_ROOT}/scripts/rust-backup' >/dev/null 2>&1 || true
        should_skip_backup >/dev/null 2>&1 && echo skip || echo backup"
}

if [[ "$(updater_decision "${PORT}")" == "hold" ]]; then
    pass "the idle guard holds an update while ${PLAYERS} players are on"
else
    fail "the idle guard let an update through with ${PLAYERS} players on"
fi
if [[ "$(updater_decision 1)" == "hold" ]]; then
    pass "the idle guard holds when the count cannot be read (standard 5.2)"
else
    fail "the idle guard updated on an unknown player count"
fi
if [[ "$(backup_decision 1)" == "backup" ]]; then
    pass "an unknown count still takes the backup"
else
    fail "an unknown count skipped the backup"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All rcon_command checks passed"
    exit 0
fi
echo "${failures} rcon_command check(s) failed"
exit 1
