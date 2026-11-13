#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/runtime"
MGMT_KEY="${RUNTIME_DIR}/mgmt_key"
PORT="${QEMU_MGMT_PORT:-17100}"

if [ ! -f "${MGMT_KEY}" ]; then
    echo "ERROR: ${MGMT_KEY} not found. Run ./qemu/qemu_cluster.sh up first." >&2
    exit 2
fi

exec ssh -i "${MGMT_KEY}" -p "${PORT}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o LogLevel=ERROR \
    root@127.0.0.1 /bin/run_client_ssh.sh
