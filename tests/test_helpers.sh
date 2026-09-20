#!/bin/bash
# =============================================================================
# Test Helpers - Common functions for E2E tests
# =============================================================================

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Logging functions
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------
log_test_start() {
    local test_name="$1"
    echo ""
    echo "----------------------------------------"
    echo "Starting test: ${test_name}"
    echo "----------------------------------------"
}

log_test_pass() {
    local test_name="$1"
    echo -e "${GREEN}----------------------------------------${NC}"
    echo -e "${GREEN}Test PASSED: ${test_name}${NC}"
    echo -e "${GREEN}----------------------------------------${NC}"
}

log_test_fail() {
    local test_name="$1"
    echo -e "${RED}----------------------------------------${NC}"
    echo -e "${RED}Test FAILED: ${test_name}${NC}"
    echo -e "${RED}----------------------------------------${NC}"
}

# -----------------------------------------------------------------------------
# Docker exec wrapper (handles Git Bash path conversion on Windows)
# -----------------------------------------------------------------------------
docker_exec() {
    local container="$1"
    shift
    MSYS_NO_PATHCONV=1 docker exec "${container}" "$@"
}

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------
assert_container_running() {
    local container="$1"
    if [[ $(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null) == "true" ]]; then
        log_info "Container '${container}' is running"
        return 0
    else
        log_error "Container '${container}' is not running"
        return 1
    fi
}

# How often the wait_* helpers poll. Overridable so unit tests need no real time.
E2E_POLL_INTERVAL="${E2E_POLL_INTERVAL:-5}"

# The one place that asks a container whether a process is up. Every process
# check goes through here so the polling logic above it can be unit tested.
process_is_running() {
    local container="$1"
    local process="$2"
    MSYS_NO_PATHCONV=1 docker exec "${container}" pgrep -f "${process}" > /dev/null 2>&1
}

assert_process_running() {
    local container="$1"
    local process="$2"
    if process_is_running "${container}" "${process}"; then
        log_info "Process '${process}' is running"
        return 0
    else
        log_error "Process '${process}' is not running"
        return 1
    fi
}

assert_file_exists() {
    local container="$1"
    local file_path="$2"
    if MSYS_NO_PATHCONV=1 docker exec "${container}" test -f "${file_path}" 2>/dev/null; then
        log_info "File exists: ${file_path}"
        return 0
    else
        log_error "File does not exist: ${file_path}"
        return 1
    fi
}

