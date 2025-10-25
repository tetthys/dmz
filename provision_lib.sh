#!/usr/bin/env bash
# =====================================================================
# provision_lib.sh — DMZ VM provision library (v7)
# ---------------------------------------------------------------------
#  - Generates NoCloud (user/meta/network) ISO seeds for KVM VMs
#  - Creates temporary egress table for cloud-init apt packages
#  - Enables password + SSH at boot (lab mode)
#  - Enables qemu-guest-agent automatically
#  - Logs clearly with section headers
# =====================================================================
set -Eeuo pipefail

# ===== Auto-load .env =====
if [ -f ".env" ]; then
  set -a; . ./.env; set +a
fi

# ===== Defaults (override by .env) =====
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

WEB_VM_MAC="${WEB_VM_MAC:-52:54:00:aa:bb:01}"
INTERNAL_VM_MAC="${INTERNAL_VM_MAC:-52:54:00:aa:bb:02}"

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
WEB_SEED_ISO="${SEED_DIR}/${WEB_VM_NAME}-seed.iso"
INT_SEED_ISO="${SEED_DIR}/${INTERNAL_VM_NAME}-seed.iso"

WEB_NETCFG="${SEED_DIR}/${WEB_VM_NAME}-network-config.yaml"
INT_NETCFG="${SEED_DIR}/${INTERNAL_VM_NAME}-network-config.yaml"

INTERNAL_API_PORT="${INTERNAL_API_PORT:-8443}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-REPLACE_WITH_YOUR_SSH_PUBLIC_KEY}"
TIMEZONE="${TIMEZONE:-Asia/Seoul}"

LOG_FILE="${LOG_FILE:-$(pwd)/provision.log}"
VERBOSE="${VERBOSE:-1}"
WAIT_SSH="${WAIT_SSH:-0}"
SSH_TIMEOUT_SEC="${SSH_TIMEOUT_SEC:-180}"

ENABLE_PW_AUTH="${ENABLE_PW_AUTH:-1}"
LOGIN_USERNAME="${LOGIN_USERNAME:-ubuntu}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-ubuntu}"
DISABLE_PW_ON_BOOT="${DISABLE_PW_ON_BOOT:-1}"

DEBUG_CLOUDINIT="${DEBUG_CLOUDINIT:-0}"
PROVISIONING_EGRESS_SECS="${PROVISIONING_EGRESS_SECS:-900}"

