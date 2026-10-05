# shellcheck shell=bash
# Stealth Mode: an isolated Whonix persona environment on top of the normal
# desktop.
#
#   ON:  host lockdown -> unlock vault -> firewall -> Gateway -> Workstation
#   OFF: Workstation off -> Gateway off -> firewall -> wipe artifacts
#        -> lock vault -> undo host lockdown
#
# The VMs and their networks are *transient* libvirt objects created from XML
# stored inside the encrypted vault. When Stealth Mode is off and the vault is
# locked, libvirt has no record of them.

WHONIX_SIGNING_FPR="916B8D99C38EAF5E8ADC7A2A8D66066A2EEACCDA"

VAULT_IMG="$KRATOS_STATE/stealth.vault"
VAULT_MAPPER="kratos-stealth"
VAULT_MNT="$KRATOS_STATE/vault"
VAULT_XML="$VAULT_MNT/libvirt"
STEALTH_FLAG="$KRATOS_RUN/stealth.active"
STEALTH_UNDO="$KRATOS_RUN/stealth.undo"
STEALTH_NFT="$KRATOS_ETC/stealth.nft"
HARDEN="$KRATOS_LIB/harden-whonix.py"
SPICE_DIR="$KRATOS_RUN/spice"
# Dedicated unprivileged user that owns the persona display and runs the
# viewer in its own login session, isolated from the normal desktop user.
STEALTH_USER="${STEALTH_USER:-kstealth}"
GW="kx-gw"
WS="kx-ws"

virsh_() { virsh -q -c qemu:///system "$@"; }

stealth_is_active() { [[ -e "$STEALTH_FLAG" ]]; }

vault_is_open() { [[ -e "/dev/mapper/$VAULT_MAPPER" ]]; }

# Passphrase given on stdin by the GUI (read once, since several steps need it).
# Empty means cryptsetup prompts on the terminal.
VAULT_PASS=""
read_stdin_pass() {
    IFS= read -r VAULT_PASS || true
    [[ -n "$VAULT_PASS" ]] || die "no passphrase on stdin"
}

# Run cryptsetup with the GUI passphrase if we have one, else interactively.
cryptsetup_pass() {
    if [[ -n "$VAULT_PASS" ]]; then
        printf '%s' "$VAULT_PASS" | cryptsetup "$@" --key-file -
    else
        cryptsetup "$@"
    fi
}

vault_open() {
    vault_is_open || cryptsetup_pass open "$VAULT_IMG" "$VAULT_MAPPER" \
        || die "could not unlock the stealth vault"
    # 0700 root: even while unlocked, no other user can enter the vault or read
    # the VM disks, which hold the persona's whole filesystem.
    install -d -m 700 "$VAULT_MNT"
    chown root:root "$VAULT_MNT"
    mountpoint -q "$VAULT_MNT" \
        || mount -o nodev,nosuid,noexec "/dev/mapper/$VAULT_MAPPER" "$VAULT_MNT" \
        || die "could not mount the stealth vault"
    chmod 700 "$VAULT_MNT"
}

vault_close() {
    sync
    if mountpoint -q "$VAULT_MNT"; then
        umount "$VAULT_MNT" || umount -l "$VAULT_MNT"
    fi
    if vault_is_open; then
        cryptsetup close "$VAULT_MAPPER" || { bad "vault could not be locked"; return 1; }
    fi
}

vault_create() {
    info "Creating the ${STEALTH_VAULT_SIZE} encrypted stealth vault."
    info "Use a passphrase you have never used anywhere else."
    install -d -m 755 "$KRATOS_STATE"
    fallocate -l "$STEALTH_VAULT_SIZE" "$VAULT_IMG"
    chmod 600 "$VAULT_IMG"
    local verify=()
    [[ -z "$VAULT_PASS" ]] && verify=(--verify-passphrase)
    cryptsetup_pass luksFormat --batch-mode --type luks2 --pbkdf argon2id "${verify[@]}" "$VAULT_IMG" \
        || { rm -f "$VAULT_IMG"; die "vault creation failed"; }
    cryptsetup_pass open "$VAULT_IMG" "$VAULT_MAPPER" || die "could not unlock the new vault"
    mkfs.ext4 -q -L kxvault "/dev/mapper/$VAULT_MAPPER"
    vault_open
}

# Verify a Whonix download against the Whonix signing key.
verify_whonix() {
    local archive="$1" sig="$2" key="$3" gnupg result=ok
    gnupg="$(mktemp -d)"
    if ! GNUPGHOME="$gnupg" gpg -q --import "$key" 2>/dev/null; then
        result="cannot import key $key"
    elif ! GNUPGHOME="$gnupg" gpg --with-colons --fingerprint 2>/dev/null \
            | grep -q "^fpr:::::::::$WHONIX_SIGNING_FPR:"; then
        result="key file is not the Whonix signing key ($WHONIX_SIGNING_FPR)"
    elif ! GNUPGHOME="$gnupg" gpg --status-fd 1 --verify "$sig" "$archive" 2>/dev/null \
            | awk -v fpr="$WHONIX_SIGNING_FPR" '$2=="VALIDSIG" && $NF==fpr {found=1} END {exit !found}'; then
        result="SIGNATURE CHECK FAILED for $archive. Do not use this download."
    fi
    rm -rf "$gnupg"
    [[ "$result" == ok ]] || die "$result"
    ok "Whonix signature verified"
}

stealth_setup() {
    local archive="" sig="" key=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sig) sig="$2"; shift 2 ;;
            --key) key="$2"; shift 2 ;;
            --passphrase-stdin) read_stdin_pass; shift ;;
            *) archive="$1"; shift ;;
        esac
    done
    need_root stealth setup
    load_config
    need_cmd gpg tar xz qemu-img virsh cryptsetup python3
    [[ -r "$archive" ]] || die "usage: kratos stealth setup <Whonix-*.libvirt.xz> [--sig FILE.asc] [--key derivative.asc]
