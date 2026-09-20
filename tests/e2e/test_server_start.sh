#!/bin/bash
# =============================================================================
# E2E Test: Server Start
# Verifies that the server starts correctly and becomes ready
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="server_start"

# -----------------------------------------------------------------------------
# Test: Server Start
# -----------------------------------------------------------------------------
test_server_start() {
    log_test_start "${TEST_NAME}"

    # Verify container is running
    assert_container_running "rust-server"

    # Check that steamcmd update ran
    log_info "Checking for SteamCMD update execution"
    if wait_for_log "rust-server" "Starting Rust server update" 120; then
        log_info "SteamCMD update started"
    else
        log_warn "SteamCMD update log not found (may have used cached files)"
    fi

    # Wait for server binary to be present (includes download time)
    # Rust server download is ~8GB and can take 30+ minutes on first run
    log_info "Waiting for server binary (includes SteamCMD download time)"
    log_info "Note: First run may take 30-40 minutes for download"
    local binary_wait_start
    binary_wait_start=$(date +%s)
    local max_binary_wait=2400  # 40 minutes for download

    while true; do
        local elapsed=$(($(date +%s) - binary_wait_start))

        # First check if container is still running
        if [[ $(docker inspect -f '{{.State.Running}}' rust-server 2>/dev/null) != "true" ]]; then
            log_error "Container stopped unexpectedly during startup"
            log_error "=== Container Logs ==="
            docker logs rust-server 2>&1 || true
            log_error "=== End Container Logs ==="
            return 1
        fi

        # Check for server binary
        if MSYS_NO_PATHCONV=1 docker exec rust-server test -f /opt/rust/server/RustDedicated 2>/dev/null; then
            log_success "Server binary found after ${elapsed}s"
            break
        fi

        # Timeout check
        if [[ ${elapsed} -ge ${max_binary_wait} ]]; then
            log_error "Server binary not found after ${max_binary_wait}s"
            log_error "=== Container Logs ==="
            docker logs rust-server 2>&1 || true
            log_error "=== End Container Logs ==="
            return 1
        fi

        # Progress updates every 60 seconds
        if [[ $((elapsed % 60)) -eq 0 ]] && [[ ${elapsed} -gt 0 ]]; then
            log_info "Still waiting for server binary... (${elapsed}s elapsed)"
            # Show recent log activity
            docker logs rust-server --tail 5 2>&1 || true
        fi

        sleep 10
    done

    # Wait for server to start (look for startup complete message or other success indicators)
    log_info "Waiting for server to initialize (this may take several minutes)"
    log_info "Looking for 'Server startup complete' or 'SteamServer' in logs..."

    # The server is up when its process is up and *stays* up.
    #
    # A startup line in the log only proves the server was alive at some earlier
    # point. Because supervisor runs with autorestart=true, RustDedicated can die
    # and be respawned, and the fallback "SteamServer" search below would match a
    # line written minutes before that crash - which is how a crash-restart loop
    # used to report "initialized" and then fail the process assert on timing
    # alone (#2). So gate on an unbroken run of the process, and treat the log
    # lines as supplementary detail rather than proof.
    log_info "Waiting for the server process to come up and stay up"
    if ! wait_for_process_stable "rust-server" "RustDedicated" \
            "${SERVER_STABLE_TIMEOUT:-900}" "${SERVER_STABLE_SECS:-60}"; then
        log_error "Server process did not stay up"
        report_supervisor_state "rust-server"
        log_error "=== Container logs ==="
        docker logs rust-server --tail 100 2>&1 || true
        log_error "=== End container logs ==="
        export_container_diagnostics rust-server "${LOGS_DIR:-data/logs}/container"
        return 1
    fi
    log_success "Server process has been up continuously"

    # Supplementary: which startup message the server got to, for the log only.
    if wait_for_log "rust-server" "Server startup complete" 60; then
        log_info "Startup message found: 'Server startup complete'"
    elif wait_for_log "rust-server" "SteamServer" 10; then
        log_info "Startup message found: 'SteamServer'"
    else
        log_info "No startup message seen yet; the process is up, which is the gate"
    fi

    log_test_pass "${TEST_NAME}"
    return 0
}

# Run test
test_server_start
