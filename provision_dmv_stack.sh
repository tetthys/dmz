#!/usr/bin/env bash
set -euo pipefail

# ===========================================================
# DMZ Stack Provisioner (VMs + Docker Compose via cloud-init)
# -----------------------------------------------------------
# What this script does:
#  - Downloads an Ubuntu cloud image (if missing)
#  - Generates cloud-init seed ISOs for two VMs:
#      * web-vm (DMZ): attaches to br-external
#      * internal-vm (Internal): attaches to br-internal
#  - Each VM is provisioned to:
#      * set static networking (IP/GW)
#      * install docker + docker compose
#      * write docker-compose files (web/internal variants)
#      * bring services up: `docker compose up -d`
#  - Boots VMs with virt-install --import
#
# Why cloud-init?
#  - Unattended, idempotent, reproducible provisioning
#  - Zero manual SSH/typing inside the VMs
# ===========================================================

# ------------------------
# EDIT THESE VARIABLES
# ------------------------

# Bridges (must already exist from host_setup.sh)
BR_EXTERNAL="br-external"
BR_INTERNAL="br-internal"

# Host gateway IPs on bridges (from host_setup.sh)
HOST_DMZ_GW="192.0.2.1"
HOST_INT_GW="10.10.0.1"

# VM IPs (must match nftables allow rules you set earlier)
WEB_VM_IP="192.0.2.101"
WEB_VM_CIDR="24"
INTERNAL_VM_IP="10.10.0.11"
INTERNAL_VM_CIDR="24"

# VM names and resources
WEB_VM_NAME="web-vm"
INTERNAL_VM_NAME="internal-vm"
WEB_VM_DISK="/var/lib/libvirt/images/${WEB_VM_NAME}.qcow2"
INTERNAL_VM_DISK="/var/lib/libvirt/images/${INTERNAL_VM_NAME}.qcow2"
WEB_VM_MEM="4096"
WEB_VM_CPUS="2"
INTERNAL_VM_MEM="4096"
INTERNAL_VM_CPUS="2"

# Cloud image (Ubuntu 22.04 Jammy)
CLOUD_IMG_DIR="/var/lib/libvirt/images"
CLOUD_IMG_BASE="${CLOUD_IMG_DIR}/ubuntu-22.04-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

# cloud-init seed iso paths
SEED_DIR="/var/lib/libvirt/cloud-seed"
WEB_SEED_ISO="${SEED_DIR}/${WEB_VM_NAME}-seed.iso"
INT_SEED_ISO="${SEED_DIR}/${INTERNAL_VM_NAME}-seed.iso"

# SSH public key to inject into both VMs (REQUIRED)
# Paste your ~/.ssh/id_rsa.pub or ~/.ssh/id_ed25519.pub content below.
SSH_PUBLIC_KEY="REPLACE_WITH_YOUR_SSH_PUBLIC_KEY"

# Timezone
TIMEZONE="Asia/Seoul"

# Internal API port (DMZ -> Internal)
INTERNAL_API_PORT="8443"

# ------------------------
# PRE-FLIGHT CHECKS
# ------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

echo "[1/8] Preflight checks..."
need wget
need qemu-img
need virt-install
need cloud-localds || true
need genisoimage || true
need xorriso || true

# Try to install cloud-init tools if missing
if ! command -v cloud-localds >/dev/null 2>&1; then
  echo "[INFO] cloud-localds not found. Installing cloud-image-utils..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y cloud-image-utils
fi
if ! command -v cloud-localds >/dev/null 2>&1; then
  echo "[ERROR] cloud-localds still not found. Install cloud-image-utils manually."
  exit 1
fi

# ------------------------
# VALIDATE SSH KEY
# ------------------------
if [[ "$SSH_PUBLIC_KEY" == "REPLACE_WITH_YOUR_SSH_PUBLIC_KEY" ]]; then
  echo "[ERROR] Please set SSH_PUBLIC_KEY in this script."
  exit 1
