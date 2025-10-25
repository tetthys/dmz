#!/usr/bin/env bash
set -euo pipefail

# Install KVM, libvirt, and bridge utilities (Ubuntu/Debian)
# Run as root or with sudo
apt update
DEBIAN_FRONTEND=noninteractive apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils nftables

# Enable and start libvirtd
systemctl enable --now libvirtd

echo "KVM and libvirt packages installed and libvirtd started."
