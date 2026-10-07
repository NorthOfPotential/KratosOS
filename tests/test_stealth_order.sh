#!/usr/bin/env bash
# The stubs below replace commands used by the sourced library code; the
# linter cannot see them being called, hence:
# shellcheck disable=SC1091,SC2030,SC2031,SC2034,SC2317,SC2329
# Stealth Mode ordering tests, with libvirt, cryptsetup and nft simulated.
#
# The rule being tested: when Stealth Mode turns off, the Workstation stops
# FIRST and is verified gone before anything else happens. If it can't be
# stopped, the Gateway keeps running and the vault stays as it is.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# Run one scenario in a subshell with everything external replaced by fakes
# that append to $log. $1 = scenario name, $2 = function to run.
scenario() {
    local name="$1" body="$2"
    (
        export KRATOS_LIB="$lib" KRATOS_ETC="$tmp/etc" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run"
        rm -rf "${tmp:?}/etc" "${tmp:?}/state" "${tmp:?}/run" "${tmp:?}/vms"
        mkdir -p "$tmp/etc" "$tmp/state" "$tmp/run" "$tmp/vms"
        touch "$tmp/state/stealth.vault"
        log="$tmp/log"; : > "$log"
        # shellcheck source=/dev/null
        . "$lib/common.sh"; . "$lib/net.sh"; . "$lib/stealth.sh"; . "$lib/opsec.sh"
        STEALTH_SHUTDOWN_TIMEOUT=1
        need_root() { :; }
        need_cmd() { :; }
        load_config() { STEALTH_REQUIRE_VPN=no; STEALTH_WORKSTATION=persistent; }
        sleep() { :; }

        # Fake libvirt: a VM is "running" while $tmp/vms/<name> exists.
        STUCK=""
        vm_running() { [[ -e "$tmp/vms/$1" ]]; }
        virsh_() {
            echo "virsh $*" >> "$log"
            case "$1" in
                create) [[ "${FAIL_CREATE:-}" == "$2" ]] && return 1
                        touch "$tmp/vms/$(basename "$2" .xml)" ;;
                shutdown|destroy) [[ "$2" == "$STUCK" ]] || rm -f "$tmp/vms/$2" ;;
            esac
            return 0
        }
        pgrep() { return 1; }
        pkill() { return 1; }
        nft() { echo "nft $*" >> "$log"; }
        systemctl() { :; }
        python3() { return 0; }
        host_lockdown() { : > "$STEALTH_UNDO"; echo "host-lockdown" >> "$log"; }
        # host_restore's real argv-dispatch is covered by tests/test_undo_safe.sh;
        # here we only need to observe WHEN it runs relative to the VM/vault steps.
        host_restore() { echo "host-restored" >> "$log"; }
        vault_open() { echo "vault-open" >> "$log"; }
        vault_close() { echo "vault-close" >> "$log"; }
        vault_is_open() { return 0; }
        wipe_artifacts() { echo "wipe" >> "$log"; }
        install() { command install "$@" 2>/dev/null || true; }
        mountpoint() { return 1; }
        give_display() { :; }
        qemu-img() { echo "qemu-img $*" >> "$log"; }

        "$body"
        echo "rc=$?" >> "$log"
    ) >"$tmp/out" 2>&1
    echo "scenario: $name"
    if [[ -n "${DEBUG:-}" ]]; then cat "$tmp/out" "$tmp/log"; fi
}

line_of() { grep -n -m1 -F "$1" "$tmp/log" | cut -d: -f1; }
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }
has() { grep -qF "$1" "$tmp/log"; }

# ── 1. Normal shutdown ─────────────────────────────────────────
normal_off() {
    touch "$tmp/vms/kx-gw" "$tmp/vms/kx-ws" "$STEALTH_FLAG"
    : > "$STEALTH_UNDO"; undo "echo host-restored >> '$log'"
    stealth_off_steps
}
scenario "stealth off" normal_off
ws=$(line_of "virsh shutdown kx-ws"); gw=$(line_of "virsh shutdown kx-gw")
vc=$(line_of "vault-close"); hr=$(line_of "host-restored"); fw=$(line_of "nft delete table inet kratos_stealth")
if [[ -n "$ws" && -n "$gw" && "$ws" -lt "$gw" ]]; then pass "Workstation stopped before Gateway"; else flunk "Workstation before Gateway"; fi
if [[ -n "$fw" && "$gw" -lt "$fw" ]]; then pass "firewall removed only after both VMs are off"; else flunk "firewall order"; fi
if [[ -n "$vc" && "$fw" -lt "$vc" ]]; then pass "vault locked after VMs are off"; else flunk "vault order"; fi
if [[ -n "$hr" && "$vc" -lt "$hr" ]]; then pass "host restored last"; else flunk "host restored last"; fi
if [[ ! -e "$tmp/run/stealth.active" ]]; then pass "stealth flag cleared"; else flunk "stealth flag cleared"; fi
if has "rc=0"; then pass "reports success"; else flunk "reports success"; fi

