#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"
PREFLIGHT_BIN="${REPO_DIR}/check_client_precedence"

compile_preflight() {
    local cc_bin="${CC:-gcc}"
    if ! command -v "${cc_bin}" >/dev/null 2>&1; then
        cc_bin="clang"
    fi
    if [ ! -x "${PREFLIGHT_BIN}" ] || [ "${REPO_DIR}/check_client_precedence.c" -nt "${PREFLIGHT_BIN}" ]; then
        "${cc_bin}" -std=c99 -Wall -Wextra "${REPO_DIR}/check_client_precedence.c" -o "${PREFLIGHT_BIN}"
    fi
}

run_full_retest() {
    local ws_dir="${1:-/tmp/ssh-wildcard-blind}"
    compile_preflight

    echo "================================================================="
    echo " 1. Fast Static & OpenSSH Config Parser Verification             "
    echo "================================================================="
    "${REPO_DIR}/reproduce.sh"

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        echo ""
        echo "[INFO] qemu-system-x86_64 not found on this host."
        echo "       Skipping live 4-VM QEMU retest; static/ssh -G verification passed."
        return 0
    fi

    echo ""
    echo "================================================================="
    echo " 2. Live 4-VM QEMU Blind Workspace & Bridge E2E Verification    "
    echo "================================================================="

    trap '"${REPO_DIR}/setup_blind_workspace.sh" --teardown "'"${ws_dir}"'" >/dev/null 2>&1 || true; rm -rf "'"${ws_dir}"'"' EXIT

    "${REPO_DIR}/setup_blind_workspace.sh" "${ws_dir}"

    echo ""
    echo "[Step A] Executing blind test_connection.sh (expecting jumphost loop via server3)..."
    set +e
    BUG_OUT="$("${ws_dir}/test_connection.sh" 2>&1)"
    BUG_RC=$?
    set -e
    echo "Exit Code: ${BUG_RC}"
    echo "Output: ${BUG_OUT}"
    if [ "${BUG_RC}" -eq 0 ] || ! echo "${BUG_OUT}" | grep -qi "jumphost loop"; then
        echo "FAIL: Expected buggy blind workspace to fail with jumphost loop!" >&2
        exit 1
    fi

    echo ""
    echo "[Step B] Running C99 Preflight Checker against blind client/.ssh/config..."
    set +e
    PRE_OUT="$("${PREFLIGHT_BIN}" "${ws_dir}/client/.ssh/config" server2 ProxyJump 2>&1)"
    PRE_RC=$?
    set -e
    echo "Exit Code: ${PRE_RC}"
    echo "Output: ${PRE_OUT}"
    if [ "${PRE_RC}" -eq 0 ] || ! echo "${PRE_OUT}" | grep -q "PREFLIGHT VIOLATION 1"; then
        echo "FAIL: Preflight checker did not catch wildcard shadowing!" >&2
        exit 1
    fi

    echo ""
    echo "[Step C] Applying minimal ground-truth fix in ${ws_dir}/client/.ssh/config..."
    cp "${REPO_DIR}/ssh_config.fixed" "${ws_dir}/client/.ssh/config"
    chmod 600 "${ws_dir}/client/.ssh/config"

    echo "[Step D] Verifying C99 Preflight Checker passes..."
    "${PREFLIGHT_BIN}" "${ws_dir}/client/.ssh/config" server2 ProxyJump

    echo ""
    echo "[Step E] Verifying blind test_connection.sh across 4 QEMU VMs (expecting 'server2')..."
    FIX_OUT="$("${ws_dir}/test_connection.sh" 2>&1)"
    FIX_RC=$?
    echo "Exit Code: ${FIX_RC}"
    echo "Output: ${FIX_OUT}"
    if [ "${FIX_RC}" -ne 0 ] || [ "${FIX_OUT}" != "server2" ]; then
        echo "FAIL: Expected 'server2' (rc=0), got '${FIX_OUT}' (rc=${FIX_RC})" >&2
        exit 1
    fi

    echo ""
    echo "================================================================="
    echo " RETEST PASSED: C99 Preflight + 4-VM QEMU Blind Workspace E2E    "
    echo "================================================================="
}

