#!/usr/bin/env bash
# Build the KratosOS installer ISO (live session + Calamares installer)
# with Debian live-build.
# Usage: sudo ./build.sh [--clean]
set -euo pipefail

cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
    echo "build.sh must run as root (live-build needs it)." >&2
    exit 1
fi
command -v lb >/dev/null || { echo "Install live-build first: apt install live-build" >&2; exit 1; }

if [[ "${1:-}" == "--clean" ]]; then
    lb clean --purge
fi

# Ship the docs inside the image
install -d config/includes.chroot/usr/share/doc/kratos
cp docs/*.md config/includes.chroot/usr/share/doc/kratos/
install -d config/includes.chroot/usr/share/kratos
cp migration/Export-WindowsData.ps1 config/includes.chroot/usr/share/kratos/

# Same hardening as the installed system (etc/default/grub.d/kratos.cfg):
#   init_on_alloc/init_on_free  zero memory, so freed data doesn't linger in RAM
#   page_alloc.shuffle, slab_nomerge, randomize_kstack_offset  harder kernel exploits
#   vsyscall=none, debugfs=off  remove legacy and debug attack surface
#   ipv6.disable=1              no IPv6, so no IPv6 leaks around the VPN
#   *_iommu, iommu.strict       protect against DMA attacks (Thunderbolt, PCIe)
KERNEL_PARAMS="init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 slab_nomerge pti=on \
randomize_kstack_offset=on vsyscall=none debugfs=off ipv6.disable=1 intel_iommu=on \
amd_iommu=force_isolation iommu.strict=1 apparmor=1 security=apparmor quiet splash"

lb config \
    --distribution trixie \
    --architectures amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --binary-images iso-hybrid \
    --debian-installer none \
    --bootappend-live "boot=live components ${KERNEL_PARAMS}" \
    --iso-application "KratosOS" \
    --iso-publisher "KratosOS project" \
    --iso-volume "KratosOS" \
    --image-name kratosos \
    --security true \
    --updates true \
    --memtest none

lb build

echo
echo "Built: $(ls -1 kratosos-*.iso)"
sha256sum kratosos-*.iso | tee SHA256SUMS
