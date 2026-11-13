#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"

CMD="${1:-/tmp/ssh-wildcard-blind}"

write_faulty_config() {
    local dst="$1"
    mkdir -p "$(dirname "${dst}")"
    cp "${REPO_DIR}/ssh_config.buggy" "${dst}"
    chmod 600 "${dst}"
}

teardown_workspace() {
    local ws="$1"
    local bridge_dir="${ws}/.bridge"
    if [ -f "${bridge_dir}/bridge_daemon.pid" ]; then
        local bpid
        bpid="$(cat "${bridge_dir}/bridge_daemon.pid" 2>/dev/null || true)"
        if [ -n "${bpid}" ] && kill -0 "${bpid}" 2>/dev/null; then
            kill "${bpid}" 2>/dev/null || true
            sleep 0.2
            kill -9 "${bpid}" 2>/dev/null || true
        fi
        rm -f "${bridge_dir}/bridge_daemon.pid"
    fi
    rm -f "${bridge_dir}/active"
    if [ -x "${REPO_DIR}/qemu/qemu_cluster.sh" ]; then
        "${REPO_DIR}/qemu/qemu_cluster.sh" down >/dev/null 2>&1 || true
    fi
    echo "[setup_blind_workspace] Stopped bridge daemon and QEMU cluster for ${ws}."
}

if [ "${CMD}" = "--teardown" ]; then
    WS_DIR="${2:-/tmp/ssh-wildcard-blind}"
    teardown_workspace "${WS_DIR}"
    exit 0
fi

WS_DIR="${CMD}"
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "ERROR: qemu-system-x86_64 is required to run the live 4-VM blind workspace." >&2
    exit 1
fi

# Tear down any previous bridge/cluster before recreating
teardown_workspace "${WS_DIR}" >/dev/null 2>&1 || true

rm -rf "${WS_DIR}"
mkdir -p "${WS_DIR}/client/.ssh" "${WS_DIR}/.bridge"
chmod 700 "${WS_DIR}/client/.ssh"
write_faulty_config "${WS_DIR}/client/.ssh/config"

cat << 'EOF' > "${WS_DIR}/PROMPT.txt"
Task: Fix the broken SSH connection to `server2`.

Environment:
- Running `./test_connection.sh` executes `ssh -o ConnectTimeout=4 server2 hostname` from `wc-client` (`10.202.1.2/24`).
- Currently `./test_connection.sh` fails with:
  "jumphost loop via server3"
- The client SSH configuration file is located at `client/.ssh/config` in this directory (synced into `wc-client:/home/deploy/.ssh/config` each time `./test_connection.sh` runs).
- You can reset `client/.ssh/config` back to the initial broken state with `./reset_lab.sh`.

Instructions:
1. Diagnose all configuration defects in `client/.ssh/config` preventing SSH connectivity to `server2`.
2. Edit `client/.ssh/config` with the minimal reversible fix to restore multi-hop connectivity.
3. Verify that `./test_connection.sh` outputs `server2` with exit code 0.
EOF

cat << 'EOF' > "${WS_DIR}/README.md"
# Blind Agent Troubleshooting Workspace

This directory is an isolated troubleshooting workspace connected to a live 4-VM QEMU OpenSSH chain (`wc-client -> server1 -> server3 -> server2`).

- Run `./test_connection.sh` to execute `ssh -o ConnectTimeout=6 server2 hostname` inside `wc-client`.
- Edit `client/.ssh/config` to fix the broken SSH configuration.
- Run `./reset_lab.sh` to restore `client/.ssh/config` to its initial broken state.
- See `PROMPT.txt` for the exact agent task prompt.
EOF

cat << 'EOF' > "${WS_DIR}/reset_lab.sh"
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat << 'CFG' > "${SCRIPT_DIR}/client/.ssh/config"
# =====================================================================
# Enterprise Bastion Mesh Client Configuration
# Environment: Production Multi-Hop Bastion Fabric (us-east-compute)
# Managed by: Platform Infrastructure Automation (Ansible ssh_config)
# Relay Topology: wc-client (10.202.1.0/24) -> bastion -> internal
# Last Modified: 2026-11-13
# =====================================================================

Host *
    IdentityFile /home/deploy/.ssh/id_ed25519
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ConnectTimeout 4
    LogLevel ERROR
    ServerAliveInterval 15
    ServerAliveCountMax 3

Host bastion-gateway
    HostName 10.202.1.3
    User deploy
    Port 22

Host !server1 server*
    ProxyJump server3
    ControlMaster no

Host *.compute.internal server?
    ProxyJump server1:2222
    User root
    ForwardAgent no

Host *1 *2
    ProxyJump server2:2222
    Port 2222
    Compression no

# =====================================================================
# Per-Host Node Definitions
# =====================================================================

Host server1
    HostName server1
    User deploy
    Port 22