fi

# ------------------------
# DOWNLOAD CLOUD IMAGE
# ------------------------
echo "[2/8] Ensuring base cloud image exists..."
mkdir -p "$CLOUD_IMG_DIR"
if [[ ! -f "$CLOUD_IMG_BASE" ]]; then
  echo "[INFO] Downloading Ubuntu cloud image..."
  wget -O "$CLOUD_IMG_BASE" "$CLOUD_IMG_URL"
else
  echo "[OK] Cloud image found: $CLOUD_IMG_BASE"
fi

# ------------------------
# PREPARE VM DISKS (copy-on-write or full copy)
# ------------------------
echo "[3/8] Preparing VM disks..."
# Create QCOW2 clones
if [[ ! -f "$WEB_VM_DISK" ]]; then
  qemu-img create -f qcow2 -b "$CLOUD_IMG_BASE" "$WEB_VM_DISK"
fi
if [[ ! -f "$INTERNAL_VM_DISK" ]]; then
  qemu-img create -f qcow2 -b "$CLOUD_IMG_BASE" "$INTERNAL_VM_DISK"
fi

# ------------------------
# GENERATE CLOUD-INIT SEEDS
# ------------------------
echo "[4/8] Generating cloud-init seed ISOs..."
mkdir -p "$SEED_DIR"

# Helper: write a cloud-config with static netplan + docker + compose + files + up
gen_user_data() {
  local vm="$1"
  local ip="$2"
  local cidr="$3"
  local gw="$4"
  local is_web="$5"   # "yes" for web-vm, else "no"

  local outfile="${SEED_DIR}/${vm}-user-data.yaml"

  # Compose content (inline) — web variant
  read -r -d '' WEB_COMPOSE <<'YML'
version: '3.8'
services:
  web:
    image: your-org/your-web-app:latest
    user: "1000:1000"
    read_only: true
    tmpfs:
      - /tmp
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
      - seccomp:/home/ubuntu/web_seccomp.json
    environment:
      - INTERNAL_API_URL=https://10.10.0.11:8443
    ports:
      - "443:443"
YML

  # Seccomp file
  read -r -d '' WEB_SECCOMP <<'JSON'
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

  # Internal compose
  read -r -d '' INT_COMPOSE <<'YML'
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
    tmpfs:
      - /run/secrets
YML

  cat > "$outfile" <<EOF
#cloud-config
timezone: "$TIMEZONE"
ssh_authorized_keys:
  - "$SSH_PUBLIC_KEY"

package_update: true
packages:
  - docker.io
  - docker-compose-plugin
  - net-tools

write_files:
  - path: /etc/netplan/50-cloud-init.yaml
    permissions: '0644'
    content: |
      network:
        version: 2
        ethernets:
          ens3:
            addresses: ["${ip}/${cidr}"]
            gateway4: ${gw}
            nameservers:
              addresses: [1.1.1.1,8.8.8.8]

  - path: /home/ubuntu/readme.txt
    permissions: '0644'
    content: |
      This VM was provisioned by cloud-init.
      Docker + Docker Compose installed. Services will be started automatically.

$( if [[ "$is_web" == "yes" ]]; then
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
EOS
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
        # Example secret template (replace with real templating)
        EOT
      }
      listener "tcp" {
        address = "127.0.0.1:8200"
        tls_disable = 1
      }
EOS
fi
)

runcmd:
  - [ bash, -lc, "netplan apply" ]
  - [ bash, -lc, "usermod -aG docker ubuntu" ]
  - [ bash, -lc, "chown -R ubuntu:ubuntu /home/ubuntu" ]
  - [ bash, -lc, "cd /home/ubuntu && docker compose up -d" ]
EOF
}

# meta-data is minimal (hostname)
gen_meta_data() {
  local vm="$1"
  local outfile="${SEED_DIR}/${vm}-meta-data.yaml"
  cat > "$outfile" <<EOF
instance-id: ${vm}
local-hostname: ${vm}
EOF
}

