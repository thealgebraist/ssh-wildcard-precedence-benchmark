#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/runtime"
CLIENT_SSH_DIR="${SCRIPT_DIR}/client/.ssh"
KERNEL="${QEMU_KERNEL:-/boot/vmlinuz-$(uname -r)}"
INITRD="${QEMU_INITRD:-${RUNTIME_DIR}/initramfs.cpio.gz}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

CMD="${1:-status}"

write_buggy_config() {
    mkdir -p "${CLIENT_SSH_DIR}"
    cat << 'CFG' > "${CLIENT_SSH_DIR}/config"
Host *
    User deploy
    IdentityFile /home/deploy/.ssh/id_ed25519
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ConnectTimeout 4
    LogLevel ERROR
    ProxyJump server3

Host server1
    HostName server1

Host server3
    HostName server3
    ProxyJump server1

Host server2
    HostName server2
    ProxyJump server3
CFG
    chmod 644 "${CLIENT_SSH_DIR}/config"
}

wait_listen_port() {
    local port="$1"
    local tries=0
    while [ "${tries}" -lt 100 ]; do
        if ss -tln 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            return 0
        fi
        sleep 0.2
        tries=$((tries + 1))
    done
    echo "ERROR: Timed out waiting for QEMU socket port ${port} to listen" >&2
    return 1
}

wait_guest_ready() {
    local role="$1"
    local log_file="${RUNTIME_DIR}/${role}.log"
    local tries=0
    while [ "${tries}" -lt 150 ]; do
        if grep -q "\[GUEST READY\] role=${role}" "${log_file}" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
        tries=$((tries + 1))
    done
    echo "ERROR: Timed out waiting for guest '${role}' to boot. Tail of ${log_file}:" >&2
    tail -n 30 "${log_file}" >&2 || true
    return 1
}

cluster_down() {
    for role in wc-client server1 server3 server2; do
        local pidfile="${RUNTIME_DIR}/${role}.pid"
        if [ -f "${pidfile}" ]; then
            local pid
            pid="$(cat "${pidfile}" 2>/dev/null || true)"
            if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
                kill "${pid}" 2>/dev/null || true
                sleep 0.2
                kill -9 "${pid}" 2>/dev/null || true
            fi
            rm -f "${pidfile}"
        fi
    done
    echo "[qemu_cluster] Stopped all QEMU VMs."
}

