#!/bin/bash
# =============================================================================
# Unit Test: dependency updates are configured (no Docker, no network)
# Every input this repository uses is pinned to an immutable ref, which is what
# the standard requires and also means nothing moves unless something moves it.
# Dependabot is that something, and this test is what keeps it honest.
#
# The failure this exists to prevent is the quiet one: a game repository
# generated from this template grows a new kind of dependency - a Python tool,
# an npm package - and nobody adds it to .github/dependabot.yml, so it stays
# pinned forever at whatever it was on the day it landed. Nothing fails, which
# is the problem.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${SCRIPT_DIR}/test_helpers.sh"

CONFIG="${PROJECT_DIR}/.github/dependabot.yml"
NAME="dependabot (unit)"

log_test_start "${NAME}"

check "the configuration exists" test -r "${CONFIG}"
if [[ ! -r "${CONFIG}" ]]; then
    # Nothing below can say anything useful without the file.
    finish "${NAME}"
fi

# The ecosystems the file declares. Parsed with sed rather than a YAML library
# because the fast tier installs nothing.
declared_ecosystems() {
    sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*package-ecosystem:[[:space:]]*["'"'"']\{0,1\}\([a-z-]\{1,\}\).*/\1/p' "${CONFIG}"
}

declares() {
    declared_ecosystems | grep -qx "$1"
}

# Maps a kind of file in the tree to the ecosystem that has to cover it. The
# patterns are what a new game adds without thinking about updates; the
# ecosystem is what it then owes this file.
covers() {
    local ecosystem="$1" label="$2"
    shift 2
    local pattern
    for pattern in "$@"; do
        if compgen -G "${PROJECT_DIR}/${pattern}" > /dev/null; then
            check "${label} is covered by the ${ecosystem} ecosystem" declares "${ecosystem}"
            return 0
        fi
    done
    return 0
}

covers github-actions "the workflow action pins" ".github/workflows/*.yml" ".github/workflows/*.yaml"
covers docker         "the base image digest"    "Dockerfile" "Dockerfile.*"
covers pip            "the Python dependencies"  "requirements*.txt" "pyproject.toml"
covers npm            "the Node dependencies"    "package.json"
covers gomod          "the Go modules"           "go.mod"
covers cargo          "the Rust crates"          "Cargo.toml"

ECOSYSTEMS=$(declared_ecosystems | grep -c .)
INTERVALS=$(grep -cE '^[[:space:]]*interval:' "${CONFIG}")
DIRECTORIES=$(grep -cE '^[[:space:]]*director(y|ies):' "${CONFIG}")

check "the file declares schema version 2" grep -qE '^version:[[:space:]]*2[[:space:]]*$' "${CONFIG}"
check "at least one ecosystem is declared" test "${ECOSYSTEMS}" -gt 0
# A block with no schedule never runs, and a block with no directory does not
# say what it is looking at. Both are silent in Dependabot's own UI.
check "every ecosystem has an update schedule" test "${INTERVALS}" -eq "${ECOSYSTEMS}"
check "every ecosystem names a directory" test "${DIRECTORIES}" -eq "${ECOSYSTEMS}"

finish "${NAME}"
