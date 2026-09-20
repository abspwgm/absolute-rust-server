#!/bin/bash
# =============================================================================
# Unit test: install_steam_sdk
# =============================================================================
# Needs no Docker. Lays out fake SteamCMD trees under TEST_ROOT and checks the
# server user ends up with a readable steamclient.so.
#
# Guards #14: SteamCMD runs as root and leaves steamclient.so under /root, which
# is mode 700. The server runs as the rust user, so it could not read it, Steam
# init failed on every start, and the server crash-looped every 35 seconds. The
# server had never once started successfully.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

ROOT=""

# make_source <path-under-ROOT> <contents>
make_source() {
    mkdir -p "${ROOT}/$(dirname "$1")"
    printf '%s' "$2" > "${ROOT}/$1"
}

# fresh_root: an empty TEST_ROOT with the server user's home present
fresh_root() {
    ROOT="${WORK}/root$RANDOM"
    mkdir -p "${ROOT}/home/rust"
}

# install: run install_steam_sdk against ROOT ; sets RC
install() {
    (
        export TEST_ROOT="${ROOT}"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/scripts/common"
        install_steam_sdk
    ) > /dev/null 2>&1
    RC=$?
}

sdk_file() { echo "${ROOT}/home/rust/.steam/sdk$1/steamclient.so"; }

# --- the normal case: SteamCMD has just run as root -----------------------
fresh_root
make_source "root/.steam/sdk64/steamclient.so" "runtime-64"
make_source "root/.steam/sdk32/steamclient.so" "runtime-32"
install
if [[ ${RC} -eq 0 ]] && [[ -r "$(sdk_file 64)" ]]; then
    pass "steamclient.so is installed where the server user can read it"
else
    fail "expected a readable sdk64 copy, rc=${RC}"
fi
if [[ "$(cat "$(sdk_file 64)" 2>/dev/null)" == "runtime-64" ]]; then
    pass "the copy SteamCMD just refreshed is the one installed"
else
    fail "sdk64 content wrong: '$(cat "$(sdk_file 64)" 2>/dev/null)'"
fi
if [[ -r "$(sdk_file 32)" ]]; then
    pass "the 32-bit library is installed too when available"
else
    fail "expected an sdk32 copy as well"
fi

# --- fall back to the library shipped in the image ------------------------
# A cold container may not have run SteamCMD as root yet.
fresh_root
make_source "opt/steamcmd/linux64/steamclient.so" "shipped-64"
install
if [[ ${RC} -eq 0 ]] && [[ "$(cat "$(sdk_file 64)" 2>/dev/null)" == "shipped-64" ]]; then
    pass "falls back to the library shipped with SteamCMD"
else
    fail "expected the shipped library to be used, rc=${RC}"
fi

# --- the copy under /root/Steam, which the image also carries -------------
fresh_root
make_source "root/Steam/steamcmd/linux64/steamclient.so" "steamdir-64"
install
if [[ ${RC} -eq 0 ]] && [[ "$(cat "$(sdk_file 64)" 2>/dev/null)" == "steamdir-64" ]]; then
    pass "falls back to the copy under /root/Steam"
else
    fail "expected the /root/Steam copy to be used, rc=${RC}"
fi

# --- prefer the runtime copy over the shipped one -------------------------
# SteamCMD updates steamclient.so, so the newer copy must win.
fresh_root
make_source "root/.steam/sdk64/steamclient.so" "runtime-64"
make_source "opt/steamcmd/linux64/steamclient.so" "shipped-64"
install
if [[ "$(cat "$(sdk_file 64)" 2>/dev/null)" == "runtime-64" ]]; then
    pass "the runtime copy is preferred over the shipped one"
else
    fail "expected the runtime copy to win"
fi

# --- a stale copy must be replaced ---------------------------------------
fresh_root
make_source "root/.steam/sdk64/steamclient.so" "new-64"
mkdir -p "${ROOT}/home/rust/.steam/sdk64"
printf 'stale' > "$(sdk_file 64)"
install
if [[ "$(cat "$(sdk_file 64)" 2>/dev/null)" == "new-64" ]]; then
    pass "an existing stale copy is overwritten"
else
    fail "expected the stale copy to be replaced"
fi

# --- no 64-bit library anywhere: the server cannot work ------------------
# RustDedicated is 64-bit, so this must be reported, not passed over. A silent
# success here is what let #14 go unnoticed for months.
fresh_root
make_source "opt/steamcmd/linux32/steamclient.so" "shipped-32"
install
if [[ ${RC} -ne 0 ]]; then
    pass "a missing 64-bit library fails loudly rather than silently"
else
    fail "expected non-zero rc when no sdk64 source exists"
fi

echo
if [[ ${failures} -eq 0 ]]; then
    echo "All Steam SDK checks passed"
    exit 0
fi
echo "${failures} Steam SDK check(s) failed"
exit 1
