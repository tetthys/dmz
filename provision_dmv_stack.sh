#!/usr/bin/env bash
# ==============================================================================
# provision_dmv_stack.sh — orchestrator for DMZ VMs (split version)
# Usage:
#   sudo bash provision_dmv_stack.sh {preflight|image|disks|seeds|define|wait|all}
# ==============================================================================
set -Eeuo pipefail
[[ "${VERBOSE:-1}" = "1" ]] && set -x

. "$(dirname "$0")/provision_lib.sh"

cmd="${1:-all}"
case "$cmd" in
  preflight) preflight ;;
  image)     preflight; ensure_cloud_image ;;
  disks)     preflight; ensure_cloud_image; create_disks ;;
  seeds)     preflight; ensure_cloud_image; create_disks; build_seeds ;;
  define)    preflight; ensure_cloud_image; create_disks; build_seeds; define_and_boot_vms ;;
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
    log " - SSH web:      ssh ${LOGIN_USERNAME}@${WEB_VM_IP}"
    log " - SSH internal: ssh ${LOGIN_USERNAME}@${INTERNAL_VM_IP}"
    ;;
  *) echo "Usage: sudo bash provision_dmv_stack.sh {preflight|image|disks|seeds|define|wait|all}"; exit 1 ;;
esac
