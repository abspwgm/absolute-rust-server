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

    # --- the library actually loaded, from the server user's home ---------
    # RustDedicated states the path it loaded, which proves both that the copy is
    # in place and that HOME resolved to the server user's home rather than
    # /root. Reading /proc/<pid>/environ was the obvious check and does not work:
    # docker exec cannot read it in this container.
    if docker exec "${CONTAINER}" grep -qF \
        "SteamAPI_Init(): Loaded '${SDK64}' OK" "${SERVER_LOG}" 2>/dev/null; then
        log_success "The server loaded ${SDK64}"
    else
        log_error "The server did not report loading ${SDK64}"
        docker exec "${CONTAINER}" grep -iE 'SteamAPI_Init|steamclient' "${SERVER_LOG}" 2>&1 | tail -10 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # Steam must actually come up, not merely load the library.
    local marker
    for marker in "SteamServer Initialized" "SteamServer Connected"; do
        if docker exec "${CONTAINER}" grep -qF "${marker}" "${SERVER_LOG}" 2>/dev/null; then
            log_success "Server log contains: ${marker}"
        else
            log_error "Server log is missing: ${marker}"
            log_test_fail "${TEST_NAME}"
            return 1
        fi
    done

    # HOME is no longer /root, so nothing tries to write into root's home. There
    # were 415 of these lines before the fix.
    local root_writes
    root_writes="$(docker exec "${CONTAINER}" grep -c "CreateDirectory '/root" "${SERVER_LOG}" 2>/dev/null | tr -d '\r')"
    [[ "${root_writes}" =~ ^[0-9]+$ ]] || root_writes=0
    if [[ "${root_writes}" -eq 0 ]]; then
        log_success "Nothing tried to write into /root"
    else
        log_error "${root_writes} attempt(s) to write into /root: HOME is still wrong"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # --- the captured failure signatures must be absent -------------------
    # Deliberately NOT matching a bare "cannot open shared object file": the
    # server always tries a local steamclient.so first and logs that miss before
    # loading the real one ("First tried local 'steamclient.so'"). Matching it
    # would fail a healthy server.
    local failure_markers=(
        "steamclient.so: cannot open shared object file: Permission denied"
        "Couldn't initialize Steam Server"
        "Failed to load module"
    )
    local found=0
    for marker in "${failure_markers[@]}"; do
        if docker exec "${CONTAINER}" grep -qF "${marker}" "${SERVER_LOG}" 2>/dev/null; then
            log_error "The server log still contains: ${marker}"
            found=1
        fi
    done

    if [[ ${found} -eq 0 ]]; then
        log_success "No Steam initialisation failures in the server log"
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
