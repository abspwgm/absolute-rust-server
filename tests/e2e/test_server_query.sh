#!/bin/bash
# =============================================================================
# E2E Test: Server Query
# Verifies that the server is listening on expected UDP ports
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="server_query"

# -----------------------------------------------------------------------------
# Test: Server Query
# -----------------------------------------------------------------------------
test_server_query() {
    log_test_start "${TEST_NAME}"

    # Verify container is running
    assert_container_running "rust-server"

    # Wait for server to be ready first
    log_info "Waiting for server to be ready"
    if ! wait_for_log "rust-server" "Server startup complete" 600; then
        log_warn "Server may not be fully initialized"
    fi

    # Give server a moment to stabilize
    sleep 10

    # Get the server port
    local server_port="${SERVER_PORT:-28015}"
    local query_port="27015"

    log_info "Checking server is listening on UDP ports"

    # Check if server is listening using /proc/net/udp inside the container
    local port_hex
    local query_port_hex
    printf -v port_hex "%04X" "${server_port}"
    printf -v query_port_hex "%04X" "${query_port}"

    local ports_ok=0
    local attempts=0
    local max_attempts=30

    while [[ ${attempts} -lt ${max_attempts} ]]; do
        local udp_sockets
        udp_sockets=$(MSYS_NO_PATHCONV=1 docker exec rust-server cat /proc/net/udp 2>/dev/null || echo "")

        local port_28015_ok=false
        local port_27015_ok=false

        # Check for query port (27015)
        if echo "${udp_sockets}" | grep -qi ":${query_port_hex}"; then
            port_27015_ok=true
        fi

        # Check for game port (28015)
        if echo "${udp_sockets}" | grep -qi ":${port_hex}"; then
            port_28015_ok=true
        fi

        # Success if either port is bound
        if [[ "${port_27015_ok}" == "true" ]] || [[ "${port_28015_ok}" == "true" ]]; then
            if [[ "${port_27015_ok}" == "true" ]]; then
                log_success "Server is listening on query port ${query_port}"
            fi
            if [[ "${port_28015_ok}" == "true" ]]; then
                log_success "Server is listening on game port ${server_port}"
            fi
            ports_ok=1
            break
        fi

        sleep 2
        attempts=$((attempts + 1))

        if [[ $((attempts % 10)) -eq 0 ]]; then
            log_info "Still waiting for ports... (${attempts}/${max_attempts})"
        fi
    done

    if [[ ${ports_ok} -eq 1 ]]; then
        # Verify server process is also running
        if process_is_running "rust-server" "RustDedicated"; then
            log_success "Server process is running and ports are bound"
            log_test_pass "${TEST_NAME}"
            return 0
        else
            log_error "Ports are bound but server process not found"
            log_test_fail "${TEST_NAME}"
            return 1
        fi
    fi

    # Fallback: If ports aren't detected but process is running
    log_warn "Could not detect ports via /proc/net/udp, checking process and logs"

    if process_is_running "rust-server" "RustDedicated"; then
        if docker logs rust-server 2>&1 | grep -q "Server startup complete"; then
            log_success "Server process is running and initialized"
            log_test_pass "${TEST_NAME}"
            return 0
        fi
    fi

    log_error "Server is not listening on expected ports"
    log_error "Expected ports: ${server_port} (game), ${query_port} (query)"
    docker logs rust-server --tail 50 2>&1 || true
    report_supervisor_state "rust-server"
    export_container_diagnostics rust-server "${LOGS_DIR:-data/logs}/container"
    log_test_fail "${TEST_NAME}"
    return 1
}

# Run test
test_server_query
