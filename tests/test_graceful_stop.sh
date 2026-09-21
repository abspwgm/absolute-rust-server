#!/bin/bash
# =============================================================================
# Unit test: stop_server, and that the wrapper handles a shutdown signal
# =============================================================================
# Needs no Docker and no game server: a stand-in process whose command line
# contains RustDedicated plays the server, so pgrep finds it.
#
# Guards #5. supervisor sends stopsignal=INT to the rust-server wrapper, not to
# RustDedicated, and the wrapper had no trap at all: bash terminated, the server
# was orphaned and never asked to save, and docker's SIGKILL took it 30 seconds
# later. Run 35512120872 shows the consequence -- the server log simply stops,
# with no save, and the container exits 137.
#
# The stand-in used to write "Saving World" when it got SIGINT, and so did this
# test's idea of a healthy server. The real one does not: it exits 0 within a
# second and writes nothing (run 35529257566). A fake that saved on SIGINT kept
# this test green while the e2e suite was red. The stand-in now behaves like
# RustDedicated -- SIGINT exits without saving -- and saves only when asked over
# WebRCON, which is the only way the wrapper can actually get a save.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

SERVER_LOG="${WORK}/var/log/rust/rust-server.log"
RCON_PW='correct horse/battery#1'
mkdir -p "$(dirname "${SERVER_LOG}")"

# start_fake_server <on_sigint: exits|ignores> ; echoes the pid (see fake_port)
#
# The stand-in is Python, not bash. bash sets SIGINT to ignore for a background
# job in a non-interactive shell, and a signal ignored on entry cannot be
# trapped -- so a bash stand-in could never model a server that reacts to it.
# Python's signal.signal() sets the disposition directly and is not subject to
# that, which lets both the exiting and the wedged case be modelled exactly.
start_fake_server() {
    local script="${WORK}/RustDedicated"
    cat > "${script}" <<'FAKE'
#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import signal
import socket
import sys
import threading
import time
import urllib.parse

log = os.environ["FAKE_LOG"]
password = os.environ["FAKE_RCON_PASSWORD"]


def handle(conn):
    """One WebRCON client. Strict where RustDedicated is strict: the password is
    the path, and a client frame must be masked."""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return
        data += chunk
    head, _, buf = data.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    path = lines[0].split(" ")[1]
    if path != "/" + urllib.parse.quote(password, safe=""):
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
        if b0 != 0x81 or not b1 & 0x80:
            conn.close()
            return
        length = b1 & 0x7F
        if length == 126:
            length = int.from_bytes(need(2), "big")
        mask = need(4)
        payload = bytes(c ^ mask[i % 4] for i, c in enumerate(need(length)))
    except EOFError:
        return
    request = json.loads(payload)
    if request.get("Message") == "server.save":
        with open(log, "a", encoding="utf-8") as handle_:
            handle_.write("[IMPORTANT] [0.1s] Saving World\n")
    reply = json.dumps({"Message": "Saved", "Identifier": request.get("Identifier"),
                        "Type": "Generic", "Stacktrace": ""}).encode()
    conn.sendall(bytes([0x81, len(reply)]) + reply)


def serve():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen()
    port_file = os.environ["FAKE_PORT_FILE"]
    with open(port_file + ".tmp", "w", encoding="utf-8") as handle_:
        handle_.write(str(srv.getsockname()[1]))
    os.replace(port_file + ".tmp", port_file)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


# Like RustDedicated: SIGINT ends the process and writes nothing.
if os.environ["FAKE_ON_SIGINT"] == "exits":
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
else:
    signal.signal(signal.SIGINT, signal.SIG_IGN)

threading.Thread(target=serve, daemon=True).start()
while True:
    time.sleep(0.2)
FAKE
    chmod +x "${script}"
    rm -f "${WORK}/port"
    # Redirect the child's output: if it inherited the command-substitution
    # pipe below, $( ) would block until the fake server exited.
    FAKE_LOG="${SERVER_LOG}" FAKE_ON_SIGINT="$1" FAKE_RCON_PASSWORD="${RCON_PW}" \
        FAKE_PORT_FILE="${WORK}/port" python3 "${script}" > /dev/null 2>&1 &
    echo "$!"
}

fake_port() {
    local tries=0
    until [[ -s "${WORK}/port" ]]; do
        [[ ${tries} -ge 50 ]] && return 1
        sleep 0.1
        tries=$((tries + 1))
    done
    cat "${WORK}/port"
}

saves_in_log() {
    local n
    n="$(grep -c "Saving World" "${SERVER_LOG}" 2>/dev/null)"
    echo "${n:-0}"
}

# Zombie-aware liveness, matching process_alive in scripts/common: a reaped-
# pending child still answers kill -0.
alive() {
    kill -0 "$1" 2>/dev/null || return 1
    [[ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != "Z" ]]
}

