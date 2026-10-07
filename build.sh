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

# Notes:
#  * --mode debian + explicit Debian mirrors: on an Ubuntu host, live-build
#    otherwise builds a *ubuntu* system and looks for the 'trixie' suite on
#    archive.ubuntu.com (where it doesn't exist), failing bootstrap. Forcing
#    Debian mode and deb.debian.org fixes that regardless of build host.
#  * --security false: this old live-build builds the security suite as the
#    pre-2021 "<dist>/updates" name (trixie/updates), which 404s — Debian has
#    used "<dist>-security" for years. Disable the build-time security archive
#    so the build completes; the installed system gets security updates via
#    apt at runtime (its sources.list uses the correct trixie-security suite).
#  * --image-name and --updates were dropped in current live-build; the
#    updates archive is on by default. The output is named live-image-* which
#    we rename below.
lb config \
    --mode debian \
    --distribution trixie \
    --architectures amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --security false \
    --mirror-bootstrap http://deb.debian.org/debian/ \
    --mirror-chroot http://deb.debian.org/debian/ \
    --mirror-binary http://deb.debian.org/debian/ \
    --binary-images iso-hybrid \
    --debian-installer none \
    --bootappend-live "boot=live components ${KERNEL_PARAMS}" \
    --iso-application "KratosOS" \
    --iso-publisher "KratosOS project" \
    --iso-volume "KratosOS" \
    --memtest none

lb build

# live-build writes live-image-amd64.hybrid.iso; publish it under our name.
out="kratosos-amd64.hybrid.iso"
built=""
for f in "$out" live-image-*.hybrid.iso kratosos-*.iso; do
    [ -f "$f" ] && { built="$f"; break; }
done
[ -n "$built" ] || { echo "build produced no ISO" >&2; exit 1; }
[ "$built" = "$out" ] || mv -f "$built" "$out"

# Publish live-build's own package manifest (every package + exact version that
# went into the image) next to the ISO. This is the authoritative input for the
# SBOM and lets anyone audit exactly what shipped. live-build names it
# live-image-amd64.packages; tolerate other names across versions.
manifest="kratosos-amd64.packages"
for m in live-image-*.packages binary.packages chroot.packages.install; do
    [ -f "$m" ] && { cp -f "$m" "$manifest"; break; }
done

echo
echo "Built: $out"
sha256sum "$out" | tee SHA256SUMS
