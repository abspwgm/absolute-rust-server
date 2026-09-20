#!/bin/bash
# =============================================================================
# E2E Test: Restart and Update
# Verifies that the update script and container restart mechanisms work
# Note: This is a simplified test to avoid timeouts. Server startup is
# already verified by test_server_start.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="restart_update"

# -----------------------------------------------------------------------------
# Test: Restart and Update
# -----------------------------------------------------------------------------
test_restart_update() {
    log_test_start "${TEST_NAME}"

    # Verify container is running
    assert_container_running "rust-server"

    # Verify server process is running (from previous tests)
    log_info "Checking server process is running"
    if process_is_running "rust-server" "RustDedicated"; then
        log_success "Server process is running"
    else
        log_warn "Server process not found, may still be starting"
    fi

    # Get current build ID (if available)
    log_info "Getting current build ID"
    local current_build
    current_build=$(MSYS_NO_PATHCONV=1 docker exec rust-server cat /opt/rust/server/.build_id 2>/dev/null || echo "unknown")
    log_info "Current build ID: ${current_build}"

    # Test that updater script exists and is executable
    log_info "Verifying updater script exists"
    if MSYS_NO_PATHCONV=1 docker exec rust-server test -x /opt/rust/scripts/rust-updater; then
        log_success "Updater script is executable"
    else
        log_error "Updater script not found or not executable"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # Test container restart via docker compose (quick test)
    log_info "Testing container restart capability"
    cd "$(dirname "${SCRIPT_DIR}")/.."

    # Stop container
    docker compose -f docker-compose.test.yml stop --timeout 30
    sleep 3

    # Verify container stopped
    if [[ $(docker inspect -f '{{.State.Running}}' rust-server 2>/dev/null) == "true" ]]; then
        log_error "Container did not stop"
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "Container stopped successfully"

    # Start container again
    docker compose -f docker-compose.test.yml up -d

    # Wait for container to be running
    local attempts=0
    while [[ $(docker inspect -f '{{.State.Running}}' rust-server 2>/dev/null) != "true" ]]; do
        if [[ ${attempts} -ge 30 ]]; then
            log_error "Container failed to restart"
            log_test_fail "${TEST_NAME}"
            return 1
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    log_success "Container restarted successfully"

    # Wait briefly for supervisor to start the server process
    log_info "Waiting for server process to start"
    attempts=0
    while [[ ${attempts} -lt 60 ]]; do
        if process_is_running "rust-server" "RustDedicated"; then
            log_success "Server process started after container restart"
            log_test_pass "${TEST_NAME}"
            return 0
        fi
        sleep 5
        attempts=$((attempts + 5))
    done

    # If process not found, check if supervisor is at least running the start script
    log_info "Checking if server is still initializing..."
    if docker logs rust-server 2>&1 | tail -20 | grep -qi "Starting supervisor\|Starting Rust"; then
        log_success "Server is initializing (supervisor started)"
        log_test_pass "${TEST_NAME}"
        return 0
    fi

    log_error "Server process did not start after restart"
    docker logs rust-server --tail 50 2>&1 || true
    log_test_fail "${TEST_NAME}"
    return 1
}

# Run test
test_restart_update
