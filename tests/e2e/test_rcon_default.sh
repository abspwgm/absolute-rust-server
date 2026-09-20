#!/bin/bash
# =============================================================================
# E2E Test: RCON Default Password
# Verifies that a known-default RCON_PASSWORD is replaced by a generated one
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="rcon_default"

# The test compose file starts the container with this known default
DEFAULT_PASSWORD="changeme"
PASSWORD_FILE="/config/rcon_password"

# -----------------------------------------------------------------------------
# Test: RCON Default Password
# -----------------------------------------------------------------------------
test_rcon_default() {
    log_test_start "${TEST_NAME}"

    # Verify container is running
    assert_container_running "rust-server"

    # Verify the container really was started with the default password
    log_info "Checking container was started with the default RCON password"
    if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' rust-server | grep -qx "RCON_PASSWORD=${DEFAULT_PASSWORD}"; then
        log_info "Container environment has RCON_PASSWORD=${DEFAULT_PASSWORD}"
    else
        log_error "Container was not started with RCON_PASSWORD=${DEFAULT_PASSWORD}"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # Generated password file must exist
    log_info "Checking for generated password file"
    if ! assert_file_exists "rust-server" "${PASSWORD_FILE}"; then
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # Password must be strong (length >= 24) and not the default
    local generated
    generated=$(docker_exec rust-server cat "${PASSWORD_FILE}" | tr -d '\r\n')
    if [[ ${#generated} -ge 24 ]]; then
        log_success "Generated password length is ${#generated}"
    else
        log_error "Generated password is too short (${#generated} < 24)"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    if [[ "${generated}" == "${DEFAULT_PASSWORD}" ]]; then
        log_error "Password file contains the default password"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # File must be mode 600 and owned by the server user
    local file_stat
    file_stat=$(docker_exec rust-server stat -c '%a %U' "${PASSWORD_FILE}" | tr -d '\r')
    if [[ "${file_stat}" == "600 rust" ]]; then
        log_success "Password file is mode 600 owned by rust"
    else
        log_error "Password file has wrong mode/owner: '${file_stat}' (expected '600 rust')"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # The generated value must never be logged
    log_info "Checking that the generated password is not logged"
    if docker logs rust-server 2>&1 | grep -qF "${generated}"; then
        log_error "Generated password found in container logs"
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    if docker_exec rust-server grep -qF "${generated}" /var/log/rust/supervisor-rust.log 2>/dev/null; then
        log_error "Generated password found in supervisor log"
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "Generated password does not appear in logs"

    # The default must not reach the server process arguments
    log_info "Waiting for server process"
    if ! wait_for_process "rust-server" "RustDedicated" 300; then
        log_error "Server process is not running"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    local server_args
    server_args=$(docker_exec rust-server sh -c 'cat /proc/$(pgrep -f RustDedicated | head -1)/cmdline | tr "\0" " "')

    if echo "${server_args}" | grep -qF "${DEFAULT_PASSWORD}"; then
        log_error "Default password found in server process arguments"
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "Default password is not in server process arguments"

    if echo "${server_args}" | grep -qF "+rcon.password ${generated}"; then
        log_success "Server process uses the generated password"
    else
        log_error "Server process is not using the generated password"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    log_test_pass "${TEST_NAME}"
    return 0
}

# Run test
test_rcon_default
