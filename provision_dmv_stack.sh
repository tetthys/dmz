#!/usr/bin/env bash
# ==============================================================================
# provision_dmv_stack.sh — Orchestrator
# Usage:
#   sudo bash provision_dmv_stack.sh {preflight|image|disks|seeds|define|egress-on|egress-off|wait|all}
# ==============================================================================
set -Eeuo pipefail
[[ "${VERBOSE:-1}" = "1" ]] && set -x

. "$(dirname "$0")/provision_lib.sh"

cmd="${1:-all}"

case "$cmd" in
  preflight)      preflight ;;
  image)          preflight; ensure_cloud_image ;;
  disks)          preflight; ensure_cloud_image; create_disks ;;
  seeds)          preflight; ensure_cloud_image; create_disks; build_seeds ;;
  egress-on)      preflight; enable_temp_egress; schedule_disable_egress ;;
  egress-off)     preflight; disable_temp_egress ;;
  define)
    preflight
    ensure_cloud_image
    create_disks
    build_seeds
    [[ "${ENABLE_TEMP_EGRESS}" = "1" ]] && { enable_temp_egress; schedule_disable_egress; }
    define_and_boot_vms
    ;;
  wait)
    [[ "${WAIT_SSH}" = "1" ]] && {
      wait_ssh "$WEB_VM_IP" "$SSH_TIMEOUT_SEC" || true
      wait_ssh "$INTERNAL_VM_IP" "$SSH_TIMEOUT_SEC" || true
      [[ "${ENABLE_TEMP_EGRESS}" = "1" ]] && disable_temp_egress || true
    } || section "[7/8] Skipping SSH wait (WAIT_SSH=0)"
    ;;
  all)
    preflight
    ensure_cloud_image
    create_disks
    build_seeds
    [[ "${ENABLE_TEMP_EGRESS}" = "1" ]] && { enable_temp_egress; schedule_disable_egress; }
    define_and_boot_vms
    if [[ "${WAIT_SSH}" = "1" ]]; then
      wait_ssh "$WEB_VM_IP" "$SSH_TIMEOUT_SEC" || true
      wait_ssh "$INTERNAL_VM_IP" "$SSH_TIMEOUT_SEC" || true
      [[ "${ENABLE_TEMP_EGRESS}" = "1" ]] && disable_temp_egress || true
    else
      section "[7/8] Skipping SSH wait (WAIT_SSH=0)"
    fi
    section "[8/8] Done"
    log "SSH web:      ssh ${LOGIN_USERNAME}@${WEB_VM_IP}"
    log "SSH internal: ssh ${LOGIN_USERNAME}@${INTERNAL_VM_IP}"
    ;;
  *)
    echo "Usage: sudo bash provision_dmv_stack.sh {preflight|image|disks|seeds|define|egress-on|egress-off|wait|all}"
    exit 1
    ;;
esac
