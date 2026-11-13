#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/runtime"
ROOTFS_DIR="${RUNTIME_DIR}/rootfs"
INITRAMFS_OUT="${RUNTIME_DIR}/initramfs.cpio.gz"

KVER="${QEMU_KVER:-$(uname -r)}"
MOD_BASE="/lib/modules/${KVER}"

echo "[build_initramfs] Target kernel: ${KVER}"

for tool in busybox cpio gzip ssh-keygen; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "ERROR: Required tool '${tool}' not found." >&2
        exit 1
    fi
done

if [ ! -x /usr/sbin/sshd ] || [ ! -x /usr/bin/ssh ]; then
    echo "ERROR: OpenSSH (/usr/sbin/sshd and /usr/bin/ssh) must be installed." >&2
    exit 1
fi

rm -rf "${ROOTFS_DIR}"
mkdir -p "${ROOTFS_DIR}"/{bin,sbin,etc/ssh,home/deploy/.ssh,root/.ssh,lib/x86_64-linux-gnu,lib64,mnt/share,modules,proc,sys,dev/pts,run/sshd,tmp,var/empty,usr/bin,usr/sbin,usr/lib/openssh}
chmod 1777 "${ROOTFS_DIR}/tmp"

# Install BusyBox and applets
BUSYBOX_BIN="$(command -v busybox)"
cp -L "${BUSYBOX_BIN}" "${ROOTFS_DIR}/bin/busybox"
chmod 755 "${ROOTFS_DIR}/bin/busybox"

