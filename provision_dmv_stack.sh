#!/usr/bin/env bash
# ==============================================================================
# provision_dmv_stack.sh — orchestrator for DMZ VMs (v6)
# Usage:
#   sudo bash provision_dmv_stack.sh {preflight|image|disks|seeds|define|wait|egress-on|egress-off|all}
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
  egress-on) preflight; enable_temp_egress; schedule_disable_egress ;;
  egress-off)preflight; disable_temp_egress ;;
  define)
    preflight
    ensure_cloud_image
    create_disks
    build_seeds
    enable_temp_egress
    schedule_disable_egress
    define_and_boot_vms
    ;;
  wait)
    if [[ "${WAIT_SSH}" = "1" ]]; then
      wait_ssh "$WEB_VM_IP" "$SSH_TIMEOUT_SEC" || true
      wait_ssh "$INTERNAL_VM_IP" "$SSH_TIMEOUT_SEC" || true
      disable_temp_egress
    else
      log "[wait] WAIT_SSH=0 → skipping."
    fi
    ;;
  all)
    preflight
    ensure_cloud_image
    create_disks
    build_seeds
    enable_temp_egress
    schedule_disable_egress
    define_and_boot_vms
    if [[ "${WAIT_SSH}" = "1" ]]; then
      wait_ssh "$WEB_VM_IP" "$SSH_TIMEOUT_SEC" || true
      wait_ssh "$INTERNAL_VM_IP" "$SSH_TIMEOUT_SEC" || true
      disable_temp_egress
    else
      log "[7/8] Skipping SSH wait (WAIT_SSH=0). Temporary egress will auto-expire in ${PROVISIONING_EGRESS_SECS}s."
    fi
    log "[8/8] Done."
    log "Next steps:"
    log " - SSH web:      ssh ${LOGIN_USERNAME}@${WEB_VM_IP}"
    log " - SSH internal: ssh ${LOGIN_USERNAME}@${INTERNAL_VM_IP}"
    ;;
  *)
    echo "Usage: sudo bash provision_dmv_stack.sh {preflight|image|disks|seeds|define|wait|egress-on|egress-off|all}"
    exit 1
    ;;
esac