# ===== Logging =====
ts(){ date +"%Y-%m-%d %H:%M:%S%z"; }
log(){ echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
dbg(){ [[ "${VERBOSE}" = "1" ]] && log "[DEBUG] $*"; true; }
err(){ echo "[$(ts)] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }
section(){ echo -e "\n========== $* ==========" | tee -a "$LOG_FILE"; }

trap 'rc=$?; err "Failed at line $LINENO (exit $rc). See $LOG_FILE for details."; exit $rc' ERR

# ===== Utilities =====
need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

# ---------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------
preflight(){
  : > "$LOG_FILE" || true
  section "[1/8] Preflight checks"
  for b in wget qemu-img virt-install cloud-localds virsh nft; do need "$b"; done
  ip link show "$BR_EXTERNAL" >/dev/null 2>&1 || { err "Bridge $BR_EXTERNAL not found"; exit 1; }
  ip link show "$BR_INTERNAL" >/dev/null 2>&1 || { err "Bridge $BR_INTERNAL not found"; exit 1; }
  [[ "$SSH_PUBLIC_KEY" == "REPLACE_WITH_YOUR_SSH_PUBLIC_KEY" ]] && { err "SSH_PUBLIC_KEY not set"; exit 1; }
  log "Bridges OK: $BR_EXTERNAL, $BR_INTERNAL"
}

# ---------------------------------------------------------------------
# 2. Ensure base cloud image
# ---------------------------------------------------------------------
ensure_cloud_image(){
  section "[2/8] Ensure base cloud image"
  mkdir -p "$IMG_DIR"
  if [[ ! -f "$CLOUD_IMG" ]]; then
    log "Downloading from $CLOUD_IMG_URL ..."
    wget -O "$CLOUD_IMG" "$CLOUD_IMG_URL" 2>&1 | tee -a "$LOG_FILE"
  else
    log "Found existing cloud image: $CLOUD_IMG"
  fi
}

# ---------------------------------------------------------------------
# 3. Create VM disks
# ---------------------------------------------------------------------
create_disks(){
  section "[3/8] Create VM disks"
  if [[ ! -f "$WEB_DISK" ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "$CLOUD_IMG" "$WEB_DISK"
    log "Created $WEB_DISK"
  else
    log "Reusing $WEB_DISK"
  fi
  if [[ ! -f "$INT_DISK" ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "$CLOUD_IMG" "$INT_DISK"
    log "Created $INT_DISK"
  else
    log "Reusing $INT_DISK"
  fi
}

# ---------------------------------------------------------------------
# 4. Generate network configs
# ---------------------------------------------------------------------
make_network_config(){
  local ip="$1" cidr="$2" gw="$3" mac="$4" out="$5"
  mkdir -p "$(dirname "$out")"
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

# ---------------------------------------------------------------------
# 5. Generate user/meta cloud-init
# ---------------------------------------------------------------------
make_user_data(){
  local vm="$1" ip="$2" cidr="$3" gw="$4" is_web="$5" mac="$6"
  local outf="${SEED_DIR}/${vm}-user-data.yaml"
  mkdir -p "$SEED_DIR"
  {
    echo "#cloud-config"
    echo "timezone: \"$TIMEZONE\""

    # Bootcmd for SSH + password
    if [[ "${ENABLE_PW_AUTH}" = "1" ]]; then
      echo "bootcmd:"
      echo "  - [ bash, -lc, \"echo '${LOGIN_USERNAME}:${LOGIN_PASSWORD}' | chpasswd\" ]"
      echo "  - [ bash, -lc, \"mkdir -p /etc/ssh/sshd_config.d\" ]"
      echo "  - [ bash, -lc, \"printf '%s\\n' 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/99-pwauth.conf\" ]"
      echo "  - [ bash, -lc, \"sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true\" ]"
      echo "  - [ bash, -lc, \"systemctl enable --now ssh || systemctl enable --now sshd || true\" ]"
    fi

    echo "package_update: true"
    echo "apt:"
    echo "  preserve_sources_list: true"

    echo "runcmd:"
    echo "  - [ bash, -lc, \"export DEBIAN_FRONTEND=noninteractive; apt-get update -y || true\" ]"
    echo "  - [ bash, -lc, \"export DEBIAN_FRONTEND=noninteractive; apt-get install -y openssh-server qemu-guest-agent docker.io docker-compose-plugin net-tools || true\" ]"
    echo "  - [ bash, -lc, \"systemctl enable --now qemu-guest-agent || true\" ]"

    if [[ "$is_web" == "yes" ]]; then
      cat <<'EOS'
  - [ bash, -lc, "cat > /home/ubuntu/docker-compose.yml <<'YML'\nversion: '3.8'\nservices:\n  web:\n    image: nginx:stable\n    user: \"101:101\"\n    read_only: true\n    tmpfs: [\"/tmp\",\"/var/cache/nginx\",\"/var/run\"]\n    cap_drop: [\"ALL\"]\n    environment:\n      - INTERNAL_API_URL=https://10.10.0.11:8443\n    ports: [\"443:443\"]\nYML" ]
EOS
    else
      cat <<'EOS'
  - [ bash, -lc, "cat > /home/ubuntu/docker-compose.yml <<'YML'\nversion: '3.8'\nservices:\n  internal-service:\n    image: hashicorp/http-echo:0.2.3\n    command: [\"-text=OK\",\"-listen=:8443\"]\n    tmpfs: [\"/run/secrets\"]\nYML" ]
EOS
    fi
    echo "  - [ bash, -lc, \"chown -R ubuntu:ubuntu /home/ubuntu || true\" ]"
    echo "  - [ bash, -lc, \"cd /home/ubuntu && docker compose up -d || true\" ]"
    echo "  - [ bash, -lc, \"systemctl disable --now systemd-networkd-wait-online.service || true\" ]"

    if [[ "${DISABLE_PW_ON_BOOT}" = "1" ]]; then
      echo "  - [ bash, -lc, \"passwd -l ${LOGIN_USERNAME} || true\" ]"
      echo "  - [ bash, -lc, \"sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true\" ]"
      echo "  - [ bash, -lc, \"systemctl try-restart ssh || systemctl try-restart sshd || true\" ]"
    fi
  } > "$outf"
  dbg "Wrote $outf"
}

make_meta_data(){
  local vm="$1"
  local outf="${SEED_DIR}/${vm}-meta-data.yaml"
  cat > "$outf" <<EOF
instance-id: ${vm}
local-hostname: ${vm}
EOF
  dbg "Wrote $outf"
}

# ---------------------------------------------------------------------
# 6. Build cloud-init seeds
# ---------------------------------------------------------------------
build_seeds(){
  section "[4/8] Build cloud-init seed ISOs"
  mkdir -p "$SEED_DIR"
  make_network_config "$WEB_VM_IP" "$WEB_VM_CIDR" "$HOST_DMZ_GW" "$WEB_VM_MAC" "$WEB_NETCFG"
  make_network_config "$INTERNAL_VM_IP" "$INTERNAL_VM_CIDR" "$HOST_INT_GW" "$INTERNAL_VM_MAC" "$INT_NETCFG"
  make_user_data "$WEB_VM_NAME" "$WEB_VM_IP" "$WEB_VM_CIDR" "$HOST_DMZ_GW" "yes" "$WEB_VM_MAC"
  make_meta_data "$WEB_VM_NAME"
  make_user_data "$INTERNAL_VM_NAME" "$INTERNAL_VM_IP" "$INTERNAL_VM_CIDR" "$HOST_INT_GW" "no" "$INTERNAL_VM_MAC"
  make_meta_data "$INTERNAL_VM_NAME"

  cloud-localds -N "$WEB_NETCFG" "$WEB_SEED_ISO" \
      "${SEED_DIR}/${WEB_VM_NAME}-user-data.yaml" \
      "${SEED_DIR}/${WEB_VM_NAME}-meta-data.yaml"
  cloud-localds -N "$INT_NETCFG" "$INT_SEED_ISO" \
      "${SEED_DIR}/${INTERNAL_VM_NAME}-user-data.yaml" \
      "${SEED_DIR}/${INTERNAL_VM_NAME}-meta-data.yaml"

  log "Seed ISOs ready: $WEB_SEED_ISO , $INT_SEED_ISO"
}

# ---------------------------------------------------------------------
# 7. Temporary egress control (HTTP/HTTPS/DNS)
# ---------------------------------------------------------------------
enable_temp_egress(){
  section "[4b] Enable temporary egress (HTTP/HTTPS/DNS) for web-vm"

  # 잔여 테이블 제거
  nft list table inet dmz_prov >/dev/null 2>&1 && nft delete table inet dmz_prov || true

  # 독립 테이블 생성
  nft add table inet dmz_prov

  # forward 훅, 우선순위 낮게(-150) 지정해서 다른 테이블보다 '먼저' 평가되도록
  # 정책은 drop 으로 두고, 필요한 것만 명시 허용
  nft add chain inet dmz_prov forward '{ type filter hook forward priority -150; policy drop; }'

  # ESTABLISHED/RELATED 허용
  nft add rule  inet dmz_prov forward ct state established,related counter accept

  # web-vm → DNS (UDP/TCP 53) 허용
  nft add rule  inet dmz_prov forward ip saddr ${WEB_VM_IP} udp dport 53 counter accept
  nft add rule  inet dmz_prov forward ip saddr ${WEB_VM_IP} tcp dport 53 counter accept

  # web-vm → HTTP/HTTPS 허용 (안정성을 위해 포트별로 2줄 처리)
  nft add rule  inet dmz_prov forward ip saddr ${WEB_VM_IP} tcp dport 80  counter accept
  nft add rule  inet dmz_prov forward ip saddr ${WEB_VM_IP} tcp dport 443 counter accept

  log "Temporary egress table 'inet dmz_prov' created (priority -150, policy drop, allow: 53/udp,53/tcp,80,443)."
}

disable_temp_egress(){
  section "[6b] Disable temporary egress table inet dmz_prov"
  nft list table inet dmz_prov >/dev/null 2>&1 && nft delete table inet dmz_prov || true
  log "Temporary egress removed."
}

schedule_disable_egress(){
  local secs="${1:-$PROVISIONING_EGRESS_SECS}"
  ( sleep "$secs"; nft list table inet dmz_prov >/dev/null 2>&1 && nft delete table inet dmz_prov || true ) >/dev/null 2>&1 &
  dbg "Scheduled dmz_prov removal in ${secs}s (PID $!)"
}

# ---------------------------------------------------------------------
# 8. Define and boot VMs
# ---------------------------------------------------------------------
undefine_if_exists(){
  local name="$1"
  if virsh dominfo "$name" >/dev/null 2>&1; then
    log "Cleaning existing domain: $name"
    virsh destroy "$name" >/dev/null 2>&1 || true
    virsh undefine "$name" --nvram >/dev/null 2>&1 || virsh undefine "$name" >/dev/null 2>&1 || true
  fi
}

define_and_boot_vms(){
  section "[5/8] Define & boot VMs"
  undefine_if_exists "$WEB_VM_NAME"
  undefine_if_exists "$INTERNAL_VM_NAME"

  virt-install \
    --name "$WEB_VM_NAME" \
    --memory "$WEB_VM_MEM" --vcpus "$WEB_VM_CPUS" \
    --disk "path=${WEB_DISK},format=qcow2" \
    --disk "path=${WEB_SEED_ISO},device=cdrom,bus=sata" \
    --network "bridge=${BR_EXTERNAL},model=virtio,mac=${WEB_VM_MAC}" \
    --channel "unix,mode=bind,target_type=virtio,name=org.qemu.guest_agent.0" \
    --import --os-variant ubuntu22.04 --noautoconsole

  virt-install \
    --name "$INTERNAL_VM_NAME" \
    --memory "$INTERNAL_VM_MEM" --vcpus "$INTERNAL_VM_CPUS" \
    --disk "path=${INT_DISK},format=qcow2" \
    --disk "path=${INT_SEED_ISO},device=cdrom,bus=sata" \
    --network "bridge=${BR_INTERNAL},model=virtio,mac=${INTERNAL_VM_MAC}" \
    --channel "unix,mode=bind,target_type=virtio,name=org.qemu.guest_agent.0" \
    --import --os-variant ubuntu22.04 --noautoconsole

  log "Launched both VMs. cloud-init boot running..."
}