run_agent_eval() {
    local agent="$1"
    local ws_dir="${2:-/tmp/ssh-wildcard-blind}"
    compile_preflight

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        echo "ERROR: Live QEMU agent evaluation requires Linux with qemu-system-x86_64." >&2
        exit 1
    fi

    trap '"${REPO_DIR}/setup_blind_workspace.sh" --teardown "'"${ws_dir}"'" >/dev/null 2>&1 || true' EXIT

    "${REPO_DIR}/setup_blind_workspace.sh" "${ws_dir}"

    local prompt_text
    prompt_text="$(cat "${ws_dir}/PROMPT.txt")"

    echo ""
    echo "================================================================="
    echo " Running Blind Agent Benchmark: ${agent}                         "
    echo " Workspace: ${ws_dir}                                            "
    echo "================================================================="

    local start_ts end_ts elapsed
    start_ts="$(date +%s)"

    case "${agent}" in
        codex)
            if ! command -v codex >/dev/null 2>&1; then
                echo "ERROR: 'codex' CLI not found in PATH." >&2
                exit 1
            fi
            local model_args=()
            if [ -n "${AGENT_MODEL:-}" ]; then
                model_args=(-m "${AGENT_MODEL}")
            fi
            (cd "${ws_dir}" && codex exec --skip-git-repo-check -C "${ws_dir}" -s workspace-write "${model_args[@]}" - < "${ws_dir}/PROMPT.txt") || true
            ;;
        gemini|gemini-cli)
            local gbin=""
            if command -v gemini >/dev/null 2>&1; then
                gbin="gemini"
            elif command -v gemini-cli >/dev/null 2>&1; then
                gbin="gemini-cli"
            else
                echo "ERROR: neither 'gemini' nor 'gemini-cli' found in PATH." >&2
                exit 1
            fi
            local model_args=()
            if [ -n "${AGENT_MODEL:-}" ]; then
                model_args=(-m "${AGENT_MODEL}")
            fi
            (cd "${ws_dir}" && "${gbin}" -p "${prompt_text}" --yolo "${model_args[@]}") || true
            ;;
        claude|claude-code)
            if ! command -v claude >/dev/null 2>&1; then
                echo "ERROR: 'claude' CLI not found in PATH." >&2
                exit 1
            fi
            local model_args=()
            if [ -n "${AGENT_MODEL:-}" ]; then
                model_args=(--model "${AGENT_MODEL}")
            fi
            (cd "${ws_dir}" && claude -p "${prompt_text}" --permission-mode acceptEdits "${model_args[@]}") || true
            ;;
        *)
            echo "ERROR: Unsupported agent '${agent}'. Supported: codex, gemini, claude" >&2
            exit 2
            ;;
    esac

    end_ts="$(date +%s)"
    elapsed=$((end_ts - start_ts))

    echo ""
    echo "================================================================="
    echo " Post-Run Ground-Truth & C99 Preflight Verification              "
    echo "================================================================="
    set +e
    FINAL_SSH_OUT="$("${ws_dir}/test_connection.sh" 2>&1)"
    FINAL_SSH_RC=$?
    FINAL_PRE_OUT="$("${PREFLIGHT_BIN}" "${ws_dir}/client/.ssh/config" server2 ProxyJump 2>&1)"
    FINAL_PRE_RC=$?
    set -e

    echo "Agent Elapsed Time : ${elapsed}s"
    echo "4-VM SSH Output    : ${FINAL_SSH_OUT} (exit ${FINAL_SSH_RC})"
    echo "C99 Preflight Out  : ${FINAL_PRE_OUT} (exit ${FINAL_PRE_RC})"

    if [ "${FINAL_SSH_RC}" -eq 0 ] && [ "${FINAL_SSH_OUT}" = "server2" ] && [ "${FINAL_PRE_RC}" -eq 0 ]; then
        echo "BENCHMARK RESULT   : PASS (Agent resolved Host * shadowing)"
    else
        echo "BENCHMARK RESULT   : FAIL (Agent failed to clear wildcard precedence bug)"
        exit 1
    fi
}

case "${1:-}" in
    --prepare-blind)
        compile_preflight
        "${REPO_DIR}/setup_blind_workspace.sh" "${2:-/tmp/ssh-wildcard-blind}"
        ;;
    --run-agent)
        if [ -z "${2:-}" ]; then
            echo "Usage: $0 --run-agent <codex|gemini|claude> [WS_DIR]" >&2
            exit 2
        fi
        run_agent_eval "$2" "${3:-/tmp/ssh-wildcard-blind}"
        ;;
    --teardown)
        "${REPO_DIR}/setup_blind_workspace.sh" --teardown "${2:-/tmp/ssh-wildcard-blind}"
        ;;
    -h|--help)
        cat << 'USAGE'
Usage:
  ./retest.sh                              Run full automated retest (ssh -G + C99 preflight + 4-VM QEMU E2E)
  ./retest.sh --prepare-blind [WS_DIR]     Boot 4-VM QEMU cluster and create spoiler-free workspace (default: /tmp/ssh-wildcard-blind)
  ./retest.sh --run-agent <AGENT> [WS_DIR] Benchmark codex, gemini, or claude against live 4-VM QEMU blind workspace
  ./retest.sh --teardown [WS_DIR]          Stop bridge daemon and QEMU cluster
USAGE
        ;;
    *)
        run_full_retest "${1:-/tmp/ssh-wildcard-blind}"
        ;;
esac
