#!/bin/bash
# =============================================================================
# E2E Test: Discoverable (ready ladder rung 3, standard 2.10)
# The server answers a Steam server-browser query (A2S_INFO) the way a player's
# browser sees it: the right name, the right game, the right slot count.
# =============================================================================
# server_query proves the ports are bound. That is "reachable", not
# "discoverable": a bound port that answers nothing, or answers with the wrong
# name, is a server nobody can find. This asks the question the browser asks,
# from outside the container, through the published port.
#
# The query is sent from the runner with bash's /dev/udp, so it needs nothing
# installed. A2S_INFO has required a challenge round trip since 2020: the first
# reply may be S2C_CHALLENGE (0x41), and the query is resent with it appended.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test_helpers.sh"

TEST_NAME="discoverable"

QUERY_PORT="${QUERY_PORT:-27015}"
# What docker-compose.test.yml configures, and so what the browser must show.
EXPECTED_NAME="E2E Test Server"
EXPECTED_FOLDER="rust"
EXPECTED_MAX_PLAYERS=4

A2S_QUERY='\xFF\xFF\xFF\xFFTSource Engine Query\x00'

# a2s_info ; the server's reply as a lowercase hex string, or nothing
a2s_info() {
    local fd reply challenge escaped=""
    exec {fd}<>"/dev/udp/127.0.0.1/${QUERY_PORT}" || return 1
    # One printf per datagram: two writes would be two packets.
    printf '%b' "${A2S_QUERY}" >&"${fd}"
    reply="$(timeout 5 dd bs=1400 count=1 status=none <&"${fd}" | od -An -v -tx1 | tr -d ' \n')" || true
    if [[ "${reply:0:10}" == "ffffffff41" ]]; then
        challenge="${reply:10:8}"
        for (( i = 0; i < 8; i += 2 )); do escaped+="\\x${challenge:i:2}"; done
        printf '%b' "${A2S_QUERY}${escaped}" >&"${fd}"
        reply="$(timeout 5 dd bs=1400 count=1 status=none <&"${fd}" | od -An -v -tx1 | tr -d ' \n')" || true
    fi
    exec {fd}>&-
    printf '%s' "${reply}"
}

# cstring <var> ; reads a NUL-terminated string at POS in HEX into <var>
cstring() {
    local out=""
    while [[ ${POS} -lt ${#HEX} && "${HEX:POS:2}" != "00" ]]; do
        out+="\\x${HEX:POS:2}"
        POS=$(( POS + 2 ))
    done
    POS=$(( POS + 2 ))
    printf -v "$1" '%b' "${out}"
}

# byte <var> ; one unsigned byte at POS. A reply cut short reads as 0 rather
# than aborting the test under set -e; the assertions then say what is wrong.
byte() {
    local h="${HEX:POS:2}"
    printf -v "$1" '%d' "0x${h:-00}"
    POS=$(( POS + 2 ))
}

test_discoverable() {
    log_test_start "${TEST_NAME}"
    assert_container_running "rust-server"

    if ! wait_for_log "rust-server" "Server startup complete" 600; then
        log_warn "Server may not be fully ready"
    fi

    # The query port can lag the game port by a few seconds after startup.
    local attempt
    HEX=""
    for attempt in 1 2 3 4 5 6; do
        HEX="$(a2s_info)" || true
        [[ "${HEX:0:10}" == "ffffffff49" ]] && break
        log_info "No A2S_INFO reply yet (attempt ${attempt}); retrying"
        sleep 5
    done

    if [[ "${HEX:0:10}" != "ffffffff49" ]]; then
        log_error "The server did not answer a server-browser query on ${QUERY_PORT}/udp"
        log_error "Reply (hex): ${HEX:-<none>}"
        log_test_fail "${TEST_NAME}"
        return 1
    fi

    # Header (4 x FF), type 'I', protocol, then name, map, folder, game,
    # a 16-bit app id, players, max players, bots, ..., version.
    local protocol name map folder game players max_players bots
    POS=10
    byte protocol
    cstring name
    cstring map
    cstring folder
    cstring game
    POS=$(( POS + 4 ))   # app id
    byte players
    byte max_players
    byte bots
    log_info "Browser sees: name='${name}' map='${map}' folder='${folder}' game='${game}' players=${players}/${max_players} bots=${bots}"

    local failed=0
    if [[ "${name}" == "${EXPECTED_NAME}" ]]; then
        log_success "The browser shows the configured name"
    else
        log_error "Expected name '${EXPECTED_NAME}', the browser shows '${name}'"
        failed=1
    fi
    if [[ "${folder}" == "${EXPECTED_FOLDER}" ]]; then
        log_success "It identifies as ${EXPECTED_FOLDER}"
    else
        log_error "Expected game folder '${EXPECTED_FOLDER}', got '${folder}'"
        failed=1
    fi
    if [[ "${max_players}" -eq ${EXPECTED_MAX_PLAYERS} ]]; then
        log_success "It offers the configured ${EXPECTED_MAX_PLAYERS} slots"
    else
        log_error "Expected ${EXPECTED_MAX_PLAYERS} slots, the browser shows ${max_players}"
        failed=1
    fi

    if [[ ${failed} -ne 0 ]]; then
        log_test_fail "${TEST_NAME}"
        return 1
    fi
    log_test_pass "${TEST_NAME}"
    return 0
}

test_discoverable
