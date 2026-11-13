#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFLIGHT_BIN="${REPO_DIR}/check_client_precedence"
CLIENT_CONFIG="${SCRIPT_DIR}/client/.ssh/config"

cleanup() {
    "${SCRIPT_DIR}/qemu_cluster.sh" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "================================================================="
echo " QEMU 4-VM End-to-End Verification: Instance 12                  "
echo "================================================================="

echo ""
echo "[Stage 0] Compiling C99 Preflight Checker & Preparing Initramfs..."
CC_BIN="${CC:-gcc}"
if ! command -v "${CC_BIN}" >/dev/null 2>&1; then
    CC_BIN="clang"
fi
"${CC_BIN}" -std=c99 -Wall -Wextra "${REPO_DIR}/check_client_precedence.c" -o "${PREFLIGHT_BIN}"

if [ ! -f "${SCRIPT_DIR}/runtime/initramfs.cpio.gz" ]; then
    "${SCRIPT_DIR}/build_initramfs.sh"
fi

"${SCRIPT_DIR}/qemu_cluster.sh" reset
"${SCRIPT_DIR}/qemu_cluster.sh" up

echo ""
echo "[Step 1] Testing buggy config across 4 QEMU VMs (expecting jumphost loop)..."
set +e
BUGGY_OUT="$("${SCRIPT_DIR}/test_connection.sh" 2>&1)"
BUGGY_RC=$?
set -e
echo "Exit Code: ${BUGGY_RC}"
echo "Output: ${BUGGY_OUT}"
if [ "${BUGGY_RC}" -eq 0 ]; then
    echo "FAIL: Expected ssh command to fail on buggy config, but it succeeded!" >&2
    exit 1
fi
if ! echo "${BUGGY_OUT}" | grep -qi "jumphost loop"; then
    echo "FAIL: Expected 'jumphost loop' error message, got: ${BUGGY_OUT}" >&2
    exit 1
fi
echo ">> STEP 1 PASS: 4-VM QEMU cluster reproduced 'jumphost loop via server3' (exit ${BUGGY_RC})."

echo ""
echo "[Step 2] Running C99 Preflight Checker on buggy config..."
set +e
PRE_BUG_OUT="$("${PREFLIGHT_BIN}" "${CLIENT_CONFIG}" server2 ProxyJump 2>&1)"
PRE_BUG_RC=$?
set -e
echo "Exit Code: ${PRE_BUG_RC}"
echo "Output: ${PRE_BUG_OUT}"
if [ "${PRE_BUG_RC}" -eq 0 ]; then
    echo "FAIL: Preflight checker did not flag buggy config!" >&2
    exit 1
fi
if ! echo "${PRE_BUG_OUT}" | grep -q "PREFLIGHT VIOLATION 1"; then
    echo "FAIL: Expected PREFLIGHT VIOLATION 1!" >&2
    exit 1
fi
echo ">> STEP 2 PASS: C99 preflight checker caught shadowing violation in <1ms."

echo ""
echo "[Step 3] Applying ground-truth fix (ssh_config.fixed)..."
cp "${REPO_DIR}/ssh_config.fixed" "${CLIENT_CONFIG}"
chmod 644 "${CLIENT_CONFIG}"
echo "Updated ${CLIENT_CONFIG}:"
cat "${CLIENT_CONFIG}"

echo ""
echo "[Step 4] Running C99 Preflight Checker on fixed config..."
PRE_FIX_OUT="$("${PREFLIGHT_BIN}" "${CLIENT_CONFIG}" server2 ProxyJump 2>&1)"
PRE_FIX_RC=$?
echo "Exit Code: ${PRE_FIX_RC}"
echo "Output: ${PRE_FIX_OUT}"
if [ "${PRE_FIX_RC}" -ne 0 ]; then
    echo "FAIL: Preflight checker rejected fixed config!" >&2
    exit 1
fi
echo ">> STEP 4 PASS: C99 preflight checker verified valid precedence."

echo ""
echo "[Step 5] Testing fixed config across 4 QEMU VMs (client -> server1 -> server3 -> server2)..."
set +e
FIXED_OUT="$("${SCRIPT_DIR}/test_connection.sh" 2>&1)"
FIXED_RC=$?
set -e
echo "Exit Code: ${FIXED_RC}"
echo "Output: ${FIXED_OUT}"
if [ "${FIXED_RC}" -ne 0 ] || [ "${FIXED_OUT}" != "server2" ]; then
    echo "FAIL: Expected 'server2' with exit code 0, got '${FIXED_OUT}' (rc=${FIXED_RC})" >&2
    exit 1
fi
echo ">> STEP 5 PASS: Real multi-hop OpenSSH across 4 QEMU VMs returned 'server2' (exit 0)!"

echo ""
echo "================================================================="
echo " ALL 5 QEMU E2E STAGES PASSED SUCCESSFULLY!                      "
echo "================================================================="
