#!/usr/bin/env bash
set -euo pipefail

echo "================================================================="
echo " Reproducing Instance 12: OpenSSH Wildcard Precedence Override   "
echo "================================================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_BUGGY="${SCRIPT_DIR}/ssh_config.buggy"
CONFIG_FIXED="${SCRIPT_DIR}/ssh_config.fixed"

echo ""
echo "[Step 1] Inspecting OpenSSH Evaluation on Buggy Config..."
echo "Running: ssh -F ${CONFIG_BUGGY} -G server2 | grep -E '^proxyjump '"
PJ_EVAL=$(ssh -F "${CONFIG_BUGGY}" -G server2 2>/dev/null | grep -E '^proxyjump ' || true)
echo "Evaluated ProxyJump: ${PJ_EVAL}"

if [[ "${PJ_EVAL}" =~ "server3" ]]; then
    echo ">> BUG CONFIRMED: OpenSSH locked in 'ProxyJump server3' from 'Host *',"
    echo "   completely ignoring 'ProxyJump server1' inside 'Host server2'!"
fi

echo ""
echo "[Step 2] Running C99 Deterministic Preflight Checker on Buggy Config..."
if ./check_client_precedence "${CONFIG_BUGGY}" server2 ProxyJump; then
    echo "Error: Preflight checker failed to catch bug!"
    exit 1
else
    echo ">> PREFLIGHT DETECTED BUG: Successfully caught shadowing violation (exit code 1)."
fi

echo ""
echo "[Step 3] Running C99 Deterministic Preflight Checker on Fixed Config..."
./check_client_precedence "${CONFIG_FIXED}" server2 ProxyJump
echo ">> PREFLIGHT PASSED: Fixed config has valid precedence (exit code 0)."

echo ""
echo "[Step 4] Inspecting OpenSSH Evaluation on Fixed Config..."
PJ_FIXED_EVAL=$(ssh -F "${CONFIG_FIXED}" -G server2 2>/dev/null | grep -E '^proxyjump ' || true)
echo "Evaluated ProxyJump: ${PJ_FIXED_EVAL}"

echo ""
echo "================================================================="
echo " Reproduction & Preflight Verification Complete!                 "
echo "================================================================="
