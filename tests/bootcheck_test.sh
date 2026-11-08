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

# VM install test: on the real system `kratos` runs under `set -euo pipefail`
# and firecfg had wrapped sha256sum in firejail (which refuses >128 args), so
# xargs exited 123 and `kratos bootcheck` died with NO output. Run exactly
# like the real tool (errexit + pipefail) with a sha256sum that fails.
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\necho "Error: too many arguments" >&2\nexit 1\n' > "$tmp/fakebin/sha256sum"
chmod +x "$tmp/fakebin/sha256sum"
out="$(PATH="$tmp/fakebin:$PATH" bash -c '
    set -euo pipefail
    KRATOS_STATE="'"$tmp/state"'"
    . "'"$lib"'/common.sh"
    . "'"$lib"'/bootcheck.sh"
    BOOT_PATHS=("'"$tmp"'/boot")
    need_root() { :; }
    load_config() { :; }
    bootcheck_main record
    echo REACHED-END
' 2>&1)"
if grep -q REACHED-END <<<"$out" && grep -q 'could not hash every file' <<<"$out" \
   && grep -q '^HASHING-INCOMPLETE' "$tmp/state/boot.baseline"; then
    pass "a hashing failure is reported and recorded, never a silent abort under set -e"
else
    flunk "bootcheck aborted silently when sha256sum failed: $out"
fi

# VM test, part 2: tpm2-tools installed but no TPM (VirtualBox) -> tpm2_pcrread
# fails; under errexit that killed `bootcheck record` silently too.
rm -f "$tmp/fakebin/sha256sum"
printf '#!/bin/sh\necho "ERROR: no TPM" >&2\nexit 1\n' > "$tmp/fakebin/tpm2_pcrread"
chmod +x "$tmp/fakebin/tpm2_pcrread"
out="$(PATH="$tmp/fakebin:$PATH" bash -c '
    set -euo pipefail
    KRATOS_STATE="'"$tmp/state"'"
    . "'"$lib"'/common.sh"
    . "'"$lib"'/bootcheck.sh"
    BOOT_PATHS=("'"$tmp"'/boot")
    need_root() { :; }
    load_config() { :; }
    bootcheck_main record
    echo REACHED-END
' 2>&1)"
if grep -q REACHED-END <<<"$out" && grep -q 'recorded boot baseline' <<<"$out" \
   && grep -q 'no TPM found' <<<"$out"; then
    pass "tpm2-tools without a TPM: record completes and says no TPM (no silent abort)"
else
    flunk "bootcheck record aborted silently without a TPM: $out"
fi

# Root tools must search system directories before /usr/local, where firecfg
# drops firejail wrapper symlinks for ordinary commands.
inc="$here/../config/includes.chroot/usr/local/bin"
for t in kratos kratos-ai; do
    if grep -qE '^export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin$' "$inc/$t" \
       && ! grep -qE '^export PATH=/usr/local' "$inc/$t"; then
        pass "$t searches system dirs before /usr/local (no firejail wrappers as root)"
    else
        flunk "$t puts /usr/local first on PATH"
    fi
done

echo
if (( fail )); then echo "BOOTCHECK TESTS FAILED"; else echo "bootcheck tests passed"; fi
exit "$fail"
