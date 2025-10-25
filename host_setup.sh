#!/usr/bin/env bash
set -euo pipefail

# (silent) load environment overrides if .env exists
if [ -f ".env" ]; then
  set -a; . ./.env; set +a
fi

# -----------------------------------------------
# DMZ Host Setup Script (hardened, commented)
# -----------------------------------------------
# Goal:
#   Build a host-side network boundary so that a compromised DMZ web VM
#   cannot laterally move into the internal network or exfiltrate data.
#   We enforce this by:
#     - Creating two L2 domains (bridges) to separate DMZ and Internal.
#     - Making the host bridges the default gateways for VMs.
#     - Enabling IP forwarding strictly for routed paths we control.
#     - Applying nftables with:
#         * Default DROP in the forward path (deny-by-default).
#         * A minimal allowlist from DMZ→Internal (single API port).
#         * A minimal allowlist from DMZ→Specific External (e.g., Bank API).
#         * NAT (masquerade) ONLY in postrouting (correct/least surprise).
#
# Threats addressed:
#   - RCE/webshell on the DMZ web VM:
#       * Can’t scan/enter Internal except the one API port.
#       * Can’t phone home to arbitrary hosts; egress is pinned to a known IP.
#       * Can’t bypass by raw routing tricks; host is the gateway & filters.
#   - Misconfiguration drift:
#       * Idempotent steps; clear separation between FILTER and NAT tables.
#       * Comments explain *why* each rule exists for auditability.
# -----------------------------------------------

# ======= VARIABLE DEFINITIONS (override via env if needed) =======
# Bridge names:
BR_EXTERNAL="${BR_EXTERNAL:-br-external}"   # DMZ L2 segment (Internet-facing VMs attach here)
BR_INTERNAL="${BR_INTERNAL:-br-internal}"   # Internal L2 segment (sensitive services attach here)

# Host-side gateway IPs (assigned to the bridges themselves):
# - These are NOT VM IPs. The VMs will point their default route to these addresses.
# - Rationale: Having the host as the L3 gateway allows host-level policy enforcement.
HOST_DMZ_IP_CIDR="${HOST_DMZ_IP_CIDR:-192.0.2.1/24}"   # Gateway for DMZ subnet (e.g., 192.0.2.0/24)
HOST_INT_IP_CIDR="${HOST_INT_IP_CIDR:-10.10.0.1/24}"   # Gateway for Internal subnet (e.g., 10.10.0.0/24)

# Explicit VM addresses referenced by firewall policy (source/destination matches):
# - Tie rules to concrete IPs to avoid overly broad allowances.
WEB_VM_IP="${WEB_VM_IP:-192.0.2.101}"       # DMZ web VM static IP
INTERNAL_VM_IP="${INTERNAL_VM_IP:-10.10.0.11}" # Internal service VM static IP

# Only this application port is reachable from DMZ→Internal:
# - Principle of least privilege: Permit just the one API hop the web tier needs.
INTERNAL_API_PORT="${INTERNAL_API_PORT:-8443}"

# Egress allowlist (single, known external dependency):
# - Pin outbound from DMZ to an expected endpoint (e.g., Bank API) to kill C2/exfil.
BANK_API_IP="${BANK_API_IP:-203.0.113.55}"

# Physical uplink device for NAT:
# - Masquerade only when packets actually leave via this NIC.
EXT_IF="${EXT_IF:-eth0}"

# Where rules are written (kept separate for auditing/change control):
NFT_DIR="${NFT_DIR:-/etc/nftables.d}"
NFT_FILTER_FILE="${NFT_FILTER_FILE:-${NFT_DIR}/dmz-filter.nft}"
NFT_NAT_FILE="${NFT_NAT_FILE:-${NFT_DIR}/dmz-nat.nft}"
# ================================================================

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

echo "[1/6] Preflight checks..."
require_cmd ip        # network config
require_cmd nft       # nftables CLI
require_cmd sysctl    # kernel toggles
require_cmd modprobe  # kernel modules loader
require_cmd tee       # safe file writes
sudo -n true >/dev/null 2>&1 || echo "Note: running without passwordless sudo; you may be prompted."

echo "[2/6] Enable IPv4 forwarding and NAT kernel modules..."
# Why: Without ip_forward=1, the host won’t route between DMZ and Internal or to the uplink.
#      We need routing so the host can apply policy and (optionally) NAT for DMZ egress.
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# Persist the forwarding toggle across reboots (so a restart doesn’t silently break egress).
echo 'net.ipv4.ip_forward=1' | tee /etc/sysctl.d/99-ipforward.conf >/dev/null
sysctl --system >/dev/null
# NAT module enables the 'type nat' hooks and MASQUERADE target in nftables.
# If the module is built-in, this is a no-op; otherwise it loads support.
modprobe nft_nat || true

echo "[3/6] Create and configure bridges (${BR_EXTERNAL}, ${BR_INTERNAL})..."
# Why bridges: Create two separate L2 broadcast domains to enforce a physical-style boundary.
# DMZ VMs attach to br-external; Internal VMs attach to br-internal. The host sits in the middle.
ip link show "${BR_EXTERNAL}" >/dev/null 2>&1 || ip link add name "${BR_EXTERNAL}" type bridge
ip link show "${BR_INTERNAL}" >/dev/null 2>&1 || ip link add name "${BR_INTERNAL}" type bridge