# ── 2. Workstation refuses to die ──────────────────────────────
stuck_off() {
    touch "$tmp/vms/kx-gw" "$tmp/vms/kx-ws" "$STEALTH_FLAG"
    : > "$STEALTH_UNDO"; undo "echo host-restored >> '$log'"
    STUCK=kx-ws
    stealth_off_steps
}
scenario "Workstation can't be stopped" stuck_off
if has "virsh destroy kx-ws"; then pass "escalates to forced power-off"; else flunk "forced power-off"; fi
if ! has "virsh shutdown kx-gw" && ! has "virsh destroy kx-gw"; then
    pass "Gateway left running (Workstation never loses Tor)"; else flunk "Gateway left running"; fi
if ! has "vault-close"; then pass "vault not touched while Workstation runs"; else flunk "vault not touched"; fi
if ! has "host-restored"; then pass "host lockdown kept"; else flunk "host lockdown kept"; fi
if has "rc=1"; then pass "reports failure"; else flunk "reports failure"; fi

# ── 3. Start fails halfway: everything rolls back ──────────────
failed_on() {
    FAIL_CREATE="$tmp/vault/libvirt/kx-ws.xml"
    VAULT_XML="$tmp/vault/libvirt"
    stealth_on
}
scenario "Workstation fails to start" failed_on
if has "virsh create $tmp/vault/libvirt/kx-gw.xml"; then pass "Gateway was started"; else flunk "Gateway started"; fi
if has "virsh shutdown kx-gw"; then pass "rollback stops the Gateway"; else flunk "rollback stops Gateway"; fi
if has "vault-close" && has "host-restored"; then pass "rollback locks vault and restores host"; else flunk "rollback cleanup"; fi
if [[ ! -e "$tmp/run/stealth.active" ]]; then pass "stealth flag cleared"; else flunk "stealth flag cleared after rollback"; fi
if has "rc=1" || ! has "rc=0"; then pass "reports failure"; else flunk "reports failure"; fi

# ── 4. Gateway refuses to die: must stay fail-closed ───────────
stuck_gw_off() {
    touch "$tmp/vms/kx-gw" "$tmp/vms/kx-ws" "$STEALTH_FLAG"
    STUCK=kx-gw
    stealth_off_steps
}
scenario "Gateway can't be stopped" stuck_gw_off
if has "virsh destroy kx-gw"; then pass "escalates to forced power-off on the Gateway"; else flunk "forced gw power-off"; fi
if ! has "vault-close"; then pass "vault NOT locked while Gateway is up"; else flunk "vault touched with gw stuck"; fi
if ! has "host-restored"; then pass "host lockdown kept (gw stuck)"; else flunk "host restored despite gw stuck"; fi
if [[ -e "$tmp/run/stealth.active" ]]; then pass "stealth flag NOT cleared (stays ON, fail-closed)"; else flunk "flag cleared despite gw stuck"; fi
if [[ -e "$tmp/run/stealth.error" ]]; then pass "error state recorded"; else flunk "no error state recorded"; fi
if has "rc=1"; then pass "reports failure"; else flunk "reports failure (gw)"; fi

# ── 5. Vault refuses to lock: must stay fail-closed ────────────
failed_vault_off() {
    touch "$tmp/vms/kx-gw" "$tmp/vms/kx-ws" "$STEALTH_FLAG"
    vault_close() { echo "vault-close-attempt" >> "$log"; return 1; }
    stealth_off_steps
}
scenario "vault can't be locked" failed_vault_off
if has "vault-close-attempt"; then pass "vault close was attempted (both VMs down first)"; else flunk "vault close not attempted"; fi
if ! has "host-restored"; then pass "host NOT restored while vault is still unlocked"; else flunk "host restored despite open vault"; fi
if [[ -e "$tmp/run/stealth.active" ]]; then pass "stealth flag NOT cleared (stays ON, fail-closed)"; else flunk "flag cleared despite open vault"; fi
if [[ -e "$tmp/run/stealth.error" ]]; then pass "error state recorded"; else flunk "no error state recorded"; fi
if has "rc=1"; then pass "reports failure"; else flunk "reports failure (vault)"; fi

exit "$fail"
