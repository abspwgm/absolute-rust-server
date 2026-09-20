#!/bin/bash
# =============================================================================
# Unit test: E2E helper process checks
# =============================================================================
# Needs no Docker. process_is_running is the only seam that touches a container,
# so these cases redefine it and drive the polling logic directly.
#
# Guards the bug behind #2: a crash-looping server must fail server_start
# instead of passing whenever a poll happens to land while the process is up.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

# shellcheck source=/dev/null
source "${REPO_ROOT}/tests/test_helpers.sh"

# No real waiting: these tests assert on poll counts, not wall-clock time.
E2E_POLL_INTERVAL=0

# Drive process_is_running from a scripted list of up/down answers. Each call
# consumes the next entry; the last entry repeats once the list runs out.
SCRIPT=""
CALLS=0
process_is_running() {
    CALLS=$((CALLS + 1))
    local answers
    read -r -a answers <<< "${SCRIPT}"
    local idx=$((CALLS - 1))
    local last=$((${#answers[@]} - 1))
    [[ ${idx} -gt ${last} ]] && idx=${last}
    [[ "${answers[${idx}]}" == "up" ]]
}

run_stable() {   # run_stable "<answers>" <timeout> <stable_secs>
    SCRIPT="$1"; CALLS=0
    wait_for_process_stable "fake" "FakeProc" "$2" "$3" > /dev/null 2>&1
    RC=$?
}

# --- the crash-loop case: the bug this test exists for --------------------
# The process flaps up/down. A single poll that catches it "up" must not pass.
run_stable "up down up down up down up down" 60 20
if [[ ${RC} -ne 0 ]]; then
    pass "a flapping process fails instead of passing on a lucky poll"
else
    fail "expected non-zero rc for a flapping process, got rc=${RC}"
fi

# --- a genuinely healthy server ------------------------------------------
run_stable "up" 60 20
if [[ ${RC} -eq 0 ]]; then
    pass "a continuously running process passes"
else
    fail "expected rc=0 for a stable process, got rc=${RC}"
fi

# --- slow to appear, then stable -----------------------------------------
run_stable "down down down up up up up up up up up up" 60 20
if [[ ${RC} -eq 0 ]]; then
    pass "a process that appears late, then stays up, passes"
else
    fail "expected rc=0 when the process appears late, got rc=${RC}"
fi

# --- never appears -------------------------------------------------------
run_stable "down" 10 20
if [[ ${RC} -ne 0 ]]; then
    pass "a process that never appears fails"
else
    fail "expected non-zero rc when the process never appears, got rc=${RC}"
fi

# --- dies after the stability window: caught by a later assert, not here --
run_stable "up up up up up up up up up up up up up up up up up up up up down" 60 20
if [[ ${RC} -eq 0 ]]; then
    pass "stability is judged over the requested window only"
else
    fail "expected rc=0 when the process was stable across the window, got rc=${RC}"
fi

# --- crash-loop detection via the watchdog's restart log -------------------
# docker_exec is the only seam these touch, so fake what grep -c would print.
FAKE_GREP_OUT=""
FAKE_GREP_RC=0
docker_exec() { printf '%s' "${FAKE_GREP_OUT}"; return "${FAKE_GREP_RC}"; }

FAKE_GREP_OUT="0"; FAKE_GREP_RC=1   # grep -c exits 1 when it counts zero
if assert_no_watchdog_restarts "fake" > /dev/null 2>&1; then
    pass "zero watchdog restarts passes"
else
    fail "zero watchdog restarts should pass"
fi

FAKE_GREP_OUT="58"; FAKE_GREP_RC=0
if assert_no_watchdog_restarts "fake" > /dev/null 2>&1; then
    fail "a crash-looping server must not pass"
else
    pass "a crash-looping server fails (the #14 signature)"
fi

FAKE_GREP_OUT="1"; FAKE_GREP_RC=0
if assert_no_watchdog_restarts "fake" > /dev/null 2>&1; then
    fail "even a single restart must not pass"
else
    pass "even a single restart fails"
fi

# The log file may not exist yet on a container that just booted: treat an
# unusable answer as "no restarts seen" rather than erroring the suite.
FAKE_GREP_OUT="grep: /var/log/rust/supervisor-rust.log: No such file or directory"
FAKE_GREP_RC=2
if assert_no_watchdog_restarts "fake" > /dev/null 2>&1; then
    pass "a missing watchdog log is treated as no restarts, not an error"
else
    fail "a missing watchdog log should not fail the check"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All e2e helper checks passed"
    exit 0
fi
echo "${failures} e2e helper check(s) failed"
exit 1
