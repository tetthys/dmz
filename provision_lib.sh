#!/usr/bin/env bash
# =====================================================================
# provision_lib.sh — shared functions, variables, and templates (v4)
# Split-out library for DMZ VM provisioning to simplify debugging.
# =====================================================================

set -Eeuo pipefail

# Auto-load .env if present (export all)
if [ -f ".env" ]; then
  set -a; . ./.env; set +a
fi

# ==============================
# DEFAULTS (overridden by .env)
# ==============================
BR_EXTERNAL="${BR_EXTERNAL:-br-external}"
BR_INTERNAL="${BR_INTERNAL:-br-internal}"

HOST_DMZ_GW="${HOST_DMZ_GW:-192.0.2.1}"
HOST_INT_GW="${HOST_INT_GW:-10.10.0.1}"

WEB_VM_NAME="${WEB_VM_NAME:-web-vm}"
WEB_VM_IP="${WEB_VM_IP:-192.0.2.101}"
WEB_VM_CIDR="${WEB_VM_CIDR:-24}"

INTERNAL_VM_NAME="${INTERNAL_VM_NAME:-internal-vm}"
INTERNAL_VM_IP="${INTERNAL_VM_IP:-10.10.0.11}"
INTERNAL_VM_CIDR="${INTERNAL_VM_CIDR:-24}"

# Fixed MACs improve determinism + allow MAC-matched netplan
WEB_VM_MAC="${WEB_VM_MAC:-52:54:00:aa:bb:01}"
INTERNAL_VM_MAC="${INTERNAL_VM_MAC:-52:54:00:aa:bb:02}"

# informational only; we use MAC match in netplan
GUEST_IFACE_NAME="${GUEST_IFACE_NAME:-ens3}"

WEB_VM_MEM="${WEB_VM_MEM:-4096}"
WEB_VM_CPUS="${WEB_VM_CPUS:-2}"
INTERNAL_VM_MEM="${INTERNAL_VM_MEM:-4096}"
INTERNAL_VM_CPUS="${INTERNAL_VM_CPUS:-2}"

IMG_DIR="${IMG_DIR:-/var/lib/libvirt/images}"
CLOUD_IMG="${CLOUD_IMG:-${IMG_DIR}/ubuntu-22.04-server-cloudimg-amd64.img}"
CLOUD_IMG_URL="${CLOUD_IMG_URL:-https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img}"

WEB_DISK="${WEB_DISK:-${IMG_DIR}/${WEB_VM_NAME}.qcow2}"
INT_DISK="${INT_DISK:-${IMG_DIR}/${INTERNAL_VM_NAME}.qcow2}"

SEED_DIR="${SEED_DIR:-/var/lib/libvirt/cloud-seed}"
WEB_SEED_ISO="${WEB_SEED_ISO:-${SEED_DIR}/${WEB_VM_NAME}-seed.iso}"
INT_SEED_ISO="${INT_SEED_ISO:-${SEED_DIR}/${INTERNAL_VM_NAME}-seed.iso}"

INTERNAL_API_PORT="${INTERNAL_API_PORT:-8443}"

SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-REPLACE_WITH_YOUR_SSH_PUBLIC_KEY}"
TIMEZONE="${TIMEZONE:-Asia/Seoul}"

LOG_FILE="${LOG_FILE:-$(pwd)/provision.log}"
VERBOSE="${VERBOSE:-1}"
WAIT_SSH="${WAIT_SSH:-0}"
SSH_TIMEOUT_SEC="${SSH_TIMEOUT_SEC:-180}"

# TEMP password auth controls (LAB ONLY)
ENABLE_PW_AUTH="${ENABLE_PW_AUTH:-0}"
LOGIN_USERNAME="${LOGIN_USERNAME:-ubuntu}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-ubuntu}"
DISABLE_PW_ON_BOOT="${DISABLE_PW_ON_BOOT:-1}"

# per-VM network-config files (cloud-localds -N)
WEB_NETCFG="${SEED_DIR:-/var/lib/libvirt/cloud-seed}/${WEB_VM_NAME}-network-config.yaml"
INT_NETCFG="${SEED_DIR:-/var/lib/libvirt/cloud-seed}/${INTERNAL_VM_NAME}-network-config.yaml"

