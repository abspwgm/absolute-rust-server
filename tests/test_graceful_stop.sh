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

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

# start_fake_server <handles_sigint: yes|no> ; echoes the pid
#
# The stand-in is Python, not bash. bash sets SIGINT to ignore for a background
# job in a non-interactive shell, and a signal ignored on entry cannot be
# trapped -- so a bash stand-in could never demonstrate a graceful stop.
# Python's signal.signal() sets the disposition directly and is not subject to
# that, which lets both the handling and the wedged case be modelled exactly.
start_fake_server() {
    local script="${WORK}/RustDedicated"
    cat > "${script}" <<'FAKE'
#!/usr/bin/env python3
import os
import signal
import sys
import time

log = os.environ["FAKE_LOG"]


def on_sigint(_signum, _frame):
    with open(log, "a", encoding="utf-8") as handle:
        handle.write("Saving World\n")
    sys.exit(0)


if os.environ["FAKE_HANDLES_SIGINT"] == "yes":
    signal.signal(signal.SIGINT, on_sigint)
else:
    signal.signal(signal.SIGINT, signal.SIG_IGN)

while True:
    time.sleep(0.2)
FAKE
    chmod +x "${script}"
    # Redirect the child's output: if it inherited the command-substitution
    # pipe below, $( ) would block until the fake server exited.
    FAKE_LOG="${WORK}/fake.log" FAKE_HANDLES_SIGINT="$1" \
        python3 "${script}" > /dev/null 2>&1 &
    echo "$!"
}

# Zombie-aware liveness, matching process_alive in scripts/common: a reaped-
# pending child still answers kill -0.
alive() {
    kill -0 "$1" 2>/dev/null || return 1
    [[ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != "Z" ]]
}

# stop_it <pid> <timeout> ; sets RC and OUT
stop_it() {
    local pid="$1" timeout="$2"
    [[ -n "${pid}" ]] || return 1
    OUT="$(
        export TEST_ROOT="${WORK}"
        export SHUTDOWN_TIMEOUT="${timeout}"
        export RUST_SCRIPTS_PATH="${REPO_ROOT}/scripts"
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

# --- a healthy server: SIGINT, it saves, we wait for it -------------------
pid="$(start_fake_server yes)"
sleep 1
stop_it "${pid}" 15
if [[ ${RC} -eq 0 ]] && ! alive "${pid}"; then
    pass "a server that handles SIGINT is stopped gracefully"
else
    fail "expected a clean stop, rc=${RC}, still running=$(alive "${pid}" && echo yes || echo no)"
fi
if [[ -f "${WORK}/fake.log" ]] && grep -q "Saving World" "${WORK}/fake.log"; then
    pass "the server was given the chance to save before exiting"
else
    fail "the server was not asked to save"
fi
if ! grep -q "timed out" <<< "${OUT}"; then
    pass "no SIGKILL was needed for a healthy server"
else
    fail "a healthy server should not have been force-killed: ${OUT}"
fi

# --- a wedged server must still be killed, not waited on forever ----------
pid="$(start_fake_server no)"
sleep 1
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

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All graceful stop checks passed"
    exit 0
fi
echo "${failures} graceful stop check(s) failed"
exit 1