Download the KVM image, its .asc signature and the signing key from https://www.whonix.org/wiki/KVM"
    stealth_is_active && die "turn Stealth Mode off first"
    sig="${sig:-$archive.asc}"
    key="${key:-$KRATOS_ETC/whonix-signing-key.asc}"
    [[ -r "$sig" ]] || die "signature not found: $sig"
    [[ -r "$key" ]] || die "signing key not found: $key (download derivative.asc from whonix.org)"

    verify_whonix "$archive" "$sig" "$key"

    if [[ -e "$VAULT_IMG" ]]; then
        vault_open
    else
        vault_create
    fi

    local imp="$VAULT_MNT/import"
    rm -rf "$imp"
    install -d -m 700 "$imp" "$VAULT_XML"
    info "Extracting Whonix (this takes a few minutes)..."
    tar -xJf "$archive" -C "$imp" --no-same-owner

    one() {
        local f
        f="$(find "$imp" -maxdepth 2 -iname "$1" | head -n1)"
        [[ -n "$f" ]] || die "Whonix archive is missing $1"
        echo "$f"
    }
    local gw_disk ws_disk gw_xml ws_xml ext_xml int_xml
    gw_disk="$(one '*Gateway*.qcow2')"
    ws_disk="$(one '*Workstation*.qcow2')"
    gw_xml="$(one '*Gateway*.xml')"
    ws_xml="$(one '*Workstation*.xml')"
    ext_xml="$(one '*external*network*.xml')"
    int_xml="$(one '*internal*network*.xml')"

    mv -f "$gw_disk" "$VAULT_MNT/gateway.qcow2"
    mv -f "$ws_disk" "$VAULT_MNT/workstation-base.qcow2"
    stealth_reset_overlay

    python3 "$HARDEN" prepare \
        --gw-xml "$gw_xml" --ws-xml "$ws_xml" --ext-xml "$ext_xml" --int-xml "$int_xml" \
        --gw-disk "$VAULT_MNT/gateway.qcow2" --ws-disk "$VAULT_MNT/workstation.qcow2" \
        --gw-ram "$STEALTH_GATEWAY_RAM" --ws-ram "$STEALTH_WORKSTATION_RAM" \
        --outdir "$VAULT_XML" || die "Whonix definitions failed the isolation check"
    rm -rf "$imp"
    vault_close
    ok "Stealth Mode is ready. Turn it on from the tray, or: sudo kratos stealth on"
    warn "You can delete the downloaded archive now (kratos shred <file>)."
}

