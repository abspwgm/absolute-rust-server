#!/bin/bash
# =============================================================================
# Unit Test: Oxide pin enforcement (no Docker, no network)
# A mod loader runs arbitrary code next to a live world, so oxide-installer may
# only install a version-pinned archive whose sha256 matches. This exercises
# scripts/oxide-installer against a local file:// "release".
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

PINNED_VERSION="2.0.7723"
RELEASE_BASE="${WORK_DIR}/releases"
TEST_ROOT_DIR="${WORK_DIR}/root"
SERVER_PATH="${TEST_ROOT_DIR}/opt/rust/server"

# -----------------------------------------------------------------------------
# Build a fake Oxide release that looks like the real archive
# -----------------------------------------------------------------------------
build_release() {
    local version="$1"
    local staging="${WORK_DIR}/staging"

    rm -rf "${staging}"
    mkdir -p "${staging}/RustDedicated_Data/Managed"
    printf 'fake oxide core %s\n' "${version}" \
        > "${staging}/RustDedicated_Data/Managed/Oxide.Core.dll"
    printf 'fake oxide rust %s\n' "${version}" \
        > "${staging}/RustDedicated_Data/Managed/Oxide.Rust.dll"

    mkdir -p "${RELEASE_BASE}/${version}"
    (cd "${staging}" && zip -qr "${RELEASE_BASE}/${version}/Oxide.Rust-linux.zip" .)
}

release_sha256() {
    sha256sum "${RELEASE_BASE}/$1/Oxide.Rust-linux.zip" | cut -d' ' -f1
}

reset_server() {
    rm -rf "${SERVER_PATH}"
    mkdir -p "${SERVER_PATH}/RustDedicated_Data/Managed"
}

# Runs oxide-installer in a clean environment. Output lands in ${WORK_DIR}/output.
run_installer() {
    local version="$1"
    local sha="$2"
    shift 2
    (
        export RUST_SCRIPTS_DIR="${PROJECT_DIR}/scripts"
        export TEST_ROOT="${TEST_ROOT_DIR}"
        export OXIDE_RELEASE_BASE="file://${RELEASE_BASE}"
        export OXIDE_TEMP_DIR="${WORK_DIR}/tmp"
        export OXIDE_VERSION="${version}"
        export OXIDE_SHA256="${sha}"
        export OXIDE_AUTO_UPDATE="${OXIDE_AUTO_UPDATE:-true}"
        bash "${PROJECT_DIR}/scripts/oxide-installer" "$@"
    ) > "${WORK_DIR}/output" 2>&1
    INSTALLER_STATUS=$?
    return ${INSTALLER_STATUS}
}

installer_succeeded() { test "${INSTALLER_STATUS}" -eq 0; }
installer_failed() { test "${INSTALLER_STATUS}" -ne 0; }

oxide_installed() {
    test -f "${SERVER_PATH}/RustDedicated_Data/Managed/Oxide.Core.dll"
}

installed_version() {
    tr -d '\r\n' < "${SERVER_PATH}/oxide/.oxide_version" 2>/dev/null
}

log_test_start "oxide_pin (unit)"

build_release "${PINNED_VERSION}"
GOOD_SHA="$(release_sha256 "${PINNED_VERSION}")"

# --- 1. The matching checksum installs -------------------------------------
reset_server
run_installer "${PINNED_VERSION}" "${GOOD_SHA}" --install
check "matching sha256: installer succeeds" installer_succeeded
check "matching sha256: Oxide is installed" oxide_installed
check "matching sha256: version marker records the pin" \
    test "$(installed_version)" == "${PINNED_VERSION}"
check "matching sha256: plugin directory created" test -d "${SERVER_PATH}/oxide/plugins"

# --- 2. A tampered archive is refused --------------------------------------
reset_server
run_installer "${PINNED_VERSION}" "0000000000000000000000000000000000000000000000000000000000000000" --install
check "wrong sha256: installer fails" installer_failed
check "wrong sha256: nothing is extracted" test ! -f "${SERVER_PATH}/RustDedicated_Data/Managed/Oxide.Core.dll"
check "wrong sha256: mismatch is reported" grep -qi "checksum mismatch" "${WORK_DIR}/output"
check "wrong sha256: temp download is cleaned up" test ! -f "${WORK_DIR}/tmp/Oxide.Rust-linux.zip"

# --- 3. An unpinned install is refused outright -----------------------------
reset_server
run_installer "${PINNED_VERSION}" "" --install
check "empty sha256: installer fails" installer_failed
check "empty sha256: refuses an unpinned mod loader" grep -qi "unpinned" "${WORK_DIR}/output"
check "empty sha256: nothing is downloaded" test ! -f "${WORK_DIR}/tmp/Oxide.Rust-linux.zip"

reset_server
run_installer "" "${GOOD_SHA}" --install
check "empty version: installer fails" installer_failed
check "empty version: nothing is extracted" test ! -f "${SERVER_PATH}/RustDedicated_Data/Managed/Oxide.Core.dll"

# --- 4. check-update is a version comparison, not a blind reinstall ---------
reset_server
run_installer "${PINNED_VERSION}" "${GOOD_SHA}" --install
run_installer "${PINNED_VERSION}" "${GOOD_SHA}" --check-update
check "check-update at the pinned version: succeeds" installer_succeeded
check "check-update at the pinned version: does not redownload" \
    grep -qi "matches the pinned version" "${WORK_DIR}/output"

# A newer pin is taken when auto-update is on
build_release "2.0.7799"
NEW_SHA="$(release_sha256 "2.0.7799")"
run_installer "2.0.7799" "${NEW_SHA}" --check-update
check "newer pin with auto-update on: upgrades" test "$(installed_version)" == "2.0.7799"

# ...and refused when auto-update is off
reset_server
run_installer "${PINNED_VERSION}" "${GOOD_SHA}" --install
OXIDE_AUTO_UPDATE=false run_installer "2.0.7799" "${NEW_SHA}" --check-update
check "newer pin with auto-update off: says why" \
    grep -qi "OXIDE_AUTO_UPDATE is false" "${WORK_DIR}/output"
check "newer pin with auto-update off: stays put" \
    test "$(installed_version)" == "${PINNED_VERSION}"

# -----------------------------------------------------------------------------
if [[ ${CHECKS_FAILED} -gt 0 ]]; then
    log_test_fail "oxide_pin (unit): ${CHECKS_FAILED} check(s) failed"
    exit 1
fi

log_test_pass "oxide_pin (unit)"
exit 0
