#!/usr/bin/env bash
set -euo pipefail

# ====== Edit these variables before running ======
BR_EXTERNAL="br-external"
BR_INTERNAL="br-internal"

# IPs (without CIDR for leaves)
WEB_VM_ADDR="192.0.2.101"
WEB_VM_CIDR="192.0.2.101/24"

INTERNAL_GW_ADDR="10.10.0.1"
INTERNAL_VM_ADDR="10.10.0.11"

# Bank or allowed external endpoint IP (example)
BANK_API_IP="203.0.113.55"

# External interface name on host (for masquerade)
EXT_IF="eth0"
# ===============================================

echo "Creating bridges if they do not exist..."
ip link show "$BR_EXTERNAL" >/dev/null 2>&1 || ip link add name "$BR_EXTERNAL" type bridge
ip addr add "$WEB_VM_CIDR" dev "$BR_EXTERNAL" 2>/dev/null || true
ip link set "$BR_EXTERNAL" up

ip link show "$BR_INTERNAL" >/dev/null 2>&1 || ip link add name "$BR_INTERNAL" type bridge
ip addr add "$INTERNAL_GW_ADDR/24" dev "$BR_INTERNAL" 2>/dev/null || true
ip link set "$BR_INTERNAL" up

echo "Bridges ready: $BR_EXTERNAL and $BR_INTERNAL"

# Prepare nftables config directory
mkdir -p /etc/nftables.d

NFT_FILE="/etc/nftables.d/dmz.nft"

cat > "$NFT_FILE" <<EOF
table inet dmz_fw {
  chain forward {
    type filter hook forward priority 0; policy drop;
    # Allow established connections
    ct state established,related accept

    # Allow DMZ (web VM) -> Internal VM only on API port 8443
    ip saddr ${WEB_VM_ADDR} ip daddr ${INTERNAL_VM_ADDR} tcp dport 8443 accept

    # Allow DMZ -> Bank API only (HTTPS)
    ip saddr ${WEB_VM_ADDR} ip daddr ${BANK_API_IP} tcp dport 443 accept

    # Masquerade outbound traffic via external interface
    oifname "${EXT_IF}" ip saddr ${WEB_VM_ADDR} masquerade
  }
}
EOF

echo "nftables config written to $NFT_FILE"

# Load the nft rules
if command -v nft >/dev/null 2>&1; then
  nft -f "$NFT_FILE"
  echo "nftables rules loaded."
else
  echo "nft command not found. Install nftables and run: nft -f $NFT_FILE"
fi

echo "Host network setup complete."
