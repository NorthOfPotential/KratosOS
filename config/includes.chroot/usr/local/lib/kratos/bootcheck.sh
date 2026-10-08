# shellcheck shell=bash
# Boot / firmware integrity check — detection, not prevention.
#
# A firmware or bootloader implant ("evil maid") is below the OS, so software
# can't stop it. What software CAN do is *notice* that /boot, the EFI System
# Partition or the TPM measurements changed between boots, which is the
# signature of such tampering. This records a baseline and warns on drift.
#
# Limits (be honest): if firmware is already compromised it can lie to this
# check. Real assurance needs measured boot with a hardware root of trust
# (TPM-sealed secrets, Heads/Coreboot, Anti Evil Maid). This raises the bar
# and catches unsophisticated tampering; it is not a guarantee.

BOOTCHECK_BASELINE="$KRATOS_STATE/boot.baseline"   # sha256 manifest
BOOTCHECK_PCRS="$KRATOS_STATE/boot.pcrs"           # TPM PCR snapshot
BOOT_PATHS=(/boot /boot/efi)

# Print a sorted sha256 manifest of everything under the boot paths.
bootcheck_manifest() {
    local p
    for p in "${BOOT_PATHS[@]}"; do
        [[ -d "$p" ]] || continue
        find "$p" -type f -print0 2>/dev/null \
            | sort -z \
            | xargs -0 sha256sum 2>/dev/null
    done
}

# Snapshot TPM PCRs 0-7 (firmware, option ROMs, bootloader) if a TPM is present.
bootcheck_pcr_snapshot() {
    if command -v tpm2_pcrread >/dev/null 2>&1; then
        tpm2_pcrread sha256:0,1,2,3,4,5,6,7 2>/dev/null
    fi
}

bootcheck_record() {
    need_root bootcheck record
    install -d -m 755 "$KRATOS_STATE"
    bootcheck_manifest > "$BOOTCHECK_BASELINE"
    chmod 644 "$BOOTCHECK_BASELINE"
    bootcheck_pcr_snapshot > "$BOOTCHECK_PCRS"
    local n; n=$(wc -l < "$BOOTCHECK_BASELINE")
    ok "recorded boot baseline ($n files)"
    if [[ -s "$BOOTCHECK_PCRS" ]]; then
        ok "recorded TPM PCR baseline"
    elif ! command -v tpm2_pcrread >/dev/null 2>&1; then
        warn "TPM measurement UNAVAILABLE: tpm2-tools (tpm2_pcrread) is not installed, so firmware/boot PCRs are NOT baselined — only file hashes are (finding R6-38)"
    else
        warn "no TPM found; only file hashes are baselined"
    fi
    warn "store a copy of $BOOTCHECK_BASELINE off this machine; a local implant could rewrite it"
}

# Compare current state to the baseline. Exit non-zero on any drift.
bootcheck_verify() {
    [[ -r "$BOOTCHECK_BASELINE" ]] || die "no baseline; run: sudo kratos bootcheck record"
    local cur rc=0
    cur="$(mktemp)"
    bootcheck_manifest > "$cur"
    if diff -q "$BOOTCHECK_BASELINE" "$cur" >/dev/null; then
        ok "/boot and ESP unchanged since baseline"
    else
        bad "BOOT FILES CHANGED since baseline:"
        # Show what differs (added, removed, modified) without dumping hashes.
        diff <(awk '{print $2}' "$BOOTCHECK_BASELINE") <(awk '{print $2}' "$cur") \
            | grep '^[<>]' | sed 's/^</  removed: /; s/^>/  added:   /' >&2
        comm -3 <(sort "$BOOTCHECK_BASELINE") <(sort "$cur") \
            | awk '{print $2}' | sort -u \
            | while read -r f; do [[ -e "$f" ]] && echo "  modified: $f" >&2; done
        rc=1
    fi
    rm -f "$cur"

    if [[ -s "$BOOTCHECK_PCRS" ]]; then
        if ! command -v tpm2_pcrread >/dev/null 2>&1; then
            warn "a TPM PCR baseline exists but tpm2_pcrread is gone — CANNOT verify firmware/boot measurements (install tpm2-tools)"
        elif diff -q "$BOOTCHECK_PCRS" <(bootcheck_pcr_snapshot) >/dev/null; then
            ok "TPM PCRs match baseline"
        else
            bad "TPM PCRs CHANGED — firmware/boot measurements differ"
            rc=1
        fi
    elif ! command -v tpm2_pcrread >/dev/null 2>&1; then
        warn "TPM PCR verification unavailable (tpm2-tools not installed); checked file hashes only"
    fi
    if (( rc == 0 )); then
        ok "boot integrity OK"
    else
        err "boot integrity FAILED — do not enter secrets; investigate from trusted media"
    fi
    return "$rc"
}

bootcheck_main() {
    load_config
    case "${1:-verify}" in
        record) bootcheck_record ;;
        verify) need_root bootcheck verify; bootcheck_verify ;;
        *) die "usage: kratos bootcheck {record|verify}" ;;
    esac
}
