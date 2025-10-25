#!/usr/bin/env bash
set -euo pipefail

# Usage: edit the variables below and then run the printed commands manually.

WEB_VM_NAME="web-vm"
WEB_VM_DISK="/var/lib/libvirt/images/web-vm.qcow2"
WEB_VM_MEM="4096"
WEB_VM_CPUS="2"
WEB_BRIDGE="br-external"

INTERNAL_VM_NAME="internal-vm"
INTERNAL_VM_DISK="/var/lib/libvirt/images/internal-vm.qcow2"
INTERNAL_VM_MEM="4096"
INTERNAL_VM_CPUS="2"
INTERNAL_BRIDGE="br-internal"

# Path to Ubuntu ISO or autoinstall mechanism
ISO_PATH="/var/lib/libvirt/boot/ubuntu-22.04-server.iso"

echo "=== VM install command templates ==="
echo ""
echo "WEB VM install (run after editing values if needed):"
echo "virt-install --name ${WEB_VM_NAME} --memory ${WEB_VM_MEM} --vcpus ${WEB_VM_CPUS} --disk path=${WEB_VM_DISK},size=20 --os-variant ubuntu22.04 --network bridge=${WEB_BRIDGE},model=virtio --graphics none --console pty,target_type=serial --cdrom ${ISO_PATH}"
echo ""
echo "INTERNAL VM install (run after editing values if needed):"
echo "virt-install --name ${INTERNAL_VM_NAME} --memory ${INTERNAL_VM_MEM} --vcpus ${INTERNAL_VM_CPUS} --disk path=${INTERNAL_VM_DISK},size=30 --os-variant ubuntu22.04 --network bridge=${INTERNAL_BRIDGE},model=virtio --graphics none --console pty,target_type=serial --cdrom ${ISO_PATH}"
echo ""
echo "Note: Consider using cloud-init/autoinstall for unattended install."