# The Workstation runs from an overlay on top of a clean base image, so
# "disposable" is just throwing the overlay away.
stealth_reset_overlay() {
    rm -f "$VAULT_MNT/workstation.qcow2"
    qemu-img create -q -f qcow2 -F qcow2 -b "$VAULT_MNT/workstation-base.qcow2" \
        "$VAULT_MNT/workstation.qcow2"
}

# ── Host lockdown ───────────────────────────────────────────

undo() { printf '%s\n' "$*" >> "$STEALTH_UNDO"; }

host_lockdown() {
    : > "$STEALTH_UNDO"
    chmod 600 "$STEALTH_UNDO"

    if [[ "$STEALTH_DISABLE_SWAP" == yes && -n "$(swapon --noheadings --show 2>/dev/null)" ]]; then
        swapoff -a || die "not enough free RAM to disable swap; close some programs"
        undo "swapon -a"
        ok "swap off"
    fi
    if [[ "$STEALTH_BLOCK_SLEEP" == yes ]]; then
        local targets="sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"
        # shellcheck disable=SC2086
        systemctl mask --runtime --quiet $targets
        undo "systemctl unmask --runtime --quiet $targets"
        ok "suspend/hibernate blocked"
    fi
    if [[ "$STEALTH_BLOCK_BLUETOOTH" == yes ]] && command -v rfkill >/dev/null; then
        if rfkill list bluetooth 2>/dev/null | grep -q 'Soft blocked: no'; then
            rfkill block bluetooth
            undo "rfkill unblock bluetooth"
        fi
        ok "bluetooth off"
    fi
    if [[ "$STEALTH_BLOCK_CAMERA" == yes ]]; then
        install -d /run/modprobe.d
        echo "install uvcvideo /bin/false" > /run/modprobe.d/kratos-stealth.conf
        undo "rm -f /run/modprobe.d/kratos-stealth.conf"
        if lsmod | grep -q '^uvcvideo'; then
            if modprobe -r uvcvideo 2>/dev/null; then
                undo "modprobe uvcvideo"
                ok "camera off"
            else
                warn "camera is in use and could not be disabled; close apps using it"
            fi
        fi
    fi
    if [[ "$STEALTH_BLOCK_NEW_USB" == yes ]] && systemctl is-active --quiet usbguard; then
        local prev
        prev="$(usbguard get-parameter ImplicitPolicyTarget 2>/dev/null || echo allow)"
        usbguard set-parameter ImplicitPolicyTarget block >/dev/null
        undo "usbguard set-parameter ImplicitPolicyTarget $prev"
        ok "new USB devices blocked"
    fi
    if [[ "$STEALTH_ONACCESS_SCAN" == yes ]] && ! systemctl is-active --quiet clamav-clamonacc; then
        # clamd needs ~1 GB RAM for signatures, so it only runs in Stealth Mode
        if systemctl start clamav-daemon clamav-clamonacc 2>/dev/null; then
            undo "systemctl stop clamav-clamonacc clamav-daemon"
            ok "on-access malware scanning on"
        else
            warn "could not start on-access malware scanning"
        fi
    fi
    if [[ "$STEALTH_NEW_MAC" == yes ]] && command -v nmcli >/dev/null; then
        local uuid
        local ctype
        while IFS=: read -r uuid ctype; do
            [[ "$ctype" == *wireless* || "$ctype" == *ethernet* ]] || continue
            nmcli -w 20 connection up "$uuid" >/dev/null 2>&1 || true
        done < <(nmcli -t -f UUID,TYPE connection show --active)
        ok "reconnected with a fresh random MAC"
    fi
    # libvirt turns forwarding on for the Gateway's NAT; turn it back off after
    undo "sysctl -qw net.ipv4.ip_forward=0"
}