Host server3
    HostName server3
    User deploy
    Port 22
    ProxyJump server1

Host server2
    HostName server2
    User deploy
    Port 22
    ProxyJump server1
CFG
chmod 600 "${SCRIPT_DIR}/client/.ssh/config"
echo "[reset_lab] Restored client/.ssh/config to initial broken state."
EOF
chmod 755 "${WS_DIR}/reset_lab.sh"

# Sandbox-safe test_connection.sh communicating over .bridge/
cat << 'EOF' > "${WS_DIR}/test_connection.sh"
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="${SCRIPT_DIR}/.bridge"

if [ ! -f "${BRIDGE_DIR}/active" ]; then
    echo "ERROR: QEMU bridge daemon is not active. Re-run setup_blind_workspace.sh." >&2
    exit 2
fi

REQ_ID="$$.$(date +%s 2>/dev/null || echo 0).${RANDOM}"
REQ_TMP="${BRIDGE_DIR}/req.${REQ_ID}.tmp"
REQ_FILE="${BRIDGE_DIR}/req.${REQ_ID}"
OUT_FILE="${BRIDGE_DIR}/out.${REQ_ID}"
RC_FILE="${BRIDGE_DIR}/rc.${REQ_ID}"
DONE_FILE="${BRIDGE_DIR}/done.${REQ_ID}"

echo "run" > "${REQ_TMP}"
mv "${REQ_TMP}" "${REQ_FILE}"

WAITED=0
while [ ! -f "${DONE_FILE}" ]; do
    sleep 0.1
    WAITED=$((WAITED + 1))
    if [ "${WAITED}" -ge 300 ]; then
        rm -f "${REQ_TMP}" "${REQ_FILE}" "${OUT_FILE}" "${RC_FILE}" "${DONE_FILE}"
        echo "ERROR: Timed out waiting for QEMU bridge response." >&2
        exit 124
    fi
done

RC="$(cat "${RC_FILE}" 2>/dev/null || echo 1)"
if [ -s "${OUT_FILE}" ]; then
    cat "${OUT_FILE}"
fi
rm -f "${OUT_FILE}" "${RC_FILE}" "${DONE_FILE}"
exit "${RC}"
EOF
chmod 755 "${WS_DIR}/test_connection.sh"

# Boot the 4-VM QEMU cluster
if [ ! -f "${REPO_DIR}/qemu/runtime/initramfs.cpio.gz" ]; then
    "${REPO_DIR}/qemu/build_initramfs.sh"
fi
"${REPO_DIR}/qemu/qemu_cluster.sh" reset
"${REPO_DIR}/qemu/qemu_cluster.sh" up

# Launch detached host-side bridge daemon
BRIDGE_DIR="${WS_DIR}/.bridge"
touch "${BRIDGE_DIR}/active"

nohup bash -c '
    REPO_DIR="$1"
    WS_DIR="$2"
    BRIDGE_DIR="$3"
    while [ -f "${BRIDGE_DIR}/active" ]; do
        for req in "${BRIDGE_DIR}"/req.*; do
            [ -e "${req}" ] || continue
            case "${req}" in
                *.tmp) continue ;;
            esac
            req_id="${req##*req.}"
            cp "${WS_DIR}/client/.ssh/config" "${REPO_DIR}/qemu/client/.ssh/config" 2>/dev/null || true
            chmod 644 "${REPO_DIR}/qemu/client/.ssh/config" 2>/dev/null || true
            set +e
            if command -v timeout >/dev/null 2>&1; then
                timeout -k 2 16 "${REPO_DIR}/qemu/test_connection.sh" > "${BRIDGE_DIR}/out.${req_id}.tmp" 2>&1
            else
                "${REPO_DIR}/qemu/test_connection.sh" > "${BRIDGE_DIR}/out.${req_id}.tmp" 2>&1
            fi
            rc=$?
            set -e
            mv "${BRIDGE_DIR}/out.${req_id}.tmp" "${BRIDGE_DIR}/out.${req_id}"
            echo "${rc}" > "${BRIDGE_DIR}/rc.${req_id}.tmp"
            mv "${BRIDGE_DIR}/rc.${req_id}.tmp" "${BRIDGE_DIR}/rc.${req_id}"
            touch "${BRIDGE_DIR}/done.${req_id}"
            rm -f "${req}"
        done
        sleep 0.1
    done
' _ "${REPO_DIR}" "${WS_DIR}" "${BRIDGE_DIR}" > "${BRIDGE_DIR}/bridge.log" 2>&1 </dev/null &

BPID=$!
echo "${BPID}" > "${BRIDGE_DIR}/bridge_daemon.pid"

echo "[setup_blind_workspace] Ready at ${WS_DIR} (bridge pid ${BPID})."
echo "[setup_blind_workspace] Give an agent the prompt in ${WS_DIR}/PROMPT.txt with cwd=${WS_DIR}."