# Assign host-side IPs to serve as default gateways for their respective subnets.
# Idempotency: flush old addresses to avoid overlapping/duplicate assignments.
ip addr flush dev "${BR_EXTERNAL}" >/dev/null 2>&1 || true
ip addr add "${HOST_DMZ_IP_CIDR}" dev "${BR_EXTERNAL}"
ip link set "${BR_EXTERNAL}" up

ip addr flush dev "${BR_INTERNAL}" >/dev/null 2>&1 || true
ip addr add "${HOST_INT_IP_CIDR}" dev "${BR_INTERNAL}"
ip link set "${BR_INTERNAL}" up

echo "[4/6] Write nftables FILTER rules (deny-by-default with minimal allowlist)..."
# FILTER table enforces security policy for transit traffic (forwarding path).
# We choose a default DROP policy and explicitly poke small “holes” where needed.
mkdir -p "${NFT_DIR}"
cat > "${NFT_FILTER_FILE}" <<EOF
# ---------------------------------------------------------
# dmz-filter.nft  —  Forward-path security policy
# ---------------------------------------------------------
# Model:
#   * Deny-by-default on forward (policy drop).
#   * Allow return traffic (established/related).
#   * Allow DMZ Web VM -> Internal Service ONLY on ${INTERNAL_API_PORT}/tcp.
#   * Allow DMZ Web VM -> ${BANK_API_IP}:443 ONLY (strict egress).
#
# Why:
#   * Prevent lateral movement from DMZ to Internal except the single API hop.
#   * Prevent arbitrary exfiltration/C2 by pinning egress to a vetted endpoint.
#   * Keep the rule specificity high (match by source/dest IP + port).
# ---------------------------------------------------------
table inet dmz_fw {
  chain forward {
    type filter hook forward priority 0; policy drop;

    # Keep stateful flows working: responses to permitted connections are allowed back.
    ct state established,related accept

    # DMZ → Internal (single API port; least privilege)
    ip saddr ${WEB_VM_IP} ip daddr ${INTERNAL_VM_IP} tcp dport ${INTERNAL_API_PORT} accept

    # DMZ → Whitelisted External (e.g., Bank API over HTTPS)
    ip saddr ${WEB_VM_IP} ip daddr ${BANK_API_IP} tcp dport 443 accept
  }
}
EOF

echo "[5/6] Write nftables NAT rules (postrouting masquerade only)..."
# NAT is for address translation when packets EXIT the host to the uplink.
# It MUST live in a NAT table’s postrouting hook (priority srcnat).
# Putting MASQUERADE in filter/forward is invalid and will error out.
cat > "${NFT_NAT_FILE}" <<EOF
# ---------------------------------------------------------
# dmz-nat.nft  —  Egress NAT
# ---------------------------------------------------------
# Model:
#   * Perform source NAT (masquerade) when DMZ Web VM traffic leaves via ${EXT_IF}.
#   * Do NOT perform NAT on internal east-west traffic (keep it routable & inspectable).
#
# Why:
#   * Hides the DMZ VM’s RFC1918 address on the uplink while preserving policy control.
#   * Restricts NAT to the real egress path (oifname "${EXT_IF}") to avoid surprises.
# ---------------------------------------------------------
table ip dmz_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;

    # NAT only when the packet's source is the DMZ Web VM and it is leaving via ${EXT_IF}.
    ip saddr ${WEB_VM_IP} oifname "${EXT_IF}" masquerade
  }
}
EOF

echo "[6/6] Apply nftables rules..."
# Cleanly (re)apply: remove old tables we manage, then load fresh files.
# This avoids stale rules lingering after edits.
nft list table inet dmz_fw >/dev/null 2>&1 && nft delete table inet dmz_fw || true
nft list table ip dmz_nat   >/dev/null 2>&1 && nft delete table ip dmz_nat   || true

# Load FILTER first (so deny-by-default is in place),
# then NAT (so egress translation is ready when allowed flows occur).
nft -f "${NFT_FILTER_FILE}"
nft -f "${NFT_NAT_FILE}"

echo "-----------------------------------------------------"
echo "DMZ host setup complete."
echo
echo "Next steps (verify and operate):"
echo " 1) Attach VM NICs to bridges:"
echo "      - Web VM NIC  -> ${BR_EXTERNAL}  (DMZ segment)"
echo "      - Internal VM -> ${BR_INTERNAL}  (Internal segment)"
echo " 2) Inside VMs, set static IPs and default gateways:"
echo "      - Web VM IP: ${WEB_VM_IP}      GW: ${HOST_DMZ_IP_CIDR%/*}"
echo "      - Internal VM IP: ${INTERNAL_VM_IP}  GW: ${HOST_INT_IP_CIDR%/*}"
echo " 3) Test policy from Web VM (expected behavior):"
echo "      - curl https://${INTERNAL_VM_IP}:${INTERNAL_API_PORT}    # ALLOWED (app path)"
echo "      - curl https://${BANK_API_IP}:443                         # ALLOWED (pinned egress)"
echo "      - curl https://8.8.8.8                                    # BLOCKED (default DROP)"
echo "-----------------------------------------------------"