host_restore() {
    [[ -r "$STEALTH_UNDO" ]] || return 0
    local cmd
    while IFS= read -r cmd; do
        bash -c "$cmd" || warn "could not undo: $cmd"
    done < <(tac "$STEALTH_UNDO")
    rm -f "$STEALTH_UNDO"
}

# ── VM control ──────────────────────────────────────────────

vm_running() { virsh_ domstate "$1" 2>/dev/null | grep -q running; }

# Stop a VM and *prove* it's gone. Polite shutdown, then hard off, then kill.
vm_stop() {
    local name="$1" t=0
    vm_running "$name" || return 0
    virsh_ shutdown "$name" >/dev/null 2>&1 || true
    while vm_running "$name" && (( t < STEALTH_SHUTDOWN_TIMEOUT )); do
        sleep 1; t=$((t + 1))
    done
    if vm_running "$name"; then
        warn "$name didn't shut down in ${STEALTH_SHUTDOWN_TIMEOUT}s; forcing it off"
        virsh_ destroy "$name" >/dev/null 2>&1 || true
        sleep 1
    fi
    if pgrep -f "guest=$name," >/dev/null; then
        pkill -KILL -f "guest=$name," || true
        sleep 1
    fi
    if vm_running "$name" || pgrep -f "guest=$name," >/dev/null; then
        bad "$name is STILL running"
        return 1
    fi
    ok "$name stopped"
}

wipe_artifacts() {
    local f
    for f in /var/log/libvirt/qemu/"$GW".log* /var/log/libvirt/qemu/"$WS".log* \
             /var/log/swtpm/libvirt/qemu/"$GW"* /var/log/swtpm/libvirt/qemu/"$WS"*; do
        [[ -e "$f" ]] && shred -uz "$f"
    done
    rm -rf /var/lib/libvirt/qemu/channel/target/domain-*-"$GW" \
           /var/lib/libvirt/qemu/channel/target/domain-*-"$WS" 2>/dev/null || true
    sync
    echo 3 > /proc/sys/vm/drop_caches
}

# ── ON / OFF ────────────────────────────────────────────────

# Always-on stylometry/timing guard at Stealth start.
guard_start() {
    local max="${GUARD_START_JITTER:-0}"
    if [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 )); then
        local d=$(( RANDOM % (max + 1) ))
        info "Timing guard: delaying start ${d}s to decorrelate from your real activity"
        sleep "$d"
    fi
    if [[ "${GUARD_STYLO_REMINDER:-yes}" == yes ]]; then
        info "Reminder: run persona text through 'kratos stylo' before posting it."
    fi
}

stealth_on_steps() {
    guard_start
    info "${BOLD}Host lockdown${RESET}"
    host_lockdown

    info "${BOLD}Unlocking stealth vault${RESET}"
    vault_open
    python3 "$HARDEN" check "$VAULT_XML" || die "VM definitions failed the isolation check"
    ok "Workstation can only reach the Gateway"
    [[ -e "$VAULT_MNT/workstation.qcow2" ]] || stealth_reset_overlay

    info "${BOLD}Starting isolated environment${RESET}"
    # QEMU (user libvirt-qemu) creates the display sockets here, and the
    # dedicated kstealth user needs to open them. 0710 root:kstealth: QEMU
    # (root-group member via libvirt) can write, kstealth can enter, and the
    # normal desktop user has no access at all.
    install -d -m 710 -o libvirt-qemu -g "$STEALTH_USER" "$SPICE_DIR"

    nft -f "$STEALTH_NFT" || die "could not load the stealth firewall"
    ok "stealth firewall loaded"
    virsh_ net-create "$VAULT_XML/kx-ext.xml" >/dev/null || die "could not create external network"
    virsh_ net-create "$VAULT_XML/kx-int.xml" >/dev/null || die "could not create internal network"
    virsh_ create "$VAULT_XML/$GW.xml" >/dev/null || die "could not start the Gateway"
    ok "Gateway started (connecting to Tor)"
    virsh_ create "$VAULT_XML/$WS.xml" >/dev/null || die "could not start the Workstation"
    ok "Workstation started"
    give_display "$GW"
    give_display "$WS"
}