assert_directory_exists() {
    local container="$1"
    local dir_path="$2"
    if MSYS_NO_PATHCONV=1 docker exec "${container}" test -d "${dir_path}" 2>/dev/null; then
        log_info "Directory exists: ${dir_path}"
        return 0
    else
        log_error "Directory does not exist: ${dir_path}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Wait Functions
# -----------------------------------------------------------------------------
wait_for_log() {
    local container="$1"
    local pattern="$2"
    local timeout="${3:-60}"
    local elapsed=0

    while [[ ${elapsed} -lt ${timeout} ]]; do
        # Check docker logs
        if docker logs "${container}" 2>&1 | grep -qi "${pattern}"; then
            return 0
        fi
        # Also check the rust server log file inside container
        if docker_exec "${container}" grep -qi "${pattern}" /var/log/rust/rust-server.log 2>/dev/null; then
            return 0
        fi
        # Check supervisor stdout log
        if docker_exec "${container}" grep -qi "${pattern}" /var/log/rust/supervisor-rust.log 2>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    return 1
}

wait_for_container_healthy() {
    local container="$1"
    local timeout="${2:-300}"
    local elapsed=0

    while [[ ${elapsed} -lt ${timeout} ]]; do
        local health
        health=$(docker inspect -f '{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "unknown")
        if [[ "${health}" == "healthy" ]]; then
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    return 1
}

wait_for_port() {
    local container="$1"
    local port="$2"
    local protocol="${3:-tcp}"
    local timeout="${4:-60}"
    local elapsed=0

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if [[ "${protocol}" == "tcp" ]]; then
            if docker_exec "${container}" nc -z localhost "${port}" 2>/dev/null; then
                return 0
            fi
        else
            # For UDP, check /proc/net/udp
            local port_hex
            printf -v port_hex "%04X" "${port}"
            if docker_exec "${container}" cat /proc/net/udp 2>/dev/null | grep -qi ":${port_hex}"; then
                return 0
            fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    return 1
}

wait_for_process() {
    local container="$1"
    local process="$2"
    local timeout="${3:-60}"
    local elapsed=0

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if process_is_running "${container}" "${process}"; then
            return 0
        fi
        sleep "${E2E_POLL_INTERVAL}"
        elapsed=$((elapsed + 5))
    done

    return 1
}

# Wait for a process to come up and then stay up continuously for stable_secs.
#
# A process that is merely present at one instant proves nothing when supervisor
# has autorestart=true: RustDedicated can die and be respawned, so a single
# check passes or fails on timing alone (#2). Requiring an unbroken run makes a
# crash-restart loop fail deterministically instead.
wait_for_process_stable() {
    local container="$1"
    local process="$2"
    local timeout="${3:-60}"
    local stable_secs="${4:-30}"
    local elapsed=0
    local stable=0

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if process_is_running "${container}" "${process}"; then
            if [[ ${stable} -ge ${stable_secs} ]]; then
                log_info "Process '${process}' has been up for ${stable}s"
                return 0
            fi
            stable=$((stable + 5))
        elif [[ ${stable} -gt 0 ]]; then
            log_warn "Process '${process}' disappeared after ${stable}s: not stable yet"
            stable=0
        fi
        sleep "${E2E_POLL_INTERVAL}"
        elapsed=$((elapsed + 5))
    done

    if [[ ${stable} -gt 0 ]]; then
        log_error "Process '${process}' never stayed up for ${stable_secs}s"
    else
        log_error "Process '${process}' never started within ${timeout}s"
    fi
    return 1
}

# How many times the wrapper's watchdog has restarted the server.
#
# This is the only deterministic crash-loop signal available. A stability window
# cannot prove "never crashes": run 35508220541 crash-looped every 35s while
# still satisfying a 60s window, because the crash took ~67s. Every restart is
# logged by scripts/rust-server to its supervisor stdout logfile.
watchdog_restart_count() {
    local container="$1"
    local count
    count="$(docker_exec "${container}" grep -c 'Server process not running, restarting' \
        /var/log/rust/supervisor-rust.log 2>/dev/null | tr -d '\r')"
    # grep -c exits non-zero with no matches, and the file may not exist yet.
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
    echo "${count}"
}

# Fail if the server has been restarted behind our back.
assert_no_watchdog_restarts() {
    local container="$1"
    local count
    count="$(watchdog_restart_count "${container}")"

    if [[ "${count}" -eq 0 ]]; then
        log_info "No watchdog restarts: the server has not crashed"
        return 0
    fi

    log_error "The server has been restarted ${count} time(s) by the watchdog: it is crash-looping"
    return 1
}

# -----------------------------------------------------------------------------
# Diagnostics
# -----------------------------------------------------------------------------
# Report what supervisor thinks of the server. When the process check fails,
# this is what distinguishes "never started" from "crash-restart loop".
report_supervisor_state() {
    local container="$1"

    log_info "=== supervisor state ==="
    docker_exec "${container}" supervisorctl status 2>&1 || true
    log_info "=== supervisord events (spawned/exited/backoff) ==="
    docker_exec "${container}" grep -Ei 'spawned|exited|backoff|fatal|stopped' \
        /var/log/rust/supervisord.log 2>&1 | tail -40 || true

    # The smoking gun for a crash loop. supervisor only manages the
    # /opt/rust/scripts/rust-server wrapper, which never exits, so supervisor
    # never reports RustDedicated dying: the wrapper's own 30s watchdog restarts
    # it and logs "Server process not running, restarting..." to its stdout
    # logfile -- a file inside the container, never container stdout.
    log_info "=== wrapper watchdog restarts ==="
    docker_exec "${container}" grep -c 'Server process not running, restarting' \
        /var/log/rust/supervisor-rust.log 2>&1 || true
    docker_exec "${container}" grep -E 'restarting|Server started with PID|Failed to start server' \
        /var/log/rust/supervisor-rust.log 2>&1 | tail -20 || true
    log_info "=== server process table ==="
    docker_exec "${container}" ps -eo pid,ppid,etime,stat,comm,args 2>&1 | tail -30 || true
    log_info "=== end supervisor state ==="
}

# Copy the logs that only exist inside the container out to the host.
#
# RustDedicated's own output and supervisord's event log live at /var/log/rust
# (see config/supervisord.conf) and used to die with the container: run_e2e.sh
# tears it down in its exit trap, before the workflow collects artifacts, so
# every failure arrived unexplainable (#2). Call this before any teardown.
export_container_diagnostics() {
    local container="$1"
    local dest="$2"

    if ! docker inspect "${container}" > /dev/null 2>&1; then
        log_warn "Container '${container}' is gone; no in-container logs to collect"
        return 0
    fi

    mkdir -p "${dest}"
    log_info "Collecting in-container logs from ${container}:/var/log/rust"
    if docker cp "${container}:/var/log/rust/." "${dest}/" 2>/dev/null; then
        log_pass "In-container logs saved to ${dest}/"
    else
        log_warn "Could not copy /var/log/rust from ${container}"
    fi

    docker inspect "${container}" > "${dest}/container-inspect.json" 2>&1 || true
    report_supervisor_state "${container}" > "${dest}/supervisor-state.log" 2>&1 || true
    log_pass "Diagnostics saved to ${dest}/"
}
