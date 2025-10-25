#!/usr/bin/env bash
# =====================================================================
# provision_lib.sh — DMZ VM Provision Library (clean, cloud-init official)
# - Builds NoCloud seed ISOs (user-data/meta-data/network-config v2)
# - Defines & boots KVM VMs via virt-install --import
# - Optional temporary egress (HTTP/HTTPS/DNS) for initial apt packages
# =====================================================================
set -Eeuo pipefail

# -----------------------------
# Load .env (if present)
# -----------------------------
if [ -f ".env" ]; then
  set -a; . ./.env; set +a
fi

# -----------------------------
# Defaults (override by .env)
# -----------------------------
BR_EXTERNAL="${BR_EXTERNAL:-br-external}"
BR_INTERNAL="${BR_INTERNAL:-br-internal}"

HOST_DMZ_GW="${HOST_DMZ_GW:-192.0.2.1}"
HOST_INT_GW="${HOST_INT_GW:-10.10.0.1}"

WEB_VM_NAME="${WEB_VM_NAME:-web-vm}"
WEB_VM_IP="${WEB_VM_IP:-192.0.2.101}"
WEB_VM_CIDR="${WEB_VM_CIDR:-24}"
WEB_VM_MAC="${WEB_VM_MAC:-52:54:00:aa:bb:01}"

INTERNAL_VM_NAME="${INTERNAL_VM_NAME:-internal-vm}"
INTERNAL_VM_IP="${INTERNAL_VM_IP:-10.10.0.11}"
INTERNAL_VM_CIDR="${INTERNAL_VM_CIDR:-24}"
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

TIMEZONE="${TIMEZONE:-Asia/Seoul}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-REPLACE_WITH_YOUR_SSH_PUBLIC_KEY}"

# (Optional) temporary egress window in seconds (for apt)
ENABLE_TEMP_EGRESS="${ENABLE_TEMP_EGRESS:-1}"
PROVISIONING_EGRESS_SECS="${PROVISIONING_EGRESS_SECS:-900}"

# Password login (LAB ONLY). Official keys: ssh_pwauth / users / chpasswd
ENABLE_PW_AUTH="${ENABLE_PW_AUTH:-1}"
LOGIN_USERNAME="${LOGIN_USERNAME:-ubuntu}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-ubuntu}"
# Set DISABLE_PW_ON_BOOT=1 later via manual hardening if desired

# Logging
LOG_FILE="${LOG_FILE:-$(pwd)/provision.log}"
VERBOSE="${VERBOSE:-1}"
WAIT_SSH="${WAIT_SSH:-1}"
SSH_TIMEOUT_SEC="${SSH_TIMEOUT_SEC:-300}"

