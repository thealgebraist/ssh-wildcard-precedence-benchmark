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

REMOTE_CMD='killall -9 ssh 2>/dev/null || true
if [ -f /mnt/share/config ]; then cp /mnt/share/config /home/deploy/.ssh/config; fi
chown -R 1000:1000 /home/deploy
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/id_ed25519 /home/deploy/.ssh/config 2>/dev/null || true
su deploy -c "ulimit -u 24 2>/dev/null || true; timeout -k 2 8 ssh -o ConnectTimeout=4 server2 hostname"
rc=$?
killall -9 ssh 2>/dev/null || true
exit $rc'

if command -v timeout >/dev/null 2>&1; then
    exec timeout -k 2 14 ssh -i "${MGMT_KEY}" -p "${PORT}" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        root@127.0.0.1 sh -c "${REMOTE_CMD}"
else
    exec ssh -i "${MGMT_KEY}" -p "${PORT}" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        root@127.0.0.1 sh -c "${REMOTE_CMD}"
fi