# Hand a VM's display socket to the dedicated stealth user ONLY.
#
# This is the heart of the host/persona separation. The persona's screen and
# keyboard are reachable only by kstealth, who owns a separate login session
# on its own VT (a cage kiosk run by kratos-stealth-seat@.service). Malware as your normal
# desktop user is a different uid with no access to this socket, so it cannot
# watch the persona or inject keystrokes. (A root compromise still wins; that
# is the limit short of a Qubes-style hypervisor. See docs/THREAT_MODEL.md.)
give_display() {
    local sock="$SPICE_DIR/$1.sock" t=0
    while [[ ! -S "$sock" ]] && (( t < 10 )); do sleep 1; t=$((t + 1)); done
    [[ -S "$sock" ]] || { warn "display socket for $1 not found"; return 0; }
    chown "root:$STEALTH_USER" "$sock"
    # 0660: connecting to a UNIX socket needs write, so the kstealth group gets
    # read+write. "Other" (your normal desktop user) gets nothing.
    chmod 0660 "$sock"
}

stealth_on() {
    need_root stealth on
    load_config
    need_cmd virsh cryptsetup nft python3
    stealth_is_active && die "Stealth Mode is already on"
    [[ -e "$VAULT_IMG" ]] || die "Stealth Mode isn't set up yet; run: sudo kratos stealth setup <Whonix archive>"
    if [[ "$STEALTH_REQUIRE_VPN" == yes && "$(saved_mode)" != vpn ]]; then
        die "STEALTH_REQUIRE_VPN=yes but network mode is '$(saved_mode)'; run: sudo kratos mode vpn"
    fi
    [[ "$(saved_mode)" == offline ]] && warn "network mode is offline; the Gateway won't reach Tor"
    systemctl is-active --quiet libvirtd || systemctl start libvirtd

    [[ "${1:-}" == --passphrase-stdin ]] && read_stdin_pass
    install -d -m 755 "$KRATOS_RUN"
    date -u +%s > "$STEALTH_FLAG"

    info "${BOLD}Stealth Mode: ON${RESET}"
    set +e
    ( set -e; stealth_on_steps )
    local rc=$?
    set -e
    if (( rc != 0 )); then
        err "starting Stealth Mode failed; rolling back"
        stealth_off_steps || true
        exit 1
    fi
    info ""
    info "Open the stealth desktop: kratos stealth view"
}

stealth_off_steps() {
    local failed=0
    info "${BOLD}Stopping isolated environment${RESET} (Workstation first)"
    vm_stop "$WS" || failed=1
    if (( failed )); then
        # Never take the Gateway away from a Workstation that is still running,
        # or the Workstation would sit without Tor while holding persona data.
        err "the Workstation could not be stopped; leaving Gateway and vault as they are"
        return 1
    fi
    vm_stop "$GW" || failed=1

    virsh_ net-destroy kx-int >/dev/null 2>&1 || true
    virsh_ net-destroy kx-ext >/dev/null 2>&1 || true
    nft delete table inet kratos_stealth 2>/dev/null || true
    rm -rf "$SPICE_DIR"
    ok "stealth networks and firewall removed"

    if [[ "${STEALTH_WORKSTATION:-persistent}" == disposable ]] && mountpoint -q "$VAULT_MNT"; then
        stealth_reset_overlay && ok "Workstation reset to clean image (disposable)"
    fi

    info "${BOLD}Wiping artifacts and locking vault${RESET}"
    wipe_artifacts
    ok "VM logs shredded, caches dropped"
    if vault_close; then ok "vault locked"; else failed=1; fi

    info "${BOLD}Restoring normal host${RESET}"
    host_restore
    ok "host restored"
    rm -f "$STEALTH_FLAG"
    return "$failed"
}

