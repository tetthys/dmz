#!/usr/bin/env bash
set -Eeuo pipefail

# Load .env if present
if [ -f ".env" ]; then
  set -a; . ./.env; set +a
fi

# =========================
# Config with sane defaults
# =========================
WEB_VM_NAME="${WEB_VM_NAME:-web-vm}"
INTERNAL_VM_NAME="${INTERNAL_VM_NAME:-internal-vm}"

IMG_DIR="${IMG_DIR:-/var/lib/libvirt/images}"
SEED_DIR="${SEED_DIR:-/var/lib/libvirt/cloud-seed}"

WEB_DISK="${WEB_DISK:-${IMG_DIR}/${WEB_VM_NAME}.qcow2}"
INT_DISK="${INT_DISK:-${IMG_DIR}/${INTERNAL_VM_NAME}.qcow2}"

WEB_SEED_ISO="${WEB_SEED_ISO:-${SEED_DIR}/${WEB_VM_NAME}-seed.iso}"
INT_SEED_ISO="${INT_SEED_ISO:-${SEED_DIR}/${INTERNAL_VM_NAME}-seed.iso}"

BR_EXTERNAL="${BR_EXTERNAL:-br-external}"
BR_INTERNAL="${BR_INTERNAL:-br-internal}"

# Options
RESET_NFT=0
REMOVE_BRIDGES=0
FORCE=0
DRYRUN=0

usage() {
  cat <<USAGE
factory-reset.sh — cleanly remove DMZ VMs and local artifacts

Usage:
  sudo bash factory-reset.sh [options]

Options:
  --reset-nft       Remove nftables tables we created (dmz_fw, dmz_nat) only
  --remove-bridges  Delete host bridges (${BR_EXTERNAL}, ${BR_INTERNAL}) [NOT recommended]
  --force           Do not ask for confirmation
  --dry-run         Show what would be deleted/stopped, but do nothing
  -h, --help        Show this help

This will:
  - virsh destroy/undefine: ${WEB_VM_NAME}, ${INTERNAL_VM_NAME}
  - remove disks: ${WEB_DISK}, ${INT_DISK}
  - remove seeds: ${WEB_SEED_ISO}, ${INT_SEED_ISO}
USAGE
}

for a in "$@"; do
  case "$a" in
    --reset-nft) RESET_NFT=1 ;;
    --remove-bridges) REMOVE_BRIDGES=1 ;;
    --force) FORCE=1 ;;
    --dry-run) DRYRUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $a"; usage; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
need virsh
need nft
need ip
need rm
need tee

confirm() {
  [[ "$FORCE" -eq 1 ]] && return 0
  read -r -p "Proceed with factory reset? This will DELETE VM disks/seeds. (yes/NO): " ans
  [[ "${ans:-}" == "yes" ]]
}

say() { echo "[*] $*"; }
act() {
  if [[ "$DRYRUN" -eq 1 ]]; then
    echo "DRY-RUN: $*"
  else
    eval "$@"
  fi
}

echo "=== FACTORY RESET PLAN ==="
echo "VMs:            ${WEB_VM_NAME}, ${INTERNAL_VM_NAME}"
echo "Disks:          ${WEB_DISK}, ${INT_DISK}"
echo "Seed ISOs:      ${WEB_SEED_ISO}, ${INT_SEED_ISO}"
echo "Reset nft:      $([[ $RESET_NFT -eq 1 ]] && echo YES || echo NO)"
echo "Remove bridges: $([[ $REMOVE_BRIDGES -eq 1 ]] && echo YES || echo NO)"
echo "Dry-run:        $([[ $DRYRUN -eq 1 ]] && echo YES || echo NO)"
echo

confirm || { echo "Aborted."; exit 1; }

# 1) Stop and undefine domains (idempotent)
for VM in "$WEB_VM_NAME" "$INTERNAL_VM_NAME"; do
  if virsh dominfo "$VM" >/dev/null 2>&1; then
    say "Destroying domain: $VM"
    act "virsh destroy '$VM' >/dev/null 2>&1 || true"
    say "Undefining domain: $VM"
    act "virsh undefine '$VM' --nvram >/dev/null 2>&1 || virsh undefine '$VM' >/dev/null 2>&1 || true"
  else
    say "Domain not found (ok): $VM"
  fi
done

# 2) Remove disks (careful not to remove the base cloud image)
for f in "$WEB_DISK" "$INT_DISK"; do
  if [[ -f "$f" ]]; then
    say "Deleting disk: $f"
    act "rm -f -- '$f'"
  else
    say "Disk not found (ok): $f"
  fi
done

# 3) Remove seed ISOs
for f in "$WEB_SEED_ISO" "$INT_SEED_ISO"; do
  if [[ -f "$f" ]]; then
    say "Deleting seed ISO: $f"
    act "rm -f -- '$f'"
  else
    say "Seed ISO not found (ok): $f"
  fi
done

# 4) Optional: nft cleanup (only our tables)
if [[ "$RESET_NFT" -eq 1 ]]; then
  say "Removing nftables policy tables (dmz_fw, dmz_nat)..."
  act "nft list table inet dmz_fw >/dev/null 2>&1 && nft delete table inet dmz_fw || true"
  act "nft list table ip dmz_nat   >/dev/null 2>&1 && nft delete table ip dmz_nat   || true"
fi

# 5) Optional: remove bridges (NOT recommended)
if [[ "$REMOVE_BRIDGES" -eq 1 ]]; then
  say "Removing bridges ${BR_EXTERNAL}, ${BR_INTERNAL} (NOT recommended)..."
  for br in "$BR_EXTERNAL" "$BR_INTERNAL"; do
    if ip link show "$br" >/dev/null 2>&1; then
      act "ip link set '$br' down"
      act "ip link del '$br' type bridge"
      say "Removed: $br"
    else
      say "Bridge not found (ok): $br"
    fi
  done
fi

echo "=== FACTORY RESET COMPLETE ==="
echo "Tip: re-run provision after fixing GUEST_IFACE_NAME or other .env values."
