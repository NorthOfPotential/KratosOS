#!/usr/bin/env bash
# Calamares installs OFFLINE from the live image: Debian's install-time helper
# (calamares-bootloader-config) tries `apt-get install cryptsetup-initramfs
# cryptsetup keyutils` and `grub-pc`, which silently fail with no network. So
# everything they would fetch must already be in the image. Missing
# cryptsetup-initramfs made every encrypted install drop to "(initramfs)" after
# GRUB (VM install test); missing grub-pc left no bootloader (earlier test).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lists="$here/../config/package-lists"
hook="$here/../config/hooks/live/0100-kratos.hook.chroot"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

in_image() { grep -hvE '^[[:space:]]*(#|$)' "$lists"/*.list.chroot | grep -qx "$1"; }
for p in cryptsetup cryptsetup-initramfs keyutils grub-pc grub-efi-amd64-bin grub2-common; do
    if in_image "$p"; then pass "$p ships in the image (offline install)"
    else flunk "$p is not in any package list: offline installs break"; fi
done
if grep -q '/usr/share/initramfs-tools/hooks/cryptroot' "$hook" \
   && grep -A3 'hooks/cryptroot' "$hook" | grep -q 'exit 1'; then
    pass "build fails if the initramfs LUKS hook (cryptroot) is missing"
else
    flunk "image hook does not guard against a missing cryptroot initramfs hook"
fi
exit "$fail"
