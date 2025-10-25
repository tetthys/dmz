#!/usr/bin/env bash
# ===================================================================================
# provision_dmv_stack.sh — main orchestrator (v4)
# Usage:
#   sudo bash provision_dmv_stack.sh <command>
#
# Commands:
#   preflight    - check deps and bridges, SSH key
#   image        - ensure base cloud image is present
#   disks        - create qcow2 disks
#   seeds        - generate cloud-init seed ISOs
#   define       - define & boot both VMs
#   wait         - wait for SSH on both VMs (uses WAIT_SSH / SSH_TIMEOUT_SEC)
#   all          - run everything: preflight → image → disks → seeds → define → (optional wait)
# ===================================================================================

set -Eeuo pipefail
[[ "${VERBOSE:-1}" = "1" ]] && set -x

# Source the library (same directory)
. "$(dirname "$0")/provision_lib.sh"

cmd="${1:-all}"

case "$cmd" in
  preflight)
    preflight
    ;;
  image)
    preflight
    ensure_cloud_image
    ;;
  disks)
    preflight
    ensure_cloud_image
    create_disks
    ;;
  seeds)
    preflight
    ensure_cloud_image
    create_disks
    build_seeds
    ;;
  define)
    preflight
    ensure_cloud_image
    create_disks
    build_seeds
    define_and_boot_vms
    ;;
  wait)
    if [[ "${WAIT_SSH}" = "1" ]]; then
      wait_ssh "$WEB_VM_IP" "$SSH_TIMEOUT_SEC" || true
      wait_ssh "$INTERNAL_VM_IP" "$SSH_TIMEOUT_SEC" || true
    else
      log "[wait] WAIT_SSH=0 → skipping."
    fi
    ;;
  all)
    preflight
    ensure_cloud_image
    create_disks
    build_seeds
    define_and_boot_vms
    if [[ "${WAIT_SSH}" = "1" ]]; then
      wait_ssh "$WEB_VM_IP" "$SSH_TIMEOUT_SEC" || true
      wait_ssh "$INTERNAL_VM_IP" "$SSH_TIMEOUT_SEC" || true
    else
      log "[7/8] Skipping SSH wait (WAIT_SSH=0)."
    fi
    log "[8/8] Done."
    log "Next steps:"
    log " - SSH into web-vm:      ssh ${LOGIN_USERNAME}@${WEB_VM_IP}"
    log " - SSH into internal-vm: ssh ${LOGIN_USERNAME}@${INTERNAL_VM_IP}"
    log "Quick checks:"
    log " - On web-vm:     docker ps; curl -vk https://${INTERNAL_VM_IP}:${INTERNAL_API_PORT}"
    log " - On web-vm:     curl -vk https://8.8.8.8   # should be BLOCKED by host nft"
    log " - On internal-vm:docker ps"
    log "Full log at: $LOG_FILE"
    ;;
  *)
    echo "Unknown command: $cmd"
    echo "Usage: sudo bash provision_dmv_stack.sh {preflight|image|disks|seeds|define|wait|all}"
    exit 1
    ;;
esac
