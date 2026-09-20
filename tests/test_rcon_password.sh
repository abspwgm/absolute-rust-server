#!/bin/bash
# =============================================================================
# Unit Test: RCON password resolution (no Docker required)
# Exercises resolve_rcon_password from scripts/common with plain bash
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_helpers.sh"

CHECKS_FAILED=0
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

check() {
    local description="$1"
    shift
    if "$@"; then
        log_pass "${description}"
    else
        log_fail "${description}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
}

# -----------------------------------------------------------------------------
# Run resolve_rcon_password in a clean subshell
# Results land in ${WORK_DIR}: resolved (the password), output (everything logged)
# -----------------------------------------------------------------------------
resolve_with() {
    local enabled="$1"
    local password="$2"
    (
        RCON_ENABLED="${enabled}"
        RCON_PASSWORD="${password}"
        source "${PROJECT_DIR}/scripts/common"
        RCON_PASSWORD_FILE="${WORK_DIR}/rcon_password"
        resolve_rcon_password > "${WORK_DIR}/output" 2>&1
        printf '%s' "${RCON_PASSWORD}" > "${WORK_DIR}/resolved"
    )
}

resolved() { cat "${WORK_DIR}/resolved"; }
file_password() { tr -d '\n' < "${WORK_DIR}/rcon_password"; }
reset_state() { rm -f "${WORK_DIR}/rcon_password" "${WORK_DIR}/resolved" "${WORK_DIR}/output"; }

log_test_start "rcon_password (unit)"

# Every denylisted default (and empty) must be replaced by a generated password
for default in "" changeme password your_secure_password admin rcon ChangeMe; do
    reset_state
    resolve_with true "${default}"
    check "default '${default}': password file written" test -f "${WORK_DIR}/rcon_password"
    check "default '${default}': file is mode 600" test "$(stat -c '%a' "${WORK_DIR}/rcon_password" 2>/dev/null)" == "600"
    check "default '${default}': generated length >= 24" test "$(file_password | wc -c)" -ge 24
    check "default '${default}': resolved password matches file" test "$(resolved)" == "$(file_password)"
    check "default '${default}': resolved password is not the default" test "$(resolved)" != "${default}"
    check "default '${default}': value is never logged" bash -c "! grep -qF '$(resolved)' '${WORK_DIR}/output'"
    check "default '${default}': log says where the file is" grep -q "${WORK_DIR}/rcon_password" "${WORK_DIR}/output"
done

# A generated password is reused on the next start, not rotated
reset_state
resolve_with true changeme
first="$(resolved)"
resolve_with true changeme
check "generated password is reused across restarts" test "$(resolved)" == "${first}"

# Two fresh generations differ
reset_state
resolve_with true changeme
check "fresh generation is random" test "$(resolved)" != "${first}"

# A user-supplied password is used unchanged and no file is written
reset_state
resolve_with true 'My-Own_S3cret'
check "custom password used unchanged" test "$(resolved)" == 'My-Own_S3cret'
check "custom password: no file written" test ! -e "${WORK_DIR}/rcon_password"

# RCON disabled: nothing is generated
reset_state
resolve_with false changeme
check "rcon disabled: no file written" test ! -e "${WORK_DIR}/rcon_password"
check "rcon disabled: password untouched" test "$(resolved)" == "changeme"

if [[ ${CHECKS_FAILED} -gt 0 ]]; then
    log_test_fail "rcon_password (unit): ${CHECKS_FAILED} check(s) failed"
    exit 1
fi

log_test_pass "rcon_password (unit)"
exit 0