# Generate user-data/meta-data for web and internal
gen_user_data "$WEB_VM_NAME"      "$WEB_VM_IP"      "$WEB_VM_CIDR"      "$HOST_DMZ_GW" "yes"
gen_meta_data "$WEB_VM_NAME"

gen_user_data "$INTERNAL_VM_NAME" "$INTERNAL_VM_IP" "$INTERNAL_VM_CIDR" "$HOST_INT_GW" "no"
gen_meta_data "$INTERNAL_VM_NAME"

# Build seed ISOs
cloud-localds "$WEB_SEED_ISO" "${SEED_DIR}/${WEB_VM_NAME}-user-data.yaml" "${SEED_DIR}/${WEB_VM_NAME}-meta-data.yaml"
cloud-localds "$INT_SEED_ISO" "${SEED_DIR}/${INTERNAL_VM_NAME}-user-data.yaml" "${SEED_DIR}/${INTERNAL_VM_NAME}-meta-data.yaml"

echo "[5/8] Seed ISOs created:"
echo " - $WEB_SEED_ISO"
echo " - $INT_SEED_ISO"

# ------------------------
# BOOT VMs
# ------------------------
echo "[6/8] Booting VMs with virt-install --import..."

# Destroy/redefine if already exists (idempotency)
if virsh dominfo "$WEB_VM_NAME" >/dev/null 2>&1; then
  echo "[INFO] $WEB_VM_NAME exists; destroying and undefining for clean run..."
  virsh destroy "$WEB_VM_NAME" >/dev/null 2>&1 || true
  virsh undefine "$WEB_VM_NAME" --nvram >/dev/null 2>&1 || true
fi

if virsh dominfo "$INTERNAL_VM_NAME" >/dev.null 2>&1; then
  echo "[INFO] $INTERNAL_VM_NAME exists; destroying and undefining for clean run..."
  virsh destroy "$INTERNAL_VM_NAME" >/dev/null 2>&1 || true
  virsh undefine "$INTERNAL_VM_NAME" --nvram >/dev/null 2>&1 || true
fi

# web-vm
virt-install \
  --name "$WEB_VM_NAME" \
  --memory "$WEB_VM_MEM" --vcpus "$WEB_VM_CPUS" \
  --disk "path=${WEB_VM_DISK},format=qcow2" \
  --disk "path=${WEB_SEED_ISO},device=cdrom" \
  --network "bridge=${BR_EXTERNAL},model=virtio" \
  --import \
  --os-variant ubuntu22.04 \
  --noautoconsole

# internal-vm
virt-install \
  --name "$INTERNAL_VM_NAME" \
  --memory "$INTERNAL_VM_MEM" --vcpus "$INTERNAL_VM_CPUS" \
  --disk "path=${INTERNAL_VM_DISK},format=qcow2" \
  --disk "path=${INT_SEED_ISO},device=cdrom" \
  --network "bridge=${BR_INTERNAL},model=virtio" \
  --import \
  --os-variant ubuntu22.04 \
  --noautoconsole

echo "[7/8] Waiting a bit for cloud-init to finish inside VMs..."
sleep 20
echo "[INFO] You can watch cloud-init logs with:"
echo "  virsh console ${WEB_VM_NAME}    (Ctrl-] to exit)"
echo "  virsh console ${INTERNAL_VM_NAME}"

echo "[8/8] Done. Next steps:"
echo " - SSH into web-vm:     ssh ubuntu@${WEB_VM_IP}"
echo " - SSH into internal-vm:ssh ubuntu@${INTERNAL_VM_IP}"
echo "Check services:"
echo " - On web-vm:     docker ps ; curl -vk https://${INTERNAL_VM_IP}:${INTERNAL_API_PORT}"
echo " - On internal-vm:docker ps"
echo "Egress policy:"
echo " - From web-vm: curl -vk https://8.8.8.8    # should be BLOCKED by host nft"