# stop_it <pid> <timeout> [rcon_port] [rcon_password] ; sets RC and OUT
# Port 1 is never listening, which models a server whose WebRCON is unreachable.
stop_it() {
    local pid="$1" timeout="$2" port="${3:-1}" password="${4:-${RCON_PW}}"
    [[ -n "${pid}" ]] || return 1
    OUT="$(
        export TEST_ROOT="${WORK}"
        export SHUTDOWN_TIMEOUT="${timeout}"
        export RUST_SCRIPTS_PATH="${REPO_ROOT}/scripts"
        export RCON_ENABLED=true RCON_WEB=true
        export RCON_PORT="${port}" RCON_PASSWORD="${password}"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/scripts/rust-server"
        # Write the PID file, which get_server_pid consults first. Relying on the
        # pgrep fallback here would be ambiguous: pgrep -f RustDedicated also
        # matches this test's own command lines, and head -1 picked the wrong one.
        mkdir -p "$(dirname "${RUST_SERVER_PID}")"
        echo "${pid}" > "${RUST_SERVER_PID}"
        stop_server
    )" 2>&1
    RC=$?
}

# --- a healthy server: saved over WebRCON, then SIGINT --------------------
: > "${SERVER_LOG}"
pid="$(start_fake_server exits)"
port="$(fake_port)" || fail "the stand-in never opened its WebRCON port"
stop_it "${pid}" 15 "${port}"
if [[ ${RC} -eq 0 ]] && ! alive "${pid}"; then
    pass "a healthy server is stopped gracefully"
else
    fail "expected a clean stop, rc=${RC}, still running=$(alive "${pid}" && echo yes || echo no)"
fi
if [[ "$(saves_in_log)" -eq 1 ]]; then
    pass "the world was saved over WebRCON before the server exited"
else
    fail "expected exactly one save, found $(saves_in_log): ${OUT}"
fi
if grep -q "World saved" <<< "${OUT}" && ! grep -q "without a confirmed save" <<< "${OUT}"; then
    pass "the save was confirmed, not assumed"
else
    fail "expected a confirmed save: ${OUT}"
fi
if ! grep -q "timed out" <<< "${OUT}"; then
    pass "no SIGKILL was needed for a healthy server"
else
    fail "a healthy server should not have been force-killed: ${OUT}"
fi

# --- WebRCON unreachable: still stops, and says the save is not confirmed ---
: > "${SERVER_LOG}"
pid="$(start_fake_server exits)"
fake_port > /dev/null || fail "the stand-in never opened its WebRCON port"
stop_it "${pid}" 15 1
if [[ ${RC} -eq 0 ]] && ! alive "${pid}"; then
    pass "an unreachable WebRCON does not prevent the stop"
else
    fail "expected a clean stop without WebRCON, rc=${RC}"
fi
if grep -q "without a confirmed save" <<< "${OUT}" && [[ "$(saves_in_log)" -eq 0 ]]; then
    pass "a stop without a save is reported rather than silent"
else
    fail "expected a warning that the save is unconfirmed: ${OUT}"
fi

# --- a wrong password is refused at the upgrade, not taken as a save -------
: > "${SERVER_LOG}"
pid="$(start_fake_server exits)"
port="$(fake_port)" || fail "the stand-in never opened its WebRCON port"
stop_it "${pid}" 15 "${port}" "not-the-password-at-all"
if grep -q "without a confirmed save" <<< "${OUT}" && [[ "$(saves_in_log)" -eq 0 ]] && ! alive "${pid}"; then
    pass "a rejected RCON password is reported and the server still stops"
else
    fail "expected a refused save and a clean stop: ${OUT}"
fi

# --- a wedged server must still be killed, not waited on forever ----------
pid="$(start_fake_server ignores)"
fake_port > /dev/null || fail "the stand-in never opened its WebRCON port"
stop_it "${pid}" 4
if [[ ${RC} -eq 0 ]] && ! alive "${pid}"; then
    pass "a server that ignores SIGINT is force-killed after the timeout"
else
    fail "expected the wedged server to be killed, rc=${RC}"
fi
if grep -q "timed out" <<< "${OUT}"; then
    pass "the forced kill is reported rather than silent"
else
    fail "expected a timeout warning: ${OUT}"
fi

# --- stopping when nothing runs is not an error ---------------------------
stop_it 999999 4
if [[ ${RC} -eq 0 ]]; then
    pass "stopping an already-stopped server succeeds"
else
    fail "expected rc=0 when no server is running, got ${RC}"
fi

# --- the wrapper must install a handler for the signal supervisor sends ---
# Without this the graceful path above is never reached in the container: the
# wrapper dies and the server is orphaned (#5).
if grep -qE "^[[:space:]]*trap .*(SIGINT|INT).*(SIGTERM|TERM)" "${REPO_ROOT}/scripts/rust-server"; then
    pass "the wrapper traps the shutdown signals supervisor sends"
else
    fail "scripts/rust-server installs no trap for SIGINT/SIGTERM"
fi

# --- and the trap must not wait behind a foreground sleep -----------------
# bash runs a trap only once the foreground command returns, so a plain
# `sleep 30` in the keep-alive loop delayed the handler by up to 30s of
# supervisor's 150s window. A backgrounded sleep plus `wait` returns at once.
if grep -qE '^[[:space:]]*wait \$!' "${REPO_ROOT}/scripts/rust-server" \
    && ! grep -qE '^[[:space:]]*sleep 30[[:space:]]*$' "${REPO_ROOT}/scripts/rust-server"; then
    pass "the keep-alive loop lets the shutdown trap run immediately"
else
    fail "the keep-alive loop sleeps in the foreground, deferring the shutdown trap"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All graceful stop checks passed"
    exit 0
fi
echo "${failures} graceful stop check(s) failed"
exit 1
