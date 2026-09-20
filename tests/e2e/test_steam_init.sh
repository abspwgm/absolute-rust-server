#!/bin/bash
# =============================================================================
# E2E Test: Steam initialisation
# Verifies that the server user can read steamclient.so and that Steam init
# actually succeeds in the real image.
# =============================================================================
# The assertions here are the exact failure signatures captured from run
# 35508220541, where the server failed SteamAPI_Init on all 59 start attempts
# and never once came up (#14).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="steam_init"
CONTAINER="rust-server"
SDK64="/home/rust/.steam/sdk64/steamclient.so"
SERVER_LOG="/var/log/rust/rust-server.log"

test_steam_init() {
    log_test_start "${TEST_NAME}"

    assert_container_running "${CONTAINER}"

    # --- the server user must be able to read the library -----------------
    if docker exec -u rust "${CONTAINER}" test -r "${SDK64}" 2>/dev/null; then
        log_success "The rust user can read ${SDK64}"
    else
        log_error "The rust user cannot read ${SDK64}"
        docker exec "${CONTAINER}" ls -la /home/rust/.steam/sdk64/ 2>&1 || true
        docker exec "${CONTAINER}" ls -la /root/.steam/sdk64/ 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # --- HOME must point at a directory the server user owns --------------
    # Reading the running process's /proc/<pid>/environ would be the direct
    # check, but it needs PTRACE_MODE_READ and Docker drops CAP_SYS_PTRACE from
    # its default capability set, so even root inside the container gets
    # "Permission denied" and this assertion fails on a true statement.
    #
    # Assert the configuration that sets HOME instead. The outcome it produces
    # is covered below: if HOME were wrong, Steam init would fail and the
    # watchdog would be restarting the server, and both are asserted.
    local rust_conf="/etc/supervisor/conf.d/rust.conf"

    if docker exec "${CONTAINER}" grep -qE '^user=rust$' "${rust_conf}" 2>/dev/null; then
        log_success "supervisor runs the server as the rust user"
    else
        log_error "supervisor does not run the server as the rust user"
        docker exec "${CONTAINER}" grep -E '^(user|environment)=' "${rust_conf}" 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    if docker exec "${CONTAINER}" grep -qE '^environment=.*HOME="?/home/rust"?' "${rust_conf}" 2>/dev/null; then
        log_success "supervisor gives the server HOME=/home/rust"
    else
        log_error "supervisor does not set HOME=/home/rust for the server"
        log_error "Without it the server inherits supervisord's /root and cannot read steamclient.so (#14)"
        docker exec "${CONTAINER}" grep -E '^(user|environment)=' "${rust_conf}" 2>&1 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # --- the captured failure signatures must be absent -------------------
    # "cannot open shared object file" is NOT a failure signature. Steam probes
    # for a local steamclient.so in the working directory first, fails, and then
    # loads the real one from $HOME/.steam/sdk64 - so that line appears on every
    # successful start:
    #
    #   steamclient.so: cannot open shared object file: No such file or directory
    #   [S_API] SteamAPI_Init(): Loaded '/home/rust/.steam/sdk64/steamclient.so' OK.
    #           (First tried local 'steamclient.so')
    #
    # #14's signature was "Permission denied" on /root, followed by the two
    # markers below, which only ever appear when init genuinely fails.
    local failure_markers=(
        "Couldn't initialize Steam Server"
        "Failed to load module"
        "steamclient.so: cannot open shared object file: Permission denied"
    )
    local marker found=0
    for marker in "${failure_markers[@]}"; do
        if docker exec "${CONTAINER}" grep -qF "${marker}" "${SERVER_LOG}" 2>/dev/null; then
            log_error "The server log still contains: ${marker}"
            found=1
        fi
    done

    # Absence of failure is not proof of success: assert that init actually
    # happened, and from the server user's own home rather than root's.
    if [[ ${found} -eq 0 ]]; then
        if docker exec "${CONTAINER}" grep -qE "SteamAPI_Init\(\): Loaded '/home/rust/\.steam/sdk64/steamclient\.so' OK" \
            "${SERVER_LOG}" 2>/dev/null; then
            log_success "Steam initialised from the server user's own SDK"
        else
            log_error "No successful SteamAPI_Init from /home/rust/.steam/sdk64 in the log"
            docker exec "${CONTAINER}" grep -iE 'SteamAPI_Init|steamclient' "${SERVER_LOG}" 2>&1 | tail -20 || true
            log_test_fail "${TEST_NAME}"
            return 1
        fi
    else
        log_error "=== Steam-related log lines ==="
        docker exec "${CONTAINER}" grep -iE 'steam|steamclient' "${SERVER_LOG}" 2>&1 | tail -30 || true
        log_error "=== end ==="
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # --- and the server must not be crash-looping -------------------------
    # #14's signature was the watchdog restarting the server every 35 seconds
    # while the container still reported healthy.
    local restarts
    restarts="$(docker exec "${CONTAINER}" grep -c 'Server process not running, restarting' \
        /var/log/rust/supervisor-rust.log 2>/dev/null | tr -d '\r')"
    [[ "${restarts}" =~ ^[0-9]+$ ]] || restarts=0

    if [[ "${restarts}" -eq 0 ]]; then
        log_success "The watchdog has not had to restart the server"
    else
        log_error "The watchdog restarted the server ${restarts} time(s): still crash-looping"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    log_test_pass "${TEST_NAME}"
    return 0
}

test_steam_init