# -----------------------------
# Logging helpers & trap
# -----------------------------
ts(){ date +"%Y-%m-%d %H:%M:%S%z"; }
log(){ echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
dbg(){ [[ "${VERBOSE}" = "1" ]] && log "[DEBUG] $*"; true; }
err(){ echo "[$(ts)] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }
section(){ echo -e "\n========== $* ==========" | tee -a "$LOG_FILE"; }
trap 'rc=$?; err "Failed at line $LINENO (exit $rc). See $LOG_FILE for details."; exit $rc' ERR

need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

# -----------------------------
# 1) Preflight
# -----------------------------
preflight() {
  : > "$LOG_FILE" || true
  section "[1/8] Preflight checks"
  for b in wget qemu-img virt-install cloud-localds virsh nft; do need "$b"; done
  ip link show "$BR_EXTERNAL" >/dev/null 2>&1 || { err "Bridge $BR_EXTERNAL not found"; exit 1; }
  ip link show "$BR_INTERNAL" >/dev/null 2>&1 || { err "Bridge $BR_INTERNAL not found"; exit 1; }
  [[ "$SSH_PUBLIC_KEY" == "REPLACE_WITH_YOUR_SSH_PUBLIC_KEY" ]] && { err "Set SSH_PUBLIC_KEY in .env"; exit 1; }
  log "Bridges OK: $BR_EXTERNAL, $BR_INTERNAL"
}

# -----------------------------
# 2) Ensure cloud image
# -----------------------------
ensure_cloud_image() {
  section "[2/8] Ensure base cloud image"
  mkdir -p "$IMG_DIR"
  if [[ ! -f "$CLOUD_IMG" ]]; then
    log "Downloading $CLOUD_IMG_URL ..."
    wget -O "$CLOUD_IMG" "$CLOUD_IMG_URL" 2>&1 | tee -a "$LOG_FILE"
  else
    log "Found $CLOUD_IMG (reuse)"
  fi
}

# -----------------------------
# 3) Create VM disks (backed by base)
# -----------------------------
create_disks() {
  section "[3/8] Create qcow2 disks"
  if [[ ! -f "$WEB_DISK" ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "$CLOUD_IMG" "$WEB_DISK"
    log "Created $WEB_DISK"
  else
    log "Reuse $WEB_DISK"
  fi
  if [[ ! -f "$INT_DISK" ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "$CLOUD_IMG" "$INT_DISK"
    log "Created $INT_DISK"
  else
    log "Reuse $INT_DISK"
  fi
}

# -----------------------------
# 4) Generate network-config (v2, MAC match)
# -----------------------------
make_network_config() {
  local ip="$1" cidr="$2" gw="$3" mac="$4" out="$5"
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<EOF
version: 2
ethernets:
  dmznic0:
    match:
      macaddress: "${mac}"
    set-name: dmznic0
    addresses: [ ${ip}/${cidr} ]
    gateway4: ${gw}
    nameservers:
      addresses: [1.1.1.1,8.8.8.8]
EOF
  dbg "Wrote $out"
}

# -----------------------------
# 5) Generate user-data / meta-data
# -----------------------------
make_user_data() {
  local vm="$1" is_web="$2"
  local outf="${SEED_DIR}/${vm}-user-data.yaml"
  mkdir -p "$SEED_DIR"

  # cloud-init official keys only
  # - ssh_pwauth: true/false
  # - users: name + sudo + shell
  # - chpasswd: { list: | user:pass, expire: false }
  # - ssh_authorized_keys
  # - package_update / packages
  # - timezone / runcmd
  cat > "$outf" <<EOF
#cloud-config
timezone: "${TIMEZONE}"

ssh_pwauth: ${ENABLE_PW_AUTH}

users:
  - name: ${LOGIN_USERNAME}
    gecos: "Default user"
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

chpasswd:
  list: |
    ${LOGIN_USERNAME}:${LOGIN_PASSWORD}
  expire: false

package_update: true
packages:
  - openssh-server
  - qemu-guest-agent
  - docker.io
  - docker-compose-plugin
  - net-tools

runcmd:
  - [ bash, -lc, "systemctl enable --now ssh || systemctl enable --now sshd || true" ]
  - [ bash, -lc, "systemctl enable --now qemu-guest-agent || true" ]
EOF
  if [[ "$is_web" == "yes" ]]; then
    cat >> "$outf" <<'EOF'
  - [ bash, -lc, "cat > /home/ubuntu/docker-compose.yml <<'YML'\nversion: '3.8'\nservices:\n  web:\n    image: nginx:stable\n    ports: [\"443:443\"]\n    read_only: true\n    tmpfs: [\"/tmp\",\"/var/cache/nginx\",\"/var/run\"]\nYML" ]
  - [ bash, -lc, "chown -R ubuntu:ubuntu /home/ubuntu && cd /home/ubuntu && docker compose up -d || true" ]
EOF
  else
    cat >> "$outf" <<'EOF'
  - [ bash, -lc, "cat > /home/ubuntu/docker-compose.yml <<'YML'\nversion: '3.8'\nservices:\n  internal-service:\n    image: hashicorp/http-echo:0.2.3\n    command: [\"-text=OK\",\"-listen=:8443\"]\nYML" ]
  - [ bash, -lc, "chown -R ubuntu:ubuntu /home/ubuntu && cd /home/ubuntu && docker compose up -d || true" ]
EOF
  fi
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

# -----------------------------
# 6) Build NoCloud seed ISOs
# -----------------------------
build_seeds() {
  section "[4/8] Build NoCloud seed ISOs"
  mkdir -p "$SEED_DIR"

  # --- web ---
  make_network_config "$WEB_VM_IP" "$WEB_VM_CIDR" "$HOST_DMZ_GW" "$WEB_VM_MAC" "$WEB_NETCFG"
  make_user_data "$WEB_VM_NAME" "yes"
  make_meta_data "$WEB_VM_NAME"
  cloud-localds -N "$WEB_NETCFG" "$WEB_SEED_ISO" \
      "${SEED_DIR}/${WEB_VM_NAME}-user-data.yaml" \
      "${SEED_DIR}/${WEB_VM_NAME}-meta-data.yaml"

  # --- internal ---
  make_network_config "$INTERNAL_VM_IP" "$INTERNAL_VM_CIDR" "$HOST_INT_GW" "$INTERNAL_VM_MAC" "$INT_NETCFG"
  make_user_data "$INTERNAL_VM_NAME" "no"
  make_meta_data "$INTERNAL_VM_NAME"
  cloud-localds -N "$INT_NETCFG" "$INT_SEED_ISO" \
      "${SEED_DIR}/${INTERNAL_VM_NAME}-user-data.yaml" \
      "${SEED_DIR}/${INTERNAL_VM_NAME}-meta-data.yaml"

  log "Seed ISOs ready: $WEB_SEED_ISO , $INT_SEED_ISO"
}

# -----------------------------
# 7) Temporary egress (HTTP/HTTPS/DNS) – optional
# -----------------------------
enable_temp_egress() {
  section "[4b] Enable temporary egress (HTTP/HTTPS/DNS) for web-vm"
  nft list table inet dmz_prov >/dev/null 2>&1 && nft delete table inet dmz_prov || true
  nft add table inet dmz_prov
  # set early priority (smaller = earlier) and default drop, then allow what we need
  nft add chain inet dmz_prov forward '{ type filter hook forward priority -150; policy drop; }'
  nft add rule  inet dmz_prov forward ct state established,related counter accept
  nft add rule  inet dmz_prov forward ip saddr ${WEB_VM_IP} udp dport 53 counter accept
  nft add rule  inet dmz_prov forward ip saddr ${WEB_VM_IP} tcp dport 53 counter accept
  nft add rule  inet dmz_prov forward ip saddr ${WEB_VM_IP} tcp dport 80  counter accept
  nft add rule  inet dmz_prov forward ip saddr ${WEB_VM_IP} tcp dport 443 counter accept
  log "Temporary egress (53/udp,53/tcp,80,443) enabled."
}

disable_temp_egress() {
  section "[6b] Disable temporary egress"
  nft list table inet dmz_prov >/dev/null 2>&1 && nft delete table inet dmz_prov || true
  log "Temporary egress removed."
}

schedule_disable_egress() {
  local secs="${1:-$PROVISIONING_EGRESS_SECS}"
  ( sleep "$secs"; nft list table inet dmz_prov >/dev/null 2>&1 && nft delete table inet dmz_prov || true ) >/dev/null 2>&1 &
  dbg "Scheduled dmz_prov removal in ${secs}s (PID $!)"
}

# -----------------------------
# 8) Define & boot VMs
# -----------------------------
undefine_if_exists() {
  local name="$1"
  if virsh dominfo "$name" >/dev/null 2>&1; then
    log "Cleaning existing domain: $name"
    virsh destroy "$name" >/dev/null 2>&1 || true
    virsh undefine "$name" --nvram >/dev/null 2>&1 || virsh undefine "$name" >/dev/null 2>&1 || true
  fi
}

define_and_boot_vms() {
  section "[5/8] Define & boot VMs"
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
    --import --os-variant ubuntu22.04 --noautoconsole

  # internal-vm
  virt-install \
    --name "$INTERNAL_VM_NAME" \
    --memory "$INTERNAL_VM_MEM" --vcpus "$INTERNAL_VM_CPUS" \
    --disk "path=${INT_DISK},format=qcow2" \
    --disk "path=${INT_SEED_ISO},device=cdrom,bus=sata" \
    --network "bridge=${BR_INTERNAL},model=virtio,mac=${INTERNAL_VM_MAC}" \
    --channel "unix,mode=bind,target_type=virtio,name=org.qemu.guest_agent.0" \
    --import --os-variant ubuntu22.04 --noautoconsole

  log "Launched. cloud-init first boot running."
}

# -----------------------------
# 9) Wait for SSH helper
# -----------------------------
wait_ssh() {
  local ip="$1" dur="$2"
  section "[7/8] Wait for SSH on ${ip}"
  local start=$(date +%s)
  while true; do
    if timeout 2 bash -lc "nc -z -w1 $ip 22" >/dev/null 2>&1; then
      log "SSH is up on $ip"
      return 0
    fi
    sleep 3
    (( $(date +%s) - start > dur )) && { err "SSH did not open on $ip within ${dur}s"; return 1; }
  done
}
