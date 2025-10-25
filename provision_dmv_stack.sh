#!/usr/bin/env bash
# ===========================================================
# DMZ Stack Provisioner (v2.1) - detailed logging & heredoc fix
# - Creates two KVM VMs from Ubuntu cloud image:
#     * web-vm on br-external (DMZ)
#     * internal-vm on br-internal (Internal)
# - Each VM auto-installs docker & docker compose via cloud-init,
#   writes compose files, and runs `docker compose up -d`.
# - Idempotent: safe to re-run if interrupted mid-way.
# ===========================================================

set -Eeuo pipefail

# Load .env if present (export all vars)
if [ -f ".env" ]; then
  set -a; . ./.env; set +a
fi

### ----- CONFIGURABLE VARS (EDIT ME) -----
BR_EXTERNAL="br-external"
BR_INTERNAL="br-internal"

HOST_DMZ_GW="192.0.2.1"
HOST_INT_GW="10.10.0.1"

WEB_VM_NAME="web-vm"
WEB_VM_IP="192.0.2.101"
WEB_VM_CIDR="24"

INTERNAL_VM_NAME="internal-vm"
INTERNAL_VM_IP="10.10.0.11"
INTERNAL_VM_CIDR="24"

# Often "ens3" for Ubuntu cloud images
GUEST_IFACE_NAME="ens3"

WEB_VM_MEM="4096"
WEB_VM_CPUS="2"
INTERNAL_VM_MEM="4096"
INTERNAL_VM_CPUS="2"

IMG_DIR="/var/lib/libvirt/images"
CLOUD_IMG="${IMG_DIR}/ubuntu-22.04-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

WEB_DISK="${IMG_DIR}/${WEB_VM_NAME}.qcow2"
INT_DISK="${IMG_DIR}/${INTERNAL_VM_NAME}.qcow2"

SEED_DIR="/var/lib/libvirt/cloud-seed"
WEB_SEED_ISO="${SEED_DIR}/${WEB_VM_NAME}-seed.iso"
INT_SEED_ISO="${SEED_DIR}/${INTERNAL_VM_NAME}-seed.iso"

INTERNAL_API_PORT="8443"

# REQUIRED: put your SSH pubkey
SSH_PUBLIC_KEY="REPLACE_WITH_YOUR_SSH_PUBLIC_KEY"

TIMEZONE="Asia/Seoul"

LOG_FILE="$(pwd)/provision.log"
VERBOSE="${VERBOSE:-1}"   # set 0 for quieter
WAIT_SSH="${WAIT_SSH:-1}" # 0 to skip
SSH_TIMEOUT_SEC=180
### ----- END CONFIG -----