cluster_up() {
    if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
        echo "ERROR: ${QEMU_BIN} not found." >&2
        exit 1
    fi
    if [ ! -r "${KERNEL}" ]; then
        echo "ERROR: Kernel not readable at ${KERNEL}" >&2
        exit 1
    fi
    if [ ! -r "${INITRD}" ]; then
        echo "[qemu_cluster] Initramfs not found; building..."
        "${SCRIPT_DIR}/build_initramfs.sh"
    fi

    cluster_down >/dev/null 2>&1 || true
    mkdir -p "${RUNTIME_DIR}"
    if [ ! -f "${CLIENT_SSH_DIR}/config" ]; then
        write_buggy_config
    fi

    local accel_args
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        accel_args="-enable-kvm -cpu host"
        echo "[qemu_cluster] Using KVM acceleration"
    else
        accel_args="-accel tcg -cpu max"
        echo "[qemu_cluster] Using QEMU TCG software emulation (no /dev/kvm)"
    fi

    local common_args="-m 192M -smp 1 -display none -no-reboot -kernel ${KERNEL} -initrd ${INITRD} -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0"

    # 1. Start wc-server-2 (listens on 17103 for server3 link)
    rm -f "${RUNTIME_DIR}/server2.log"
    ${QEMU_BIN} ${accel_args} ${common_args} \
        -append "console=ttyS0 quiet panic=-1 role=server2" \
        -netdev socket,id=n32,listen=127.0.0.1:17103 \
        -device virtio-net-pci,netdev=n32,mac=52:54:00:00:32:02 \
        -serial file:"${RUNTIME_DIR}/server2.log" \
        -pidfile "${RUNTIME_DIR}/server2.pid" \
        -daemonize
    wait_listen_port 17103

    # 2. Start wc-server-3 (listens on 17102 for server1 link, connects to 17103 -> server2)
    rm -f "${RUNTIME_DIR}/server3.log"
    ${QEMU_BIN} ${accel_args} ${common_args} \
        -append "console=ttyS0 quiet panic=-1 role=server3" \
        -netdev socket,id=n13,listen=127.0.0.1:17102 \
        -device virtio-net-pci,netdev=n13,mac=52:54:00:00:13:03 \
        -netdev socket,id=n32,connect=127.0.0.1:17103 \
        -device virtio-net-pci,netdev=n32,mac=52:54:00:00:32:03 \
        -serial file:"${RUNTIME_DIR}/server3.log" \
        -pidfile "${RUNTIME_DIR}/server3.pid" \
        -daemonize
    wait_listen_port 17102

    # 3. Start wc-server-1 (listens on 17101 for client link, connects to 17102 -> server3)
    rm -f "${RUNTIME_DIR}/server1.log"
    ${QEMU_BIN} ${accel_args} ${common_args} \
        -append "console=ttyS0 quiet panic=-1 role=server1" \
        -netdev socket,id=n01,listen=127.0.0.1:17101 \
        -device virtio-net-pci,netdev=n01,mac=52:54:00:00:01:03 \
        -netdev socket,id=n13,connect=127.0.0.1:17102 \
        -device virtio-net-pci,netdev=n13,mac=52:54:00:00:13:02 \
        -serial file:"${RUNTIME_DIR}/server1.log" \
        -pidfile "${RUNTIME_DIR}/server1.pid" \
        -daemonize
    wait_listen_port 17101

    # 4. Start wc-client (user-net mgmt port 17100->2222, connects to 17101 -> server1, 9p share)
    rm -f "${RUNTIME_DIR}/wc-client.log"
    ${QEMU_BIN} ${accel_args} ${common_args} \
        -append "console=ttyS0 quiet panic=-1 role=wc-client" \
        -netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:17100-:2222 \
        -device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:00:01 \
        -netdev socket,id=n01,connect=127.0.0.1:17101 \
        -device virtio-net-pci,netdev=n01,mac=52:54:00:00:01:02 \
        -virtfs local,path="${CLIENT_SSH_DIR}",mount_tag=hostshare,security_model=none,id=hostshare \
        -serial file:"${RUNTIME_DIR}/wc-client.log" \
        -pidfile "${RUNTIME_DIR}/wc-client.pid" \
        -daemonize

    echo "[qemu_cluster] Waiting for all 4 VMs to boot..."
    for role in server2 server3 server1 wc-client; do
        wait_guest_ready "${role}"
    done

    # Verify management SSH on 127.0.0.1:17100
    local tries=0
    while [ "${tries}" -lt 30 ]; do
        if ssh -i "${RUNTIME_DIR}/mgmt_key" -p 17100 \
            -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=2 root@127.0.0.1 true 2>/dev/null; then
            echo "[qemu_cluster] All 4 VMs are booted and SSH-ready!"
            return 0
        fi
        sleep 0.5
        tries=$((tries + 1))
    done

    echo "ERROR: Timed out waiting for wc-client management SSH on port 17100" >&2
    return 1
}

cluster_status() {
    for role in wc-client server1 server3 server2; do
        local pidfile="${RUNTIME_DIR}/${role}.pid"
        if [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}" 2>/dev/null || echo 0)" 2>/dev/null; then
            echo "${role}: RUNNING (pid $(cat "${pidfile}"))"
        else
            echo "${role}: STOPPED"
        fi
    done
}

case "${CMD}" in
    up)
        cluster_up
        ;;
    down)
        cluster_down
        ;;
    reset)
        write_buggy_config
        echo "[qemu_cluster] Reset ${CLIENT_SSH_DIR}/config to baseline faulty state (Host * -> ProxyJump server3)."
        ;;
    status)
        cluster_status
        ;;
    *)
        echo "Usage: $0 {up|down|reset|status}" >&2
        exit 2
        ;;
esac
