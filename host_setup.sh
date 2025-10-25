#!/usr/bin/env bash
set -euo pipefail

# Load .env if present (export all vars)
if [ -f ".env" ]; then
  set -a; . ./.env; set +a
fi

# -----------------------------------------------
# DMZ Host Setup Script
# -----------------------------------------------
# This script prepares a host to run a DMZ-style network layout
# for a hardened web front and an isolated internal service.
# It:
#  1) Enables IPv4 forwarding and NAT modules (needed for routed/NATed egress)
#  2) Creates two Linux bridges: br-external (DMZ) and br-internal (Internal)
#  3) Assigns host-side bridge IPs (act as default gateways for VMs)
#  4) Installs nftables rules:
#     - FILTER table: whitelist DMZ -> Internal/API and DMZ -> Bank-only egress
#     - NAT table: perform source NAT (masquerade) *only* in postrouting
#
# Why these steps?
#  - Separation of concerns: DMZ (internet-facing) is isolated from Internal.
#  - Least privilege networking: DMZ can only reach what it must (internal API & bank).
#  - Correct NAT placement: masquerade belongs in postrouting, not filter/forward.
# -----------------------------------------------

# ======= EDIT THESE VARIABLES FOR YOUR ENV =======
# Bridges
BR_EXTERNAL="br-external"     # DMZ-facing bridge
BR_INTERNAL="br-internal"     # Internal-only bridge

# Host-side bridge IPs (gateways for VMs)
HOST_DMZ_IP_CIDR="192.0.2.1/24"    # host IP on br-external (gateway for DMZ VMs)
HOST_INT_IP_CIDR="10.10.0.1/24"    # host IP on br-internal (gateway for Internal VMs)

# VM addresses (used by firewall policies)
WEB_VM_IP="192.0.2.101"       # DMZ web VM address
INTERNAL_VM_IP="10.10.0.11"   # Internal service VM address

# Internal API port (only this port is allowed DMZ -> Internal)
INTERNAL_API_PORT="8443"

# External allowed egress (bank API) - use a fixed IP or a controlled egress proxy
BANK_API_IP="203.0.113.55"

# Outbound physical NIC on the host (used by NAT)
EXT_IF="eth0"

# nftables files to write
NFT_DIR="/etc/nftables.d"
NFT_FILTER_FILE="${NFT_DIR}/dmz-filter.nft"
NFT_NAT_FILE="${NFT_DIR}/dmz-nat.nft"
# =================================================

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

echo "[1/6] Preflight checks..."
require_cmd ip
require_cmd nft
require_cmd sysctl
require_cmd modprobe
require_cmd tee
sudo -n true >/dev/null 2>&1 || echo "Note: running without passwordless sudo; you may be prompted."

echo "[2/6] Enable IPv4 forwarding and NAT kernel modules..."
# Why: DMZ VMs should be able to route/egress. Without ip_forward, packets won't be forwarded.
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# Persist across reboots
echo 'net.ipv4.ip_forward=1' | tee /etc/sysctl.d/99-ipforward.conf >/dev/null
sysctl --system >/dev/null
# NAT module (nftables NAT support). Without this, masquerade won't be available.
modprobe nft_nat || true

echo "[3/6] Create and configure bridges (${BR_EXTERNAL}, ${BR_INTERNAL})..."
# Why: Two L2 broadcast domains to physically separate DMZ and Internal networks on one host.
ip link show "${BR_EXTERNAL}" >/dev/null 2>&1 || ip link add name "${BR_EXTERNAL}" type bridge
ip link show "${BR_INTERNAL}" >/dev/null 2>&1 || ip link add name "${BR_INTERNAL}" type bridge

# Assign host-side gateway IPs to bridges (so VMs can use the host as default gateway)
# Why: Host bridges need addresses to route/NAT traffic for VMs.
# Clean previous addresses (idempotency) then add desired ones.
ip addr flush dev "${BR_EXTERNAL}" >/dev/null 2>&1 || true
ip addr add "${HOST_DMZ_IP_CIDR}" dev "${BR_EXTERNAL}"
ip link set "${BR_EXTERNAL}" up

ip addr flush dev "${BR_INTERNAL}" >/dev/null 2>&1 || true
ip addr add "${HOST_INT_IP_CIDR}" dev "${BR_INTERNAL}"
ip link set "${BR_INTERNAL}" up

echo "[4/6] Write nftables FILTER rules (whitelisting DMZ egress & DMZ->Internal API)..."
mkdir -p "${NFT_DIR}"
cat > "${NFT_FILTER_FILE}" <<EOF
# ---------------------------------------------------------
# dmz-filter.nft
# FILTER rules for DMZ design
# Why:
#  - Default DROP on forward: nothing passes unless explicitly allowed
#  - Allow only:
#     * DMZ Web VM -> Internal VM on a single API port (least privilege)
#     * DMZ Web VM -> Bank API over HTTPS (strict egress control)
# ---------------------------------------------------------
table inet dmz_fw {
  chain forward {
    type filter hook forward priority 0; policy drop;

    # Allow established/related to keep return traffic working.
    ct state established,related accept

    # DMZ Web VM -> Internal Service (API port only)
    ip saddr ${WEB_VM_IP} ip daddr ${INTERNAL_VM_IP} tcp dport ${INTERNAL_API_PORT} accept

    # DMZ Web VM -> Bank API (HTTPS only)
    ip saddr ${WEB_VM_IP} ip daddr ${BANK_API_IP} tcp dport 443 accept
  }
}
EOF

echo "[5/6] Write nftables NAT rules (postrouting masquerade only)..."
cat > "${NFT_NAT_FILE}" <<EOF
# ---------------------------------------------------------
# dmz-nat.nft
# NAT rules for DMZ design
# Why:
#  - NAT must happen in postrouting (srcnat) NOT in filter/forward chains.
#  - Masquerade only DMZ Web VM's traffic leaving via the external NIC.
# ---------------------------------------------------------
table ip dmz_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;

    # Masquerade DMZ Web VM egress out of host's external interface
    ip saddr ${WEB_VM_IP} oifname "${EXT_IF}" masquerade
  }
}
EOF

echo "[6/6] Apply nftables rules..."
# Safer: delete our tables if present, then re-create just our content
nft list table inet dmz_fw >/dev/null 2>&1 && nft delete table inet dmz_fw || true
nft list table ip dmz_nat   >/dev/null 2>&1 && nft delete table ip dmz_nat   || true

nft -f "${NFT_FILTER_FILE}"
nft -f "${NFT_NAT_FILE}"

echo "-----------------------------------------------------"
echo "DMZ host setup complete."
echo ""
echo "Next steps:"
echo " 1) Attach your VMs to bridges:"
echo "      - Web VM NIC -> ${BR_EXTERNAL} (DMZ)"
echo "      - Internal VM NIC -> ${BR_INTERNAL} (Internal)"
echo " 2) Inside VMs, set IPs and default gateways:"
echo "      - Web VM IP: ${WEB_VM_IP}   GW: ${HOST_DMZ_IP_CIDR%/*}"
echo "      - Internal VM IP: ${INTERNAL_VM_IP}   GW: ${HOST_INT_IP_CIDR%/*}"
echo " 3) Verify routing from Web VM:"
echo "      - Can reach ${INTERNAL_VM_IP}:${INTERNAL_API_PORT} (allowed)"
echo "      - Can reach ${BANK_API_IP}:443 (allowed)"
echo "      - Other destinations/ports are blocked (as designed)"
echo "-----------------------------------------------------"
