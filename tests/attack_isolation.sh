#!/usr/bin/env bash
# Stubs and helpers below are invoked indirectly (sourced library code,
# runuser), which the linter cannot see.
# shellcheck disable=SC1091,SC2034,SC2317,SC2329
# Simulated attack: malware running as your NORMAL desktop user tries to reach
# the Stealth Mode persona. Every attack must fail.
#
# This drives the real stealth.sh code (crypto, mount, libvirt and QEMU are
# mocked, but every chown/chmod/install that sets a permission is the real
# code path), brings Stealth Mode "up", then drops to an unprivileged attacker
# user and attempts each attack. A PASS means the attack was blocked.
#
# Run as root:  sudo tests/attack_isolation.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
ATTACKER="${ATTACKER:-mallory}"
STEALTH_USER="${STEALTH_USER:-kstealth}"
fail=0
LISTENERS=()

[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 2; }
id "$ATTACKER"    >/dev/null 2>&1 || { echo "SKIP: no attacker user '$ATTACKER'"; exit 0; }
id "$STEALTH_USER" >/dev/null 2>&1 || { echo "SKIP: no '$STEALTH_USER' user"; exit 0; }

tmp="$(mktemp -d)"
chmod 755 "$tmp"
cleanup() { kill "${LISTENERS[@]}" 2>/dev/null; umount "$tmp/state/vault" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

export KRATOS_ETC="$tmp/etc" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run" KRATOS_LIB="$lib"
export STAGE_TOOL="$tmp/bin/kratos"
mkdir -p "$KRATOS_ETC" "$KRATOS_STATE" "$KRATOS_RUN"

# ── Bring Stealth Mode "up" using the real permission code ─────────────────
# Mock only the things that need real hardware/daemons. vault_open's mount is
# replaced by a tmpfs mount so the real chmod/chown on the mountpoint runs.
build_live_system() {
    # shellcheck source=/dev/null
    . "$lib/common.sh"; . "$lib/net.sh"; . "$lib/stealth.sh"
    
    # --- mocks (only hardware/daemon calls) ---
    cryptsetup_pass() { return 0; }
    vault_is_open() { mountpoint -q "$VAULT_MNT"; }
    mount() { command mount -t tmpfs none "$VAULT_MNT"; }  # real mountpoint, real perms
    load_config() { STEALTH_REQUIRE_VPN=no; STEALTH_WORKSTATION=persistent; }
    need_cmd() { :; }
    need_root() { :; }
    host_lockdown() { : > "$STEALTH_UNDO"; chmod 600 "$STEALTH_UNDO"; }
    nft() { :; }
    systemctl() { :; }
    python3() { return 0; }
    date() { echo 1700000000; }
    # libvirt + qemu: start a real listening socket where QEMU would, as root
    # (QEMU runs as root-group libvirt-qemu). It LISTENS, so the only barrier
    # a client hits is filesystem permission — exactly what we're testing.
    virsh_() {
        case "$1" in
            create|net-create)
                local f; f="$(basename "$2" .xml)"
                case "$f" in kx-gw|kx-ws)
                    command python3 "$here/_mock_spice_listener.py" "$SPICE_DIR/$f.sock" &
                    LISTENERS+=($!)
                    while [[ ! -S "$SPICE_DIR/$f.sock" ]]; do sleep 0.05; done ;;
                esac ;;
        esac
        return 0
    }

    install -d -m 755 "$KRATOS_STATE"  # matches the hook: /var/lib/kratos is 0755
    : > "$VAULT_IMG"; chmod 600 "$VAULT_IMG"
    date > "$STEALTH_FLAG"
    vault_open
    # Populate the vault as setup would: VM disks and definitions, root-only.
    install -d -m 700 "$VAULT_XML"
    echo "PERSONA DISK (secret filesystem)" > "$VAULT_MNT/workstation.qcow2"
    echo "PERSONA DISK (secret filesystem)" > "$VAULT_MNT/gateway.qcow2"
    echo "<domain/>" > "$VAULT_XML/kx-ws.xml"
    chmod 600 "$VAULT_MNT"/*.qcow2 "$VAULT_XML"/*.xml 
    install -d -m 710 -o root -g "$STEALTH_USER" "$SPICE_DIR"
    virsh_ create "$VAULT_XML/kx-gw.xml"
    virsh_ create "$VAULT_XML/kx-ws.xml"
    give_display kx-gw; give_display kx-ws
    # secret the attacker wants: the LUKS passphrase, if it ever hit disk
    install -m 644 /dev/null "$KRATOS_ETC/kratos.conf"
    echo "STEALTH_DISABLE_SWAP=yes" > "$KRATOS_ETC/kratos.conf"
    echo "correct horse battery staple" > "$STEALTH_UNDO.secret"
    chmod 600 "$STEALTH_UNDO.secret"
    # A stand-in for the installed kratos tool, root-owned, to test that
    # attacker malware cannot replace it (without writing into the repo).
    install -d -m 755 "$tmp/bin"
    install -m 755 /dev/null "$tmp/bin/kratos"
    echo "#!/bin/sh" > "$tmp/bin/kratos"
}


build_live_system

echo "Stealth Mode is up. Threat model: an UNPRIVILEGED attacker '$ATTACKER'"
echo "(malware running as your normal desktop user). A root/hypervisor"
echo "compromise is explicitly OUT OF SCOPE here — that is the Qubes tier's job."
echo

# ── Attack helpers ─────────────────────────────────────────────────────────
# Run a command as the attacker; returns its exit status.
as_attacker() { runuser -u "$ATTACKER" -- "$@"; }
# Try to connect to a UNIX socket as a given user, using an INLINE program so
# the result depends only on the socket's permissions — never on whether that
# user can traverse the repo checkout to read a script file. (On CI the repo
# lives under a path system users can't traverse; reading a probe script there
# would make every "blocked" check pass vacuously.)
connect_as() { # $1 user  $2 socket-path
    runuser -u "$1" -- python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1]); print("CONNECTED")
except OSError as e:
    sys.exit(1)' "$2"
}
# A blocked attack: command fails OR produces no secret output.
blocked() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  FAIL  $desc  (attack SUCCEEDED — this is a leak)"; fail=1
    else
        echo "  PASS  $desc"
    fi
}
# An attack that must not find the secret string in its output.
no_secret() {
    local desc="$1"; shift
    local out; out="$("$@" 2>/dev/null)"
    if grep -q "PERSONA DISK\|correct horse battery staple" <<<"$out"; then
        echo "  FAIL  $desc  (secret LEAKED)"; fail=1
    else
        echo "  PASS  $desc"
    fi
}

echo "— Attacks on the vault (persona filesystem) —"
no_secret "read the mounted Workstation disk"      as_attacker cat "$KRATOS_STATE/vault/workstation.qcow2"
no_secret "read the Gateway disk"                  as_attacker cat "$KRATOS_STATE/vault/gateway.qcow2"
blocked  "list the vault directory"                as_attacker ls "$KRATOS_STATE/vault"
no_secret "read the encrypted vault image"         as_attacker cat "$KRATOS_STATE/stealth.vault"
no_secret "grep secrets out of the vault image"    as_attacker grep -a "horse battery" "$KRATOS_STATE/stealth.vault"

echo "— Attacks on the persona display (watch screen / inject keys) —"
blocked  "open the Workstation SPICE socket"       connect_as "$ATTACKER" "$KRATOS_RUN/spice/kx-ws.sock"
blocked  "open the Gateway SPICE socket"           connect_as "$ATTACKER" "$KRATOS_RUN/spice/kx-gw.sock"
blocked  "enter the SPICE socket directory"        as_attacker ls "$KRATOS_RUN/spice"

echo "— Attacks on secrets and control files —"
no_secret "read the host-lockdown undo log"        as_attacker cat "$KRATOS_RUN/stealth.undo"
no_secret "read the stashed passphrase file"       as_attacker cat "$KRATOS_RUN/stealth.undo.secret"

echo "— Tampering attacks (subvert isolation for next start) —"
blocked  "overwrite a VM definition"               as_attacker sh -c "echo pwned > '$KRATOS_STATE/vault/libvirt/kx-ws.xml'"
blocked  "drop a malicious VM definition"          as_attacker sh -c "echo evil > '$KRATOS_STATE/vault/libvirt/evil.xml'"
blocked  "rewrite kratos.conf to disable lockdown" as_attacker sh -c "echo STEALTH_DISABLE_SWAP=no >> '$KRATOS_ETC/kratos.conf'"
blocked  "replace the kratos tool"                 as_attacker sh -c "echo '#!/bin/sh' > '$STAGE_TOOL'"

echo "— Positive control: the intended user CAN use the display —"
if connect_as "$STEALTH_USER" "$KRATOS_RUN/spice/kx-ws.sock" >/dev/null 2>&1; then
    echo "  PASS  $STEALTH_USER can open the persona display (isolation is not vacuous)"
else
    echo "  FAIL  $STEALTH_USER CANNOT open the display — Stealth Mode would be unusable"; fail=1
fi

echo
if (( fail )); then echo "ISOLATION BREACHED — see FAIL lines above"; else echo "ALL UNPRIVILEGED-ATTACKER ATTACKS BLOCKED (root/hypervisor compromise out of scope)"; fi
exit "$fail"
