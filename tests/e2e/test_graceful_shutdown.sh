#!/bin/bash
# =============================================================================
# E2E Test: Graceful Shutdown
# Verifies that the server handles shutdown signals properly
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="graceful_shutdown"

# -----------------------------------------------------------------------------
# Test: Graceful Shutdown
# -----------------------------------------------------------------------------
test_graceful_shutdown() {
    log_test_start "${TEST_NAME}"

    # Verify container is running
    assert_container_running "rust-server"

    # Wait for server to be ready
    log_info "Waiting for server to be ready"
    if ! wait_for_log "rust-server" "Server startup complete" 600; then
        log_warn "Server may not be fully ready"
    fi

    # Give server time to stabilize
    sleep 10

    # Verify server process is running
    assert_process_running "rust-server" "RustDedicated"

    # Send graceful shutdown signal (SIGINT to container)
    # Count the saves already in the log, so we can require a NEW one. The old
    # assertion grepped docker logs for "saving|shutdown|stopping|SIGINT|
    # terminated", which matches supervisor's own chatter: it passed even while
    # the server was crash-looping and never saving a thing (#5, #14).
    local saves_before
    saves_before="$(docker logs rust-server 2>&1 | grep -c "Saving World" || true)"
    [[ "${saves_before}" =~ ^[0-9]+$ ]] || saves_before=0
    log_info "Saves in the log before shutdown: ${saves_before}"

    log_info "Sending graceful shutdown signal (SIGINT)"
    docker kill --signal=INT rust-server || true

    # Wait for the container to exit of its own accord. The budget has to exceed
    # the shutdown ladder: the server may take up to 120s to save, supervisor
    # waits 150s, and compose allows 180s.
    log_info "Waiting for the server to save and the container to exit"
    local waited=0
    while [[ "$(docker inspect -f '{{.State.Running}}' rust-server 2>/dev/null)" == "true" ]]; do
        if [[ ${waited} -ge 200 ]]; then
            log_error "Container still running ${waited}s after SIGINT"
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    # A graceful stop must not look like a kill. 137 is SIGKILL, which is what
    # happened before the ladder was aligned.
    local exit_code
    exit_code="$(docker inspect -f '{{.State.ExitCode}}' rust-server 2>/dev/null)"
    log_info "Container exited after ${waited}s with code ${exit_code}"
    if [[ "${exit_code}" == "137" ]]; then
        log_error "Container was SIGKILLed (137): the save window was cut short"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # The point of a graceful shutdown: the world was actually written.
    local saves_after
    saves_after="$(docker logs rust-server 2>&1 | grep -c "Saving World" || true)"
    [[ "${saves_after}" =~ ^[0-9]+$ ]] || saves_after=0

    if [[ "${saves_after}" -gt "${saves_before}" ]]; then
        log_pass "The server saved the world on shutdown (${saves_before} -> ${saves_after})"
    else
        log_error "No new save was written on shutdown (still ${saves_after})"
        log_error "=== last 40 log lines ==="
        docker logs rust-server 2>&1 | tail -40 || true
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # --- restart deterministically for the tests that follow ---------------
    # Previously this ran `docker compose up -d` against a container that was
    # still exiting; compose reported "Running", did nothing, and the container
    # never came back, which failed restart_update too.
    log_info "Restarting the container for subsequent tests"
    docker start rust-server > /dev/null 2>&1 || {
        cd "$(dirname "${SCRIPT_DIR}")/.."
        docker compose -f docker-compose.test.yml up -d
    }

    local attempts=0
    while [[ "$(docker inspect -f '{{.State.Running}}' rust-server 2>/dev/null)" != "true" ]]; do
        if [[ ${attempts} -ge 30 ]]; then
            log_error "Container failed to restart after graceful shutdown test"
            docker logs rust-server 2>&1 | tail -20 || true
            log_test_fail "${TEST_NAME}"
            return 1
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    log_pass "Container restarted successfully"

    log_test_pass "${TEST_NAME}"
    return 0
}

# Run test
test_graceful_shutdown