stealth_off() {
    need_root stealth off
    load_config
    if ! stealth_is_active && ! vault_is_open; then
        info "Stealth Mode is already off."
        return 0
    fi
    info "${BOLD}Stealth Mode: OFF${RESET}"
    stealth_off_steps || die "Stealth Mode did not shut down cleanly; see above. If in doubt: kratos panic"
}

# For `kratos panic`: no politeness, just get everything down.
stealth_kill() {
    virsh_ destroy "$WS" >/dev/null 2>&1 || true
    virsh_ destroy "$GW" >/dev/null 2>&1 || true
    pkill -KILL -f "guest=kx-" 2>/dev/null || true
    rm -rf "$SPICE_DIR"
    umount -l "$VAULT_MNT" 2>/dev/null || true
    cryptsetup close "$VAULT_MAPPER" 2>/dev/null || true
}

# Open the persona display. The viewer runs as kstealth in its own session,
# NOT in the caller's desktop session, so the persona's window never shares a
# compositor, clipboard or input path with normal-mode programs. The tray
# triggers this through the org.kratos.view polkit action.
stealth_view() {
    local vm="${1:-workstation}" name="$WS"
    [[ "$vm" == gateway ]] && name="$GW"
    need_root stealth view
    stealth_is_active || die "Stealth Mode is off"
    [[ -S "$SPICE_DIR/$name.sock" ]] || die "no display socket for $vm"
    # kratos-stealth-seat@.service runs a cage (kiosk Wayland) session for kstealth on its own VT;
    # launch the viewer into that session's bus, locked to this one socket.
    if ! loginctl --no-legend list-sessions 2>/dev/null | grep -qw "$STEALTH_USER"; then
        info "Starting the isolated stealth session (switch VTs with Ctrl+Alt+F2)..."
        systemctl start "kratos-stealth-seat@${name}.service" \
            || die "could not start the isolated stealth session"
        return 0
    fi
    runuser -u "$STEALTH_USER" -- \
        remote-viewer --title "KratosOS Stealth: $vm" \
        "spice+unix://$SPICE_DIR/$name.sock" >/dev/null 2>&1 &
    disown
}

stealth_reset() {
    need_root stealth reset
    load_config
    stealth_is_active && die "turn Stealth Mode off first"
    confirm "Erase everything in the Workstation and restore a clean image?" || exit 0
    vault_open
    stealth_reset_overlay
    vault_close
    ok "Workstation reset"
}

stealth_status() {
    info "${BOLD}Stealth Mode:${RESET} $(stealth_is_active && echo ON || echo off)"
    if [[ ! -e "$VAULT_IMG" ]]; then
        info "  not set up (sudo kratos stealth setup <Whonix archive>)"
        return 0
    fi
    if vault_is_open; then ok "vault unlocked"; else info "  vault locked"; fi
    if stealth_is_active; then
        local d
        for d in "$GW" "$WS"; do
            if vm_running "$d"; then ok "$d running"; else bad "$d not running"; fi
        done
        if nft list table inet kratos_stealth >/dev/null 2>&1; then
            ok "stealth firewall loaded"
        else
            bad "stealth firewall NOT loaded"
        fi
        if [[ -d "$VAULT_XML" ]] && python3 "$HARDEN" check "$VAULT_XML" 2>/dev/null; then
            ok "isolation check passed"
        fi
    fi
}

stealth_main() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        on)     stealth_on "$@" ;;
        off)    stealth_off "$@" ;;
        toggle) if stealth_is_active; then stealth_off; else stealth_on "$@"; fi ;;
        status) stealth_status ;;
        view)   stealth_view "$@" ;;
        setup)  stealth_setup "$@" ;;
        reset)  stealth_reset ;;
        *) die "usage: kratos stealth {on|off|toggle|status|view|setup|reset}" ;;
    esac
}
