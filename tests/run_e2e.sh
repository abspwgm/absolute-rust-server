#!/bin/bash
# =============================================================================
# E2E Test Runner - Orchestrates end-to-end tests for Rust server
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

# Source test helpers
source "${SCRIPT_DIR}/test_helpers.sh"

# Configuration
# Note: server_start test can take 40+ minutes for initial download
TEST_TIMEOUT="${TEST_TIMEOUT:-3600}"
STARTUP_WAIT="${STARTUP_WAIT:-3600}"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
FAILED_TESTS=()

# Create logs directory
LOGS_DIR="${PROJECT_DIR}/data/logs"
mkdir -p "${LOGS_DIR}"

# Master log file
MASTER_LOG="${LOGS_DIR}/e2e_run_$(date '+%Y%m%d_%H%M%S').log"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log_to_master() {
    echo "$*" | tee -a "${MASTER_LOG}"
}

# -----------------------------------------------------------------------------
# Export logs from container
# -----------------------------------------------------------------------------
export_container_logs() {
    local prefix="$1"
    local log_file="${LOGS_DIR}/${prefix}.log"

    log_info "Exporting logs to ${log_file}"
    docker logs rust-server > "${log_file}" 2>&1 || true
    log_pass "Logs exported to ${log_file}"
}

# -----------------------------------------------------------------------------
# Cleanup function
# -----------------------------------------------------------------------------
cleanup() {
    log_info "Cleaning up test environment"
    export_container_logs "$(date '+%Y%m%d_%H%M%S')_cleanup_final"
    # Must precede teardown: /var/log/rust only exists inside the container.
    export_container_diagnostics rust-server "${LOGS_DIR}/container"
    docker compose -f "${PROJECT_DIR}/docker-compose.test.yml" down -v 2>/dev/null || true
    docker rm -f rust-server 2>/dev/null || true
    docker volume rm rust-test-config rust-test-server 2>/dev/null || true
}

# Set trap for cleanup
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Run a single test
# -----------------------------------------------------------------------------
run_test() {
    local test_name="$1"
    local test_script="${SCRIPT_DIR}/e2e/test_${test_name}.sh"

    if [[ ! -f "${test_script}" ]]; then
        log_warn "Test script not found: ${test_script}"
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
        return 0
    fi

    log_to_master ""
    log_to_master "========================================"
    log_to_master "Running test: ${test_name}"
    log_to_master "========================================"

    local start_time
    start_time=$(date +%s)

    # Run test with timeout
    set +e
    timeout "${TEST_TIMEOUT}" bash "${test_script}"
    local exit_code=$?
    set -e

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ ${exit_code} -eq 0 ]]; then
        log_pass "Test passed: ${test_name} (${duration}s)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        export_container_logs "$(date '+%Y%m%d_%H%M%S')_${test_name}_PASSED"
    elif [[ ${exit_code} -eq 124 ]]; then
        log_fail "Test timed out: ${test_name} (${TEST_TIMEOUT}s)"
        log_info "=== Container Logs (last 100 lines) ==="
        docker logs rust-server --tail 100 2>&1 || true
        log_info "=== End Container Logs ==="
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("${test_name}")
        export_container_logs "$(date '+%Y%m%d_%H%M%S')_${test_name}_FAILED"
    else
        log_fail "Test failed: ${test_name} (exit code: ${exit_code})"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("${test_name}")
        export_container_logs "$(date '+%Y%m%d_%H%M%S')_${test_name}_FAILED"
    fi

    return ${exit_code}
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_to_master ""
    log_to_master "========================================"
    log_to_master "Absolute Rust Server - E2E Test Suite"
    log_to_master "========================================"
    log_to_master "Master log: ${MASTER_LOG}"

    # Setup phase
    log_to_master ""
    log_to_master "========================================"
    log_to_master "Setting up test environment"
    log_to_master "========================================"

    # Cleanup any existing containers
    log_info "Cleaning up any existing containers"
    docker compose -f "${PROJECT_DIR}/docker-compose.test.yml" down -v 2>/dev/null || true
    docker rm -f rust-server 2>/dev/null || true
    docker volume rm rust-test-config rust-test-server 2>/dev/null || true

    # Build image (skip if already built by CI)
    if docker image inspect absolute-rust-server:test > /dev/null 2>&1; then
        log_info "Using pre-built Docker image (absolute-rust-server:test)"
    else
        log_info "Building Docker image"
        docker compose -f "${PROJECT_DIR}/docker-compose.test.yml" build
    fi
    log_pass "Test environment ready"

    # Start container
    log_info "Starting test container"
    docker compose -f "${PROJECT_DIR}/docker-compose.test.yml" up -d
    log_pass "Container started"

    # Run tests
    local tests=(
        "server_start"
        "steam_init"
        "rcon_default"
        "server_query"
        "backup"
        "graceful_shutdown"
        "restart_update"
    )

    for test in "${tests[@]}"; do
        run_test "${test}" || true
    done

    # Export final summary
    export_container_logs "$(date '+%Y%m%d_%H%M%S')_final_summary"

    # Print summary
    log_to_master ""
    log_to_master "========================================"
    log_to_master "Test Summary"
    log_to_master "========================================"
    log_to_master ""
    log_to_master "  Passed:  ${TESTS_PASSED}"
    log_to_master "  Failed:  ${TESTS_FAILED}"
    log_to_master "  Skipped: ${TESTS_SKIPPED}"
    log_to_master "  Total:   $((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))"

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        log_to_master ""
        log_to_master "Failed tests:"
        for test in "${FAILED_TESTS[@]}"; do
            log_to_master "  - ${test}"
        done
    fi

    log_to_master ""
    log_info "Logs saved to: ${LOGS_DIR}/"
    log_info "Master log: ${MASTER_LOG}"

    # Exit with failure if any tests failed
    if [[ ${TESTS_FAILED} -gt 0 ]]; then
        log_to_master ""
        log_to_master "========================================"
        log_to_master "TESTS FAILED"
        log_to_master "========================================"
        exit 1
    fi

    log_to_master ""
    log_to_master "========================================"
    log_to_master "ALL TESTS PASSED"
    log_to_master "========================================"
    exit 0
}

# Run main
main "$@"
