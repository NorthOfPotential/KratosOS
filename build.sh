#!/usr/bin/env bash
# Build the KratosOS live ISO with Debian live-build.
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

# Hardened kernel command line:
#   init_on_alloc/init_on_free  zero memory, so freed data doesn't linger in RAM
#   page_alloc.shuffle          randomize page allocator
#   slab_nomerge, pti=on        mitigate heap and Meltdown-class attacks
#   randomize_kstack_offset     kernel stack randomization
#   vsyscall=none, debugfs=off  remove legacy and debug attack surface
#   lockdown=confidentiality    block kernel memory reads even from root
#   ipv6.disable=1              no IPv6 means no IPv6 leaks
#   module.sig_enforce=1        only signed kernel modules
#   mce=0, oops=panic           don't continue in a corrupted state
KERNEL_PARAMS="init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 slab_nomerge pti=on \
randomize_kstack_offset=on vsyscall=none debugfs=off lockdown=confidentiality \
ipv6.disable=1 module.sig_enforce=1 oops=panic spectre_v2=on spec_store_bypass_disable=on \
l1tf=full,force mds=full,nosmt tsx=off apparmor=1 security=apparmor quiet splash"

lb config \
    --distribution trixie \
    --architectures amd64 \
    --archive-areas "main contrib non-free-firmware" \
    --binary-images iso-hybrid \
    --bootappend-live "boot=live components noautologin hostname=localhost username=amnesia timezone=Etc/UTC locales=en_US.UTF-8 ${KERNEL_PARAMS}" \
    --iso-application "KratosOS" \
    --iso-publisher "KratosOS project" \
    --iso-volume "KratosOS" \
    --image-name kratosos \
    --apt-recommends false \
    --security true \
    --updates true \
    --memtest none

lb build

echo
echo "Built: $(ls -1 kratosos-*.iso)"
sha256sum kratosos-*.iso | tee SHA256SUMS