# ====== Logging helpers ======
ts() { date +"%Y-%m-%d %H:%M:%S%z"; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
dbg() { [[ "$VERBOSE" = "1" ]] && log "[DEBUG] $*"; true; }
err() { echo "[$(ts)] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

trap 'rc=$?; err "Failed at line $LINENO (exit $rc). See $LOG_FILE for details."; exit $rc' ERR
[[ "$VERBOSE" = "1" ]] && set -x

# ====== Preflight ======
need() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

: > "$LOG_FILE" || true
log "===== DMZ Provisioner v2.1 starting ====="

log "[1/8] Preflight checks..."
for bin in wget qemu-img virt-install cloud-localds virsh; do need "$bin"; done

ip link show "$BR_EXTERNAL" >/dev/null 2>&1 || { err "Bridge $BR_EXTERNAL not found. Run host_setup.sh first."; exit 1; }
ip link show "$BR_INTERNAL" >/dev/null 2>&1 || { err "Bridge $BR_INTERNAL not found. Run host_setup.sh first."; exit 1; }
log "Bridges OK: $BR_EXTERNAL, $BR_INTERNAL"

if [[ "$SSH_PUBLIC_KEY" == "REPLACE_WITH_YOUR_SSH_PUBLIC_KEY" ]]; then
  err "SSH_PUBLIC_KEY is not set. Paste your public key into the script."
  exit 1
fi

# ====== Download cloud image ======
log "[2/8] Ensuring base cloud image exists at $CLOUD_IMG ..."
mkdir -p "$IMG_DIR"
if [[ ! -f "$CLOUD_IMG" ]]; then
  log "Downloading cloud image from: $CLOUD_IMG_URL"
  wget -O "$CLOUD_IMG" "$CLOUD_IMG_URL" 2>&1 | tee -a "$LOG_FILE"
else
  log "Cloud image already present. Skipping download."
fi

# ====== Create VM disks ======
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

# ====== cloud-init seed generation ======
log "[4/8] Generating cloud-init seed ISOs in $SEED_DIR ..."
mkdir -p "$SEED_DIR"

# Compose / seccomp content via heredoc (no read -d '')
WEB_COMPOSE=$(cat <<'YML'
version: '3.8'
services:
  web:
    image: your-org/your-web-app:latest
    user: "1000:1000"
    read_only: true
    tmpfs: ["/tmp"]
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
    {
      "names": ["read","write","close","fstat","poll","recvfrom","sendto","sendmsg","recvmsg","nanosleep","clock_gettime","gettimeofday","epoll_wait"],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
JSON
)

INT_COMPOSE=$(cat <<'YML'
version: '3.8'
services:
  vault-agent:
    image: hashicorp/vault:latest
    command: agent -config=/vault/config/agent.hcl
    volumes:
      - /home/ubuntu/vault-config:/vault/config
  internal-service:
    image: your-org/internal-service:latest
    environment:
      - VAULT_ADDR=http://127.0.0.1:8200
      - DB_DSN=postgresql://app:password@10.10.0.21:5432/appdb
    tmpfs: ["/run/secrets"]
YML
)

# Generators
make_user_data() {
  local vm="$1" ip="$2" cidr="$3" gw="$4" is_web="$5"
  local outf="${SEED_DIR}/${vm}-user-data.yaml"
  {
    echo "#cloud-config"
    echo "timezone: \"$TIMEZONE\""
    echo "ssh_authorized_keys:"
    echo "  - \"$SSH_PUBLIC_KEY\""
    echo "package_update: true"
    echo "packages: [docker.io, docker-compose-plugin, net-tools]"
    cat <<EOF
write_files:
  - path: /etc/netplan/50-cloud-init.yaml
    permissions: '0644'
    content: |
      network:
        version: 2
        ethernets:
          ${GUEST_IFACE_NAME}:
            addresses: ["${ip}/${cidr}"]
            gateway4: ${gw}
            nameservers: { addresses: [1.1.1.1,8.8.8.8] }
EOF
    if [[ "$is_web" == "yes" ]]; then
      cat <<'EOS'
  - path: /home/ubuntu/docker-compose.yml
    permissions: '0644'
    content: |
EOS
      echo "$WEB_COMPOSE" | sed 's/^/      /'
      cat <<'EOS'
  - path: /home/ubuntu/web_seccomp.json
    permissions: '0644'
    content: |
EOS
      echo "$WEB_SECCOMP" | sed 's/^/      /'
    else
      cat <<'EOS'
  - path: /home/ubuntu/docker-compose.yml
    permissions: '0644'
    content: |
EOS
      echo "$INT_COMPOSE" | sed 's/^/      /'
      cat <<'EOS'
  - path: /home/ubuntu/vault-config/agent.hcl
    permissions: '0644'
    content: |
      auto_auth {
        method "approle" {
          config = {
            role_id_file_path = "/home/ubuntu/vault-config/role_id"
            secret_id_file_path = "/home/ubuntu/vault-config/secret_id"
          }
        }
      }
      template {
        destination = "/run/secrets/app_secrets.env"
        contents = <<EOT
        # TODO: replace with your template
        EOT
      }
      listener "tcp" {
        address = "127.0.0.1:8200"
        tls_disable = 1
      }
EOS
    fi
    cat <<'EOF3'
runcmd:
  - [ bash, -lc, "netplan apply" ]
  - [ bash, -lc, "usermod -aG docker ubuntu" ]
  - [ bash, -lc, "chown -R ubuntu:ubuntu /home/ubuntu" ]
  - [ bash, -lc, "cd /home/ubuntu && docker compose up -d" ]
EOF3
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

make_user_data "$WEB_VM_NAME"      "$WEB_VM_IP"      "$WEB_VM_CIDR"      "$HOST_DMZ_GW" "yes"
make_meta_data "$WEB_VM_NAME"
make_user_data "$INTERNAL_VM_NAME" "$INTERNAL_VM_IP" "$INTERNAL_VM_CIDR" "$HOST_INT_GW" "no"
make_meta_data "$INTERNAL_VM_NAME"

cloud-localds "$WEB_SEED_ISO" "${SEED_DIR}/${WEB_VM_NAME}-user-data.yaml" "${SEED_DIR}/${WEB_VM_NAME}-meta-data.yaml" | tee -a "$LOG_FILE"
cloud-localds "$INT_SEED_ISO" "${SEED_DIR}/${INTERNAL_VM_NAME}-user-data.yaml" "${SEED_DIR}/${INTERNAL_VM_NAME}-meta-data.yaml" | tee -a "$LOG_FILE"
log "Seed ISOs ready: $WEB_SEED_ISO , $INT_SEED_ISO"

# ====== Boot VMs ======
log "[5/8] Defining/booting VMs with virt-install --import ..."
if virsh dominfo "$WEB_VM_NAME" >/dev/null 2>&1; then
  log "Cleaning existing domain: $WEB_VM_NAME"
  virsh destroy "$WEB_VM_NAME" >/dev/null 2>&1 || true
  virsh undefine "$WEB_VM_NAME" --nvram >/dev/null 2>&1 || true
fi
if virsh dominfo "$INTERNAL_VM_NAME" >/dev/null 2>&1; then
  log "Cleaning existing domain: $INTERNAL_VM_NAME"
  virsh destroy "$INTERNAL_VM_NAME" >/dev/null 2>&1 || true
  virsh undefine "$INTERNAL_VM_NAME" --nvram >/dev/null 2>&1 || true
fi

virt-install \
  --name "$WEB_VM_NAME" \
  --memory "$WEB_VM_MEM" --vcpus "$WEB_VM_CPUS" \
  --disk "path=${WEB_DISK},format=qcow2" \
  --disk "path=${WEB_SEED_ISO},device=cdrom" \
  --network "bridge=${BR_EXTERNAL},model=virtio" \
  --import \
  --os-variant ubuntu22.04 \
  --noautoconsole | tee -a "$LOG_FILE"

virt-install \
  --name "$INTERNAL_VM_NAME" \
  --memory "$INTERNAL_VM_MEM" --vcpus "$INTERNAL_VM_CPUS" \
  --disk "path=${INT_DISK},format=qcow2" \
  --disk "path=${INT_SEED_ISO},device=cdrom" \
  --network "bridge=${BR_INTERNAL},model=virtio" \
  --import \
  --os-variant ubuntu22.04 \
  --noautoconsole | tee -a "$LOG_FILE"

log "[6/8] VMs launched. (cloud-init will configure them on first boot)"

# ====== Optional: wait for SSH ======
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

if [[ "$WAIT_SSH" = "1" ]]; then
  log "[7/8] Waiting for SSH to become available on both VMs..."
  wait_ssh "$WEB_VM_IP" "$SSH_TIMEOUT_SEC" || true
  wait_ssh "$INTERNAL_VM_IP" "$SSH_TIMEOUT_SEC" || true
else
  log "[7/8] Skipping SSH wait (WAIT_SSH=0)."
fi

log "[8/8] Done."
log "Next steps:"
log " - SSH into web-vm:      ssh ubuntu@${WEB_VM_IP}"
log " - SSH into internal-vm: ssh ubuntu@${INTERNAL_VM_IP}"
log "Quick checks:"
log " - On web-vm:     docker ps; curl -vk https://${INTERNAL_VM_IP}:${INTERNAL_API_PORT}"
log " - On web-vm:     curl -vk https://8.8.8.8   # should be BLOCKED by host nft"
log " - On internal-vm:docker ps"
log "Full log written to: $LOG_FILE"
