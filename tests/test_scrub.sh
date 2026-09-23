#!/bin/bash
# =============================================================================
# Unit Test: the runner's address never leaves a test's output (no Docker)
# A game learns the lab's public address from Steam and prints it; on lab
# hardware the workflow masks that address in the job log and fails a suite
# that prints it. These helpers are what let a test dump a container's log
# without doing that, and this is the test that keeps them - and every dump in
# tests/e2e - honest.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_helpers.sh"

check() {
    local name="$1"
    shift
    if "$@"; then
        log_pass "${name}"
    else
        log_fail "${name}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
}

# TEST-NET-3 and the documentation prefix: never routed, so never anyone's.
V4="203.0.113.9"
V6="2001:db8::9"
LINE="Public IP is ${V4}. udp/ip : ?.?.?.?:? (public IP from Steam: ${V4})"

scrubbed="$(RUNNER_PUBLIC_ADDRESS="${V4}" scrub_addresses <<< "${LINE}")"
check "the address is gone" bash -c "! grep -qF -- '${V4}' <<< \"\$1\"" _ "${scrubbed}"
check "a placeholder says something was there" grep -q '<runner-public-address>' <<< "${scrubbed}"
check "every occurrence goes, not only the first" \
    [ "$(grep -o '<runner-public-address>' <<< "${scrubbed}" | wc -l)" -eq 2 ]

both="$(RUNNER_PUBLIC_ADDRESS="${V4} ${V6}" scrub_addresses <<< "v6 ${V6} and v4 ${V4}")"
check "more than one address, space-separated, all scrubbed" \
    bash -c "! grep -qE -- '${V4}|${V6}' <<< \"\$1\"" _ "${both}"

untouched="$(RUNNER_PUBLIC_ADDRESS="" scrub_addresses <<< "${LINE}")"
check "with nothing to hide, the output is unchanged" [ "${untouched}" = "${LINE}" ]

literal="$(RUNNER_PUBLIC_ADDRESS="${V4}" scrub_addresses <<< "203x0x113x9 is not the address")"
check "the dots are literal, not wildcards" [ "${literal}" = "203x0x113x9 is not the address" ]

# Every `docker logs` in the suite is read by a computation (a $(...) or a
# grep) or scrubbed on its way out. Anything else is a dump the scrub never
# sees, whatever it is piped through afterwards. A comment that mentions the
# command is not a dump.
raw="$(grep -rn 'docker logs' "${PROJECT_DIR}/tests/e2e" | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#|[|] *grep|[$][(]docker logs|[|] *scrub_addresses' || true)"
if [[ -z "${raw}" ]]; then
    log_pass "no test dumps a container's log without the scrub"
else
    log_fail "a test dumps a container's log straight into its output:"
    printf '  %s\n' "${raw}"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

finish "scrub (unit)"
