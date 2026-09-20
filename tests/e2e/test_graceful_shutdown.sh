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
# Bring the container back after the shutdown test, whatever the verdict was.
# A container left stopped fails every test that follows on someone else's
# behalf: restart_update has been reported red for exactly that reason.
#
# `docker compose up -d` against a container that is still exiting reports
# "Running" and does nothing, so start the container directly first and only
# fall back to compose if it has gone entirely.
# Everything the game server prints goes to files inside the container, never
# to `docker logs`: the wrapper's stdout is captured by supervisor into
# supervisor-rust.log, and rust-logfilter also writes its own rust-server.log.
# Counting matches in `docker logs` therefore always returned zero no matter
# what the server did.
server_output() {
    # `docker exec` cannot run against a stopped container, and the whole point
    # of this test is to inspect the server after it has shut down - so the
    # previous version silently returned nothing exactly when it mattered, and
    # the save count was measured against an empty string. `docker cp` reads
    # from a stopped container's filesystem, which is what is needed here.
    local tmp
    tmp="$(mktemp -d)"
    docker cp rust-server:/var/log/rust/supervisor-rust.log "${tmp}/" 2>/dev/null || true
    docker cp rust-server:/var/log/rust/rust-server.log "${tmp}/" 2>/dev/null || true
    cat "${tmp}"/*.log 2>/dev/null || true
    rm -rf "${tmp}"
    docker logs rust-server 2>&1
}

restart_container_for_following_tests() {
    log_info "Restarting the container for subsequent tests"
    docker start rust-server > /dev/null 2>&1 || {
        cd "$(dirname "${SCRIPT_DIR}")/.."
        docker compose -f docker-compose.test.yml up -d
    }

    local attempts=0
    while [[ "$(docker inspect -f '{{.State.Running}}' rust-server 2>/dev/null)" != "true" ]]; do
        if [[ ${attempts} -ge 30 ]]; then
            log_error "Container failed to restart after the graceful shutdown test"
            docker logs rust-server 2>&1 | tail -20 || true
            return 1
        fi
        sleep 2
        attempts=$((attempts + 1))
    done

    log_pass "Container restarted successfully"
    return 0
}

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
    saves_before="$(server_output | grep -c "Saving World" || true)"
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
    saves_after="$(server_output | grep -c "Saving World" || true)"
    [[ "${saves_after}" =~ ^[0-9]+$ ]] || saves_after=0

    if [[ "${saves_after}" -gt "${saves_before}" ]]; then
        log_pass "The server saved the world on shutdown (${saves_before} -> ${saves_after})"
    else
        log_error "No new save was written on shutdown (still ${saves_after})"

        # Two things can produce this, and the diagnostics have not so far been
        # able to tell them apart: the server really did not save, or it did and
        # "Saving World" is not the string this build prints. Both questions are
        # answered by the server's own output, which the captured artifacts have
        # been missing - they only held supervisor lines.
        log_error "=== any save-like line the server printed (case-insensitive) ==="
        server_output | grep -iE 'sav(e|ing)|persist|world' | tail -20 || true
        log_error "=== tail of the server's logs, copied out of the stopped container ==="
        server_output | tail -60 || true
        log_error "=== end ==="

        # Leave the container running even though this assertion failed, or
        # every test after this one fails as collateral rather than on its own
        # merits. restart_update has been failing this way.
        restart_container_for_following_tests
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    if ! restart_container_for_following_tests; then
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    log_test_pass "${TEST_NAME}"
    return 0
}

# Run test
test_graceful_shutdown
