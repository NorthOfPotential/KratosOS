#!/usr/bin/env bash
# bootcheck: record a baseline of a fake /boot tree, then confirm verify passes
# when nothing changes and fails on modify/add/remove.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

# Fake boot tree + state dir
mkdir -p "$tmp/boot/efi/EFI/debian" "$tmp/state"
echo "vmlinuz-6.x" > "$tmp/boot/vmlinuz"
echo "initrd data" > "$tmp/boot/initrd.img"
echo "grub config" > "$tmp/boot/efi/EFI/debian/grub.cfg"

# Drive bootcheck with overridden paths/state, mocking root + output helpers.
run_bootcheck() {  # $1 = record|verify
    env KRATOS_STATE="$tmp/state" bash -c '
        KRATOS_STATE="'"$tmp/state"'"
        # shellcheck source=/dev/null
        . "'"$lib"'/common.sh"
        . "'"$lib"'/bootcheck.sh"
        BOOT_PATHS=("'"$tmp"'/boot")
        need_root() { :; }
        load_config() { :; }
        bootcheck_main "'"$1"'"
    ' 2>&1
}

run_bootcheck record >/dev/null
if [[ -s "$tmp/state/boot.baseline" ]]; then pass "baseline recorded"; else flunk "no baseline written"; fi

if run_bootcheck verify >/dev/null; then pass "clean tree verifies"; else flunk "clean verify failed"; fi

# Modify a file
echo "tampered" >> "$tmp/boot/vmlinuz"
if run_bootcheck verify >/dev/null; then flunk "modified kernel not detected"; else pass "modified file detected"; fi
echo "vmlinuz-6.x" > "$tmp/boot/vmlinuz"  # restore
if run_bootcheck verify >/dev/null; then pass "verify clean again after restore"; else flunk "restore not clean"; fi

# Add a file (implant drops a payload)
echo "payload" > "$tmp/boot/efi/EFI/debian/evil.efi"
if run_bootcheck verify >/dev/null; then flunk "added file not detected"; else pass "added file detected"; fi
rm "$tmp/boot/efi/EFI/debian/evil.efi"

# Remove a file
rm "$tmp/boot/initrd.img"
if run_bootcheck verify >/dev/null; then flunk "removed file not detected"; else pass "removed file detected"; fi

echo
if (( fail )); then echo "BOOTCHECK TESTS FAILED"; else echo "bootcheck tests passed"; fi
exit "$fail"