# debug toggle
DEBUG_CLOUDINIT="${DEBUG_CLOUDINIT:-0}"

# ==============
# LOG HELPERS
# ==============
ts() { date +"%Y-%m-%d %H:%M:%S%z"; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
dbg() { [[ "${VERBOSE}" = "1" ]] && log "[DEBUG] $*"; true; }
err() { echo "[$(ts)] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

# ========
# CHECKS
# ========
need() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

preflight() {
  : > "$LOG_FILE" || true
  log "[1/8] Preflight checks..."
  for bin in wget qemu-img virt-install cloud-localds virsh; do need "$bin"; done
  ip link show "$BR_EXTERNAL" >/dev/null 2>&1 || { err "Bridge $BR_EXTERNAL not found (run host_setup.sh)."; exit 1; }
  ip link show "$BR_INTERNAL" >/dev/null 2>&1 || { err "Bridge $BR_INTERNAL not found (run host_setup.sh)."; exit 1; }
  if [[ "$SSH_PUBLIC_KEY" == "REPLACE_WITH_YOUR_SSH_PUBLIC_KEY" ]]; then
    err "SSH_PUBLIC_KEY is not set."; exit 1
  fi
  log "Bridges OK: $BR_EXTERNAL, $BR_INTERNAL"
}

# =========================
# CLOUD IMAGE / DISKS
# =========================
ensure_cloud_image() {
  log "[2/8] Ensuring base cloud image exists at $CLOUD_IMG ..."
  mkdir -p "$IMG_DIR"
  if [[ ! -f "$CLOUD_IMG" ]]; then
    log "Downloading cloud image from: $CLOUD_IMG_URL"
    wget -O "$CLOUD_IMG" "$CLOUD_IMG_URL" 2>&1 | tee -a "$LOG_FILE"
  else
    log "Cloud image already present. Skipping download."
  fi
}

create_disks() {
  log "[3/8] Preparing VM disks..."
  if [[ ! -f "$WEB_DISK" ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "$CLOUD_IMG" "$WEB_DISK" | tee -a "$LOG_FILE"
    log "Created $WEB_DISK"
  else
    log "Found existing $WEB_DISK (reusing)."
  fi
  if [[ ! -f "$INT_DISK" ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "$CLOUD_IMG" "$INT_DISK" | tee -a "$LOG_FILE"
    log "Created $INT_DISK"
  else
    log "Found existing $INT_DISK (reusing)."
  fi
}

# =========================
# COMPOSE / SECCOMP TEMPLATES
# =========================
WEB_COMPOSE=$(cat <<'YML'
version: '3.8'
services:
  web:
    image: nginx:stable
    user: "101:101"
    read_only: true
    tmpfs: ["/tmp","/var/cache/nginx","/var/run"]
    cap_drop: ["ALL"]
    security_opt:
      - no-new-privileges:true
      - seccomp:/home/ubuntu/web_seccomp.json
    environment:
      - INTERNAL_API_URL=https://10.10.0.11:8443
    ports: ["443:443"]
YML
)

WEB_SECCOMP=$(cat <<'JSON'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "syscalls": [
    { "names": ["read","write","close","fstat","poll","recvfrom","sendto","sendmsg","recvmsg","nanosleep","clock_gettime","gettimeofday","epoll_wait"],
      "action": "SCMP_ACT_ALLOW" }
  ]
}
JSON
)

INT_COMPOSE=$(cat <<'YML'
version: '3.8'
services:
  internal-service:
    image: hashicorp/http-echo:0.2.3
    command: ["-text=OK","-listen=:8443"]
    tmpfs: ["/run/secrets"]
YML
)

# =========================
# NETWORK CONFIG MAKERS
# =========================
make_network_config() {
  local ip="$1" cidr="$2" gw="$3" mac="$4" out="$5"
  # cloud-init native network-config (v2, netplan renderer)
  cat > "$out" <<EOF
version: 2
ethernets:
  dmznic0:
    match:
      macaddress: "${mac}"
    set-name: dmznic0
    addresses:
      - ${ip}/${cidr}
    gateway4: ${gw}
    nameservers:
      addresses: [1.1.1.1,8.8.8.8]
EOF
  dbg "Wrote $out"
}

# =========================
# CLOUD-INIT SEED MAKERS
# =========================
make_user_data() {
  local vm="$1" ip="$2" cidr="$3" gw="$4" is_web="$5" mac="$6"
  local outf="${SEED_DIR}/${vm}-user-data.yaml"
  {
    echo "#cloud-config"
    echo "timezone: \"$TIMEZONE\""

    # (매우 이른 단계) 부팅 초반에 비번/SSH 허용 보장
    if [[ "${ENABLE_PW_AUTH}" = "1" ]]; then
      echo "bootcmd:"
      echo "  - [ bash, -lc, \"echo '${LOGIN_USERNAME}:${LOGIN_PASSWORD}' | chpasswd\" ]"
      echo "  - [ bash, -lc, \"sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true\" ]"
      echo "  - [ bash, -lc, \"systemctl try-restart ssh || systemctl try-restart sshd || true\" ]"
    fi

    # (선택) cloud-init 로깅 상향 + 우리가 쓴 파일도 남김
    if [[ "${DEBUG_CLOUDINIT}" = "1" ]]; then
      cat <<'EODBG'
write_files:
  - path: /etc/cloud/cloud.cfg.d/99-debug.cfg
    permissions: '0644'
    content: |
      # Increase cloud-init verbosity
      system_info:
        default_user:
          name: ubuntu
      debug: true
      verbose: true
      apt:
        preserve_sources_list: true
EODBG
    else
      echo "write_files: []"
    fi

    echo "ssh_authorized_keys:"
    echo "  - \"$SSH_PUBLIC_KEY\""
    echo "package_update: true"
    echo "packages: [docker.io, docker-compose-plugin, net-tools, qemu-guest-agent]"

    # (옵션) 웹/내부 컴포즈/SECcomp 파일
    if [[ "$is_web" == "yes" ]]; then
      cat <<'EOS'
runcmd:
  - [ bash, -lc, "systemctl enable --now qemu-guest-agent || true" ]
  - [ bash, -lc, "printf '%s\n' \"$WEB_COMPOSE\" > /home/ubuntu/docker-compose.yml" ]
  - [ bash, -lc, "printf '%s\n' \"$WEB_SECCOMP\" > /home/ubuntu/web_seccomp.json" ]
  - [ bash, -lc, "chown -R ubuntu:ubuntu /home/ubuntu || true" ]
  - [ bash, -lc, "docker compose -f /home/ubuntu/docker-compose.yml up -d || true" ]
EOS
    else
      cat <<'EOS'
runcmd:
  - [ bash, -lc, "systemctl enable --now qemu-guest-agent || true" ]
  - [ bash, -lc, "printf '%s\n' \"$INT_COMPOSE\" > /home/ubuntu/docker-compose.yml" ]
  - [ bash, -lc, "chown -R ubuntu:ubuntu /home/ubuntu || true" ]
  - [ bash, -lc, "docker compose -f /home/ubuntu/docker-compose.yml up -d || true" ]
EOS
    fi

    # 부팅 직후 자동 경화(선택)
    if [[ "${DISABLE_PW_ON_BOOT}" = "1" ]]; then
      echo "  - [ bash, -lc, \"passwd -l ${LOGIN_USERNAME} || true\" ]"
      echo "  - [ bash, -lc, \"sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true\" ]"
      echo "  - [ bash, -lc, \"systemctl try-restart ssh || systemctl try-restart sshd || true\" ]"
    fi

    # 네트워크 디버깅: wait-online이 과도하게 막는 경우가 있어 마스킹(옵션)
    echo "  - [ bash, -lc, \"systemctl disable --now systemd-networkd-wait-online.service || true\" ]"
  } > "$outf"
  dbg "Wrote $outf"
}

make_meta_data() {
  local vm="$1"
  local outf="${SEED_DIR}/${vm}-meta-data.yaml"
  cat > "$outf" <<EOF
instance-id: ${vm}
local-hostname: ${vm}
EOF
  dbg "Wrote $outf"
}

build_seeds() {
  log "[4/8] Generating cloud-init seed ISOs in $SEED_DIR ..."
  mkdir -p "$SEED_DIR"

  # 1) per-VM network-config 생성 (MAC 매칭)
  make_network_config "$WEB_VM_IP" "$WEB_VM_CIDR" "$HOST_DMZ_GW" "$WEB_VM_MAC" "$WEB_NETCFG"
  make_network_config "$INTERNAL_VM_IP" "$INTERNAL_VM_CIDR" "$HOST_INT_GW" "$INTERNAL_VM_MAC" "$INT_NETCFG"

  # 2) user-data/meta-data 생성
  make_user_data "$WEB_VM_NAME"      "$WEB_VM_IP"      "$WEB_VM_CIDR"      "$HOST_DMZ_GW" "yes" "$WEB_VM_MAC"
  make_meta_data "$WEB_VM_NAME"
  make_user_data "$INTERNAL_VM_NAME" "$INTERNAL_VM_IP" "$INTERNAL_VM_CIDR" "$HOST_INT_GW" "no"  "$INTERNAL_VM_MAC"
  make_meta_data "$INTERNAL_VM_NAME"

  # 3) 시드 ISO: network-config를 -N 로 주입 (NoCloud 권장 방식)
  cloud-localds -N "$WEB_NETCFG" "$WEB_SEED_ISO" \
      "${SEED_DIR}/${WEB_VM_NAME}-user-data.yaml" \
      "${SEED_DIR}/${WEB_VM_NAME}-meta-data.yaml" | tee -a "$LOG_FILE"

  cloud-localds -N "$INT_NETCFG" "$INT_SEED_ISO" \
      "${SEED_DIR}/${INTERNAL_VM_NAME}-user-data.yaml" \
      "${SEED_DIR}/${INTERNAL_VM_NAME}-meta-data.yaml" | tee -a "$LOG_FILE"

  log "Seed ISOs ready: $WEB_SEED_ISO , $INT_SEED_ISO"
}

undefine_if_exists() {
  local name="$1"
  if virsh dominfo "$name" >/dev/null 2>&1; then
    log "Cleaning existing domain: $name"
    virsh destroy "$name" >/dev/null 2>&1 || true
    virsh undefine "$name" --nvram >/dev/null 2>&1 || virsh undefine "$name" >/dev/null 2>&1 || true
  fi
}

define_and_boot_vms() {
  log "[5/8] Defining/booting VMs with virt-install --import ..."

  undefine_if_exists "$WEB_VM_NAME"
  undefine_if_exists "$INTERNAL_VM_NAME"

  # web-vm
  virt-install \
    --name "$WEB_VM_NAME" \
    --memory "$WEB_VM_MEM" --vcpus "$WEB_VM_CPUS" \
    --disk "path=${WEB_DISK},format=qcow2" \
    --disk "path=${WEB_SEED_ISO},device=cdrom,bus=sata" \
    --network "bridge=${BR_EXTERNAL},model=virtio,mac=${WEB_VM_MAC}" \
    --channel "unix,mode=bind,target_type=virtio,name=org.qemu.guest_agent.0" \
    --import \
    --os-variant ubuntu22.04 \
    --noautoconsole | tee -a "$LOG_FILE"

  # internal-vm
  virt-install \
    --name "$INTERNAL_VM_NAME" \
    --memory "$INTERNAL_VM_MEM" --vcpus "$INTERNAL_VM_CPUS" \
    --disk "path=${INT_DISK},format=qcow2" \
    --disk "path=${INT_SEED_ISO},device=cdrom,bus=sata" \
    --network "bridge=${BR_INTERNAL},model=virtio,mac=${INTERNAL_VM_MAC}" \
    --channel "unix,mode=bind,target_type=virtio,name=org.qemu.guest_agent.0" \
    --import \
    --os-variant ubuntu22.04 \
    --noautoconsole | tee -a "$LOG_FILE"

  log "[6/8] VMs launched. Cloud-init is applying configuration on first boot."
}

wait_ssh() {
  local ip="$1" dur="$2"
  log "Waiting for SSH on $ip (timeout ${dur}s)..."
  local start=$(date +%s)
  while true; do
    if timeout 2 bash -lc "nc -z -w1 $ip 22" >/dev/null 2>&1; then
      log "SSH is up on $ip"
      return 0
    fi
    sleep 3
    local now=$(date +%s)
    (( now-start > dur )) && { err "SSH did not open on $ip within ${dur}s"; return 1; }
  done
}
