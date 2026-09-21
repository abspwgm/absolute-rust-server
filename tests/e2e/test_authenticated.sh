#!/bin/bash
# =============================================================================
# E2E Test: Authenticated session (ready ladder rung 4, standard 2.10)
# An admin session logs in over WebRCON with the server's own credential and
# reads the server's live state back: its name, its slots, its player count.
# =============================================================================
# Stand-in, named as one (2.10): no headless Rust client exists, and scripting
# the real game client against EasyAntiCheat is neither possible nor honest.
# What this proves is that the server accepts an authenticated session and
# reports its own state through it - not that a player joined.
#
# It also proves the player count the idle guard and the backup schedule depend
# on is real. It was a placeholder that always said 0.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="authenticated"

RCON="/opt/rust/scripts/rust-rcon"
EXPECTED_NAME="E2E Test Server"
EXPECTED_MAX_PLAYERS=4

test_authenticated() {
    log_test_start "${TEST_NAME}"
    assert_container_running "rust-server"

    if ! wait_for_log "rust-server" "Server startup complete" 600; then
        log_warn "Server may not be fully ready"
    fi

    # jq runs inside the container: the image ships it, the runner may not.
    local info
    if ! info="$(docker exec rust-server sh -c "${RCON} serverinfo" 2>&1)"; then
        log_error "An admin session could not log in and run serverinfo over WebRCON"
        log_error "${info}"
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_success "Logged in over WebRCON with the server's own credential"

    local fields hostname max_players players
    fields="$(docker exec -i rust-server jq -r '[.Hostname, .MaxPlayers, .Players] | @tsv' <<< "${info}" 2>&1)" || {
        log_error "serverinfo did not return the JSON it documents: ${info:0:300}"
        log_test_fail "${TEST_NAME}"
        return 1
    }
    IFS=$'\t' read -r hostname max_players players <<< "${fields}"
    log_info "The server reports: hostname='${hostname}' players=${players}/${max_players}"

    local failed=0
    if [[ "${hostname}" == "${EXPECTED_NAME}" ]]; then
        log_success "It reports the configured name"
    else
        log_error "Expected hostname '${EXPECTED_NAME}', got '${hostname}'"
        failed=1
    fi
    if [[ "${max_players}" == "${EXPECTED_MAX_PLAYERS}" ]]; then
        log_success "It reports the configured ${EXPECTED_MAX_PLAYERS} slots"
    else
        log_error "Expected ${EXPECTED_MAX_PLAYERS} slots, got '${max_players}'"
        failed=1
    fi

    # The count the idle guard reads, through the same function it calls.
    local count
    if count="$(docker exec rust-server bash -c 'source /opt/rust/scripts/common && get_player_count' 2>/dev/null)" \
        && [[ "${count}" =~ ^[0-9]+$ ]] && [[ "${count}" == "${players}" ]]; then
        log_success "get_player_count reads the live count (${count}), as the idle guard will"
    else
        log_error "get_player_count returned '${count:-<nothing>}', expected the live count ${players}"
        failed=1
    fi

    # An authenticated session means nothing if any password gets in.
    if docker exec -e RCON_PASSWORD=not-the-password-this-server-uses rust-server "${RCON}" serverinfo >/dev/null 2>&1; then
        log_error "WebRCON accepted a wrong password"
        failed=1
    else
        log_success "A wrong password is refused"
    fi

    if [[ ${failed} -ne 0 ]]; then
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_test_pass "${TEST_NAME}"
    return 0
}

test_authenticated