for cmd in sh ash ls cat cp mv rm mkdir rmdir chmod chown ln sleep grep sed awk echo printf touch head tail kill ps mount umount hostname su env test [ [[ mkfifo xargs; do
    ln -sf /bin/busybox "${ROOTFS_DIR}/bin/${cmd}"
done
for cmd in ip ifconfig route insmod rmmod modprobe poweroff reboot halt; do
    ln -sf /bin/busybox "${ROOTFS_DIR}/sbin/${cmd}"
done
ln -sf /bin/sh "${ROOTFS_DIR}/usr/bin/sh" 2>/dev/null || true

# Copy binaries + dynamic shared libraries
copy_bin_and_libs() {
    local bin="$1"
    local dst_rel="$2"
    [ -e "${bin}" ] || return 0
    mkdir -p "${ROOTFS_DIR}/$(dirname "${dst_rel}")"
    cp -L "${bin}" "${ROOTFS_DIR}/${dst_rel}"
    chmod 755 "${ROOTFS_DIR}/${dst_rel}"

    ldd "${bin}" 2>/dev/null | while IFS= read -r line; do
        local lib=""
        if [[ "${line}" == *"=>"* ]]; then
            lib="$(echo "${line}" | awk '{print $3}')"
        else
            lib="$(echo "${line}" | awk '{print $1}')"
        fi
        if [[ "${lib}" == /* && -e "${lib}" ]]; then
            local lib_dir="${ROOTFS_DIR}/$(dirname "${lib#/}")"
            mkdir -p "${lib_dir}"
            cp -L -n "${lib}" "${lib_dir}/" 2>/dev/null || true
        fi
    done
}

copy_bin_and_libs "/usr/sbin/sshd" "usr/sbin/sshd"
copy_bin_and_libs "/usr/bin/ssh" "usr/bin/ssh"
copy_bin_and_libs "/usr/bin/ssh-keygen" "usr/bin/ssh-keygen"
copy_bin_and_libs "/usr/lib/openssh/sshd-session" "usr/lib/openssh/sshd-session"
copy_bin_and_libs "/usr/lib/openssh/sshd-auth" "usr/lib/openssh/sshd-auth"

# Copy NSS libraries for /etc/passwd and /etc/hosts resolution
for nss in /lib/x86_64-linux-gnu/libnss_files* /lib/x86_64-linux-gnu/libnss_dns* /lib/x86_64-linux-gnu/libresolv* /lib/x86_64-linux-gnu/libc.so* /lib64/ld-linux-x86-64.so*; do
    if [ -e "${nss}" ]; then
        dst_dir="${ROOTFS_DIR}/$(dirname "${nss#/}")"
        mkdir -p "${dst_dir}"
        cp -L -n "${nss}" "${dst_dir}/" 2>/dev/null || true
    fi
done

# Copy & decompress required kernel modules (virtio_net, virtio-rng, 9p)
copy_kmod() {
    local name_pattern="$1"
    local found
    found="$(find "${MOD_BASE}" -name "${name_pattern}" 2>/dev/null | head -n 1 || true)"
    if [ -z "${found}" ]; then
        echo "WARNING: Kernel module matching '${name_pattern}' not found under ${MOD_BASE}" >&2
        return 0
    fi
    local base_ko
    base_ko="$(basename "${found}")"
    base_ko="${base_ko%.xz}"
    base_ko="${base_ko%.zst}"
    base_ko="${base_ko%.gz}"
    case "${found}" in
        *.xz)  xz -dc "${found}" > "${ROOTFS_DIR}/modules/${base_ko}" ;;
        *.zst) zstd -dc "${found}" > "${ROOTFS_DIR}/modules/${base_ko}" ;;
        *.gz)  gzip -dc "${found}" > "${ROOTFS_DIR}/modules/${base_ko}" ;;
        *)     cp -L "${found}" "${ROOTFS_DIR}/modules/${base_ko}" ;;
    esac
}

if [ -d "${MOD_BASE}" ]; then
    for pat in \
        "failover.ko*" \
        "net_failover.ko*" \
        "virtio_net.ko*" \
        "virtio-rng.ko*" \
        "netfs.ko*" \
        "9pnet.ko*" \
        "9pnet_virtio.ko*" \
        "9p.ko*"; do
        copy_kmod "${pat}"
    done
else
    echo "WARNING: ${MOD_BASE} not found; assuming drivers are built-in to kernel." >&2
fi

# Generate SSH keys in runtime dir
mkdir -p "${RUNTIME_DIR}"
if [ ! -f "${RUNTIME_DIR}/id_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N "" -f "${RUNTIME_DIR}/id_ed25519"
fi
if [ ! -f "${RUNTIME_DIR}/mgmt_key" ]; then
    ssh-keygen -q -t ed25519 -N "" -f "${RUNTIME_DIR}/mgmt_key"
fi
if [ ! -f "${RUNTIME_DIR}/ssh_host_ed25519_key" ]; then
    ssh-keygen -q -t ed25519 -N "" -f "${RUNTIME_DIR}/ssh_host_ed25519_key"
fi
chmod 600 "${RUNTIME_DIR}/id_ed25519" "${RUNTIME_DIR}/mgmt_key" "${RUNTIME_DIR}/ssh_host_ed25519_key"

cp "${RUNTIME_DIR}/ssh_host_ed25519_key" "${ROOTFS_DIR}/etc/ssh/ssh_host_ed25519_key"
cp "${RUNTIME_DIR}/ssh_host_ed25519_key.pub" "${ROOTFS_DIR}/etc/ssh/ssh_host_ed25519_key.pub"
cp "${RUNTIME_DIR}/id_ed25519" "${ROOTFS_DIR}/home/deploy/.ssh/id_ed25519"
cp "${RUNTIME_DIR}/id_ed25519.pub" "${ROOTFS_DIR}/home/deploy/.ssh/id_ed25519.pub"
cp "${RUNTIME_DIR}/id_ed25519.pub" "${ROOTFS_DIR}/etc/ssh/authorized_keys_deploy"
cp "${RUNTIME_DIR}/mgmt_key.pub" "${ROOTFS_DIR}/root/.ssh/authorized_keys"

chmod 600 "${ROOTFS_DIR}/etc/ssh/ssh_host_ed25519_key" \
          "${ROOTFS_DIR}/home/deploy/.ssh/id_ed25519" \
          "${ROOTFS_DIR}/root/.ssh/authorized_keys"
chmod 644 "${ROOTFS_DIR}/etc/ssh/authorized_keys_deploy"
chmod 700 "${ROOTFS_DIR}/home/deploy/.ssh" "${ROOTFS_DIR}/root/.ssh"

# Users, groups, shadow, NSS, hosts
cat << 'EOF' > "${ROOTFS_DIR}/etc/passwd"
root:x:0:0:root:/root:/bin/sh
sshd:x:990:65534:sshd:/run/sshd:/bin/false
_ssh:x:101:65534:sshd:/run/sshd:/bin/false
deploy:x:1000:1000:deploy:/home/deploy:/bin/sh
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/shadow"
root:*:19000:0:99999:7:::
sshd:!:19000:0:99999:7:::
_ssh:!:19000:0:99999:7:::
deploy:*:19000:0:99999:7:::
EOF
chmod 600 "${ROOTFS_DIR}/etc/shadow"

cat << 'EOF' > "${ROOTFS_DIR}/etc/group"
root:x:0:
nogroup:x:65534:
_ssh:x:102:
deploy:x:1000:
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/nsswitch.conf"
passwd: files
group: files
hosts: files dns
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/hosts"
127.0.0.1 localhost
10.202.1.3 server1
10.202.13.3 server3
10.202.32.2 server2
EOF

# sshd configs: port 22 for inter-VM hop traffic, port 2222 for management on wc-client
cat << 'EOF' > "${ROOTFS_DIR}/etc/ssh/sshd_config"
Port 22
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PubkeyAuthentication yes
AuthorizedKeysFile /etc/ssh/authorized_keys_deploy
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM no
AllowUsers deploy
StrictModes no
AllowTcpForwarding yes
AllowAgentForwarding yes
PermitOpen any
PidFile /run/sshd.pid
LogLevel ERROR
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/ssh/sshd_mgmt_config"
Port 2222
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PubkeyAuthentication yes
AuthorizedKeysFile /root/.ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
UsePAM no
AllowUsers root
StrictModes no
PidFile /run/sshd_mgmt.pid
LogLevel ERROR
EOF

# Seed default ssh_config inside client initramfs (overridden at runtime from 9p /mnt/share/config)
cp "${REPO_DIR}/ssh_config.buggy" "${ROOTFS_DIR}/home/deploy/.ssh/config" 2>/dev/null || true
chmod 600 "${ROOTFS_DIR}/home/deploy/.ssh/config" 2>/dev/null || true

# Helper script inside wc-client VM to sync config from 9p mount and run ssh
cat << 'EOF' > "${ROOTFS_DIR}/bin/run_client_ssh.sh"
#!/bin/sh
if [ -f /mnt/share/config ]; then
    cp /mnt/share/config /home/deploy/.ssh/config
fi
chown -R 1000:1000 /home/deploy
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/id_ed25519 /home/deploy/.ssh/config 2>/dev/null || true
exec su deploy -c "ssh -o ConnectTimeout=6 server2 hostname"
EOF
chmod 755 "${ROOTFS_DIR}/bin/run_client_ssh.sh"

# Guest /init script
cat << 'EOF' > "${ROOTFS_DIR}/init"
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /run/sshd /var/empty
mount -t devpts devpts /dev/pts 2>/dev/null || true
chmod 755 /run/sshd /var/empty

chown -R 0:0 /root /etc/ssh /run/sshd /var/empty
chown -R 1000:1000 /home/deploy
chmod 700 /home/deploy/.ssh /root/.ssh
chmod 644 /etc/ssh/authorized_keys_deploy 2>/dev/null || true
chmod 600 /etc/shadow /home/deploy/.ssh/id_ed25519 /root/.ssh/authorized_keys /etc/ssh/ssh_host_ed25519_key 2>/dev/null || true

# Load virtio / 9p modules
for mod in failover net_failover virtio_net virtio-rng netfs 9pnet 9pnet_virtio 9p; do
    if [ -f "/modules/${mod}.ko" ]; then
        insmod "/modules/${mod}.ko" 2>/dev/null || true
    fi
done

# Give udev/kernel a moment for netdevs to settle
sleep 0.5 2>/dev/null || sleep 1

ROLE="unknown"
for arg in $(cat /proc/cmdline); do
    case "${arg}" in
        role=*) ROLE="${arg#role=}" ;;
    esac
done

hostname "${ROLE}"
echo "127.0.0.1 localhost ${ROLE}" >> /etc/hosts

ip link set lo up

case "${ROLE}" in
    wc-client)
        # eth0: QEMU user-net management interface
        ip link set eth0 up 2>/dev/null || true
        ip addr add 10.0.2.15/24 dev eth0 2>/dev/null || true
        ip route add default via 10.0.2.2 dev eth0 2>/dev/null || true
        # eth1: Point-to-point link to wc-server-1
        ip link set eth1 up 2>/dev/null || true
        ip addr add 10.202.1.2/24 dev eth1 2>/dev/null || true
        # Mount hostshare via 9p
        mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/share 2>/dev/null || true
        # Start management sshd on port 2222
        /usr/sbin/sshd -f /etc/ssh/sshd_mgmt_config
        ;;
    server1)
        # eth0: link from wc-client
        ip link set eth0 up 2>/dev/null || true
        ip addr add 10.202.1.3/24 dev eth0 2>/dev/null || true
        # eth1: link to server3
        ip link set eth1 up 2>/dev/null || true
        ip addr add 10.202.13.2/24 dev eth1 2>/dev/null || true
        /usr/sbin/sshd -f /etc/ssh/sshd_config
        ;;
    server3)
        # eth0: link from server1
        ip link set eth0 up 2>/dev/null || true
        ip addr add 10.202.13.3/24 dev eth0 2>/dev/null || true
        # eth1: link to server2
        ip link set eth1 up 2>/dev/null || true
        ip addr add 10.202.32.3/24 dev eth1 2>/dev/null || true
        /usr/sbin/sshd -f /etc/ssh/sshd_config
        ;;
    server2)
        # eth0: link from server3
        ip link set eth0 up 2>/dev/null || true
        ip addr add 10.202.32.2/24 dev eth0 2>/dev/null || true
        /usr/sbin/sshd -f /etc/ssh/sshd_config
        ;;
esac

echo "[GUEST READY] role=${ROLE}"
while true; do
    sleep 60
done
EOF
chmod 755 "${ROOTFS_DIR}/init"

(cd "${ROOTFS_DIR}" && find . -print0 | cpio --null -ov --format=newc -R 0:0 2>/dev/null | gzip -9 > "${INITRAMFS_OUT}")
echo "[build_initramfs] Built ${INITRAMFS_OUT} ($(du -h "${INITRAMFS_OUT}" | awk '{print $1}'))"
