# shellcheck shell=bash
# OpSec tools: metadata scrubbing, secure deletion, scanning, USB, panic.

opsec_scrub() {
    need_cmd mat2
    [[ $# -gt 0 ]] || die "usage: kratos scrub [--show] <files...>"
    if [[ "$1" == --show ]]; then
        shift
        mat2 --show "$@"
        return
    fi
    # mat2 writes "<name>.cleaned.<ext>" next to each file and keeps the original
    mat2 "$@"
    ok "cleaned copies written as *.cleaned.*; check them, then: kratos shred <originals>"
}

opsec_shred() {
    [[ $# -gt 0 ]] || die "usage: kratos shred <files...>"
    warn "On SSDs and flash drives overwriting is NOT reliable (wear levelling keeps old copies)."
    warn "Your real protection is disk encryption. This removes the file and overwrites what it can."
    confirm "Permanently destroy $# item(s)?" || exit 0
    local f
    for f in "$@"; do
        # `--` so a filename beginning with '-' is never read as an option.
        if [[ -d "$f" ]]; then
            find "$f" -type f -exec shred -uz -- {} + && rm -rf -- "$f"
        else
            shred -uz -- "$f"
        fi
        ok "destroyed $f"
    done
}

opsec_scan() {
    local target="${1:-$HOME}"
    need_cmd clamscan
    info "${BOLD}Malware scan:${RESET} $target"
    clamscan -r -i --exclude-dir='^/proc|^/sys|^/dev' "$target" || true
    if [[ $EUID -eq 0 ]] && command -v rkhunter >/dev/null; then
        info "${BOLD}Rootkit scan${RESET}"
        rkhunter --check --sk --rwo || true
    else
        info "(run with sudo to include the rootkit scan)"
    fi
}

opsec_usb() {
    need_cmd usbguard
    case "${1:-list}" in
        list)  usbguard list-devices ;;
        allow) need_root usb allow "${2:-}"; usbguard allow-device "${2:?device id}" ;;
        block) need_root usb block "${2:-}"; usbguard block-device "${2:?device id}" ;;
        *) die "usage: kratos usb [list | allow <id> | block <id>]" ;;
    esac
}

# Fastest safe shutdown: kill the stealth VMs, lock the vault, cut the
# network, kill user sessions (so freed memory is zeroed by init_on_free),
# power off.
opsec_panic() {
    need_root panic
    nft -f "$KRATOS_ETC/modes/offline.nft" 2>/dev/null || true
    stealth_kill
    loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' \
        | xargs -r -n1 loginctl kill-session --signal=KILL 2>/dev/null || true
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    systemctl poweroff --force --force
}
