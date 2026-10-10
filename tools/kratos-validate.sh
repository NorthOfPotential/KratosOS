#!/usr/bin/env bash
# kratos-validate.sh — one script to validate KratosOS end-to-end on your PC.
#
# It does the things that can only be proven on real hardware/VMs (which a cloud
# assistant can't do): get the built ISO, boot it, and run the live isolation
# checks — then writes a report you can paste back.
#
# Two places it runs:
#   * ON YOUR DEV BOX (Linux with KVM): phases  deps | fetch | build | boot
#   * INSIDE A BOOTED KratosOS (live USB, the QEMU VM this script boots, or an
#     install): phase  probe   — the actual security checks (vault ACL, sVirt,
#     offline rfkill, firewall). It refuses to run `probe` anywhere else.
#
# Quick start on your dev box:
#     curl -fsSL https://raw.githubusercontent.com/NorthOfPotential/KratosOS/main/tools/kratos-validate.sh -o kratos-validate.sh
#     chmod +x kratos-validate.sh
#     ./kratos-validate.sh all        # deps, source tests, fetch-or-build ISO, boot it
#
# Then, in the KratosOS window that opens, open a terminal and run:
#     curl -fsSL https://raw.githubusercontent.com/NorthOfPotential/KratosOS/main/tools/kratos-validate.sh | bash -s -- probe
#
# Everything lands in ./kratos-validate/out/. `./kratos-validate.sh report`
# bundles it into one file to send back.
set -uo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
OWNER="NorthOfPotential"
REPO_NAME="KratosOS"
REPO_URL="https://github.com/${OWNER}/${REPO_NAME}"
RAW_URL="https://raw.githubusercontent.com/${OWNER}/${REPO_NAME}/main"
BRANCH="main"
WORK="${KRATOS_VALIDATE_WORK:-$PWD/kratos-validate}"
OUT="$WORK/out"
SRC="$WORK/src"          # repo clone (dev-box side)
ISO_GLOB="kratosos-*.iso"

b() { printf '\033[1m%s\033[0m\n' "$*"; }
say() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
mkout() { mkdir -p "$OUT"; }

on_kratos() { [[ -x /usr/local/bin/kratos ]]; }

# ── deps: install the host-side tooling (Debian/Ubuntu) ───────────────────────
phase_deps() {
    b "[deps] host tooling for build/boot"
    if ! have apt-get; then
        warn "not a Debian/Ubuntu host — install these yourself: git gh qemu-system-x86 qemu-utils shellcheck nftables python3 jq curl socat"
        return 0
    fi
    local pkgs=(git qemu-system-x86 qemu-utils ovmf shellcheck nftables python3 jq curl socat ca-certificates)
    say "installing: ${pkgs[*]}"
    if sudo apt-get update -y && sudo apt-get install -y "${pkgs[@]}"; then :; else warn "some packages failed to install"; fi
    if ! have gh; then
        warn "GitHub CLI 'gh' is not installed (needed for 'fetch'). Install it:"
        warn "  https://github.com/cli/cli/blob/trunk/docs/install_linux.md   then run:  gh auth login"
    fi
    [[ -e /dev/kvm ]] || warn "/dev/kvm is missing — QEMU will be slow and NESTED VMs (Whonix) won't run. Use a bare-metal Linux box with VT-x/AMD-V."
}

# ── clone/refresh the repo (dev-box side) ─────────────────────────────────────
ensure_src() {
    have git || die "git is required (run: $0 deps)"
    if [[ -d "$SRC/.git" ]]; then
        git -C "$SRC" fetch --quiet origin "$BRANCH" && git -C "$SRC" reset --hard "origin/$BRANCH" --quiet
    else
        mkdir -p "$WORK"
        git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC"
    fi
    say "source at $SRC ($(git -C "$SRC" rev-parse --short HEAD))"
}

# ── tests: run the source test suite ──────────────────────────────────────────
phase_tests() {
    b "[tests] source test suite (shellcheck, firewall/isolation, qubes, migration…)"
    mkout; ensure_src
    local log="$OUT/tests.log"
    # The namespace/firewall tests need root; create the users they expect.
    if [[ $(id -u) -eq 0 ]] || have sudo; then
        local SUDO=""; [[ $(id -u) -ne 0 ]] && SUDO="sudo"
        $SUDO groupadd -r kstealth 2>/dev/null || true
        $SUDO useradd -r -g kstealth -s /usr/sbin/nologin kstealth 2>/dev/null || true
        $SUDO useradd -m mallory 2>/dev/null || true
        $SUDO useradd -r kratos-nym 2>/dev/null || true
        ( cd "$SRC" && $SUDO ATTACKER=mallory tests/run.sh ) 2>&1 | tee "$log"
    else
        ( cd "$SRC" && tests/run.sh ) 2>&1 | tee "$log"
    fi
    if grep -q "ALL CHECKS PASSED" "$log"; then say "RESULT: source tests PASSED"; else warn "RESULT: source tests reported failures (see $log)"; fi
}

# ── fetch: download the ISO the GitHub build-iso job produced ─────────────────
phase_fetch() {
    b "[fetch] download the ISO artifact from GitHub Actions"
    mkout
    have gh || die "GitHub CLI 'gh' not found. Install it and 'gh auth login', or use '$0 build' to build locally."
    gh auth status >/dev/null 2>&1 || die "run 'gh auth login' first (needs read access to $OWNER/$REPO_NAME)."
    say "looking for the most recent successful build-iso run…"
    # Newest completed workflow_dispatch/tag run that actually has the artifact.
    local rid
    rid="$(gh run list --repo "$OWNER/$REPO_NAME" --workflow ci.yml --status success \
            --json databaseId,createdAt --jq 'sort_by(.createdAt)|reverse|.[0].databaseId' 2>/dev/null)"
    [[ -n "$rid" ]] || die "no successful CI run found yet. The build may still be running or may have failed — check:
     $REPO_URL/actions
   If the ISO build failed, use '$0 build' to build locally instead."
    say "downloading artifact 'kratosos-iso' from run $rid …"
    if ! gh run download "$rid" --repo "$OWNER/$REPO_NAME" -n kratosos-iso -D "$OUT" 2>"$OUT/fetch.log"; then
        cat "$OUT/fetch.log" >&2
        die "that run had no 'kratosos-iso' artifact (the ISO build job may have failed or been skipped).
   See $REPO_URL/actions/runs/$rid  — or build locally with '$0 build'."
    fi
    _verify_iso
}

_verify_iso() {
    local iso; iso="$(find "$OUT" -maxdepth 1 -name "$ISO_GLOB" | head -n1)"
    [[ -n "$iso" ]] || die "no ISO found in $OUT"
    say "ISO: $iso ($(du -h "$iso" | cut -f1))"
    if [[ -f "$OUT/SHA256SUMS" ]]; then
        if ( cd "$OUT" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
            say "checksum OK (SHA256SUMS)"
        else
            warn "checksum MISMATCH — do not trust this ISO"
        fi
    fi
    if have gh; then
        if gh attestation verify "$iso" -R "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
            say "build provenance attestation VERIFIED (built by $OWNER/$REPO_NAME CI)"
        else
            warn "could not verify build provenance attestation (ok if offline / older gh)"
        fi
    fi
    printf '%s\n' "$iso" > "$OUT/.iso-path"
}

# ── build: local fallback ISO build (Debian/Ubuntu, needs live-build) ─────────
phase_build() {
    b "[build] build the ISO locally with live-build (fallback if CI didn't produce one)"
    mkout; ensure_src
    [[ $(id -u) -eq 0 ]] || have sudo || die "need root or sudo to run live-build"
    local SUDO=""; [[ $(id -u) -ne 0 ]] && SUDO="sudo"
    if ! have lb; then
        if have apt-get; then say "installing live-build…"; $SUDO apt-get install -y live-build debootstrap xorriso squashfs-tools dosfstools mtools || die "could not install live-build";
        else die "live-build (lb) not found and no apt — build on a Debian/Ubuntu box, or just use '$0 fetch'."; fi
    fi
    say "building (this takes 15–40 min and ~10 GB of disk)…"
    ( cd "$SRC" && $SUDO ./build.sh ) 2>&1 | tee "$OUT/build.log"
    local iso; iso="$(find "$SRC" -maxdepth 1 -name "$ISO_GLOB" | head -n1)"
    [[ -n "$iso" ]] || die "build finished but no ISO was produced (see $OUT/build.log)"
    cp -f "$iso" "$OUT"/ && ( cd "$SRC" && sha256sum "$(basename "$iso")" > "$OUT/SHA256SUMS" )
    _verify_iso
}

# ── boot: boot the ISO in QEMU so you can see it come up ──────────────────────
phase_boot() {
    b "[boot] boot the ISO in QEMU (live session) and capture proof-of-boot"
    mkout
    have qemu-system-x86_64 || die "qemu-system-x86_64 not found (run: $0 deps)"
    local iso; iso="$(cat "$OUT/.iso-path" 2>/dev/null || true)"
    [[ -n "$iso" && -f "$iso" ]] || iso="$(find "$OUT" -maxdepth 1 -name "$ISO_GLOB" | head -n1)"
    [[ -n "$iso" ]] || die "no ISO in $OUT — run '$0 fetch' or '$0 build' first"

    local kvm=() ; if [[ -e /dev/kvm ]]; then kvm=(-enable-kvm -cpu host); else warn "no /dev/kvm: slow TCG emulation, no nested VMs"; kvm=(-cpu max); fi
    say "ISO:  $iso"
    say "A window opens (SPICE/GTK). Watch it reach the KratosOS desktop."
    say "Serial log: $OUT/serial.log   (VNC also on :1 → 127.0.0.1:5901)"
    say "Give it RAM for the inner Whonix VMs if you'll test Stealth (6–8 GB)."
    local mem="${KRATOS_VM_MEM:-6144}"
    local display=(-display gtk)
    have qemu-system-x86_64 && qemu-system-x86_64 -display help 2>/dev/null | grep -q spice-app && display=(-display spice-app)
    # Headless override: KRATOS_HEADLESS=1 → no window, VNC only (for servers).
    [[ "${KRATOS_HEADLESS:-0}" == 1 ]] && display=(-display none)

    ( set -x
      qemu-system-x86_64 "${kvm[@]}" -m "$mem" -smp "$(nproc 2>/dev/null || echo 2)" \
        -machine q35 \
        -drive file="$iso",media=cdrom,readonly=on -boot d \
        -nic user,model=virtio-net-pci \
        -vga virtio "${display[@]}" -vnc :1 \
        -serial file:"$OUT/serial.log" \
        -monitor unix:"$OUT/mon.sock",server,nowait ) 2>>"$OUT/boot.log" &
    local qpid=$!
    say "QEMU pid $qpid. Take a screenshot after it boots with:"
    say "    printf 'screendump $OUT/screen.ppm\\n' | socat - UNIX-CONNECT:$OUT/mon.sock"
    say "Close the QEMU window (or: kill $qpid) when done."
    wait "$qpid" 2>/dev/null || true
}

# ── probe: the REAL security checks — run INSIDE a booted KratosOS ─────────────
phase_probe() {
    local rpt="$PWD/kratos-probe-report.txt"
    b "[probe] live isolation checks (run this INSIDE a booted KratosOS)"
    if ! on_kratos; then
        die "this is the GUEST phase: run it inside a booted KratosOS (the QEMU window, a live USB, or an install).
   There, open a terminal and run:
     curl -fsSL $RAW_URL/tools/kratos-validate.sh | bash -s -- probe"
    fi
    local SUDO=""; [[ $(id -u) -ne 0 ]] && SUDO="sudo"
    local stealth=0; [[ "${1:-}" == "--stealth" ]] && stealth=1

    {
        echo "KratosOS live probe — $(date -u +%FT%TZ)"
        echo "kernel: $(uname -a)"
        echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
        echo "=================================================================="

        echo; echo "### kratos status"
        $SUDO kratos status 2>&1 || true

        echo; echo "### firewall table present?"
        $SUDO nft list table inet kratos >/dev/null 2>&1 && echo "PASS: inet kratos table loaded" || echo "FAIL: no inet kratos table"

        echo; echo "### offline mode → layer-1 radio/link shutdown (R9–R13)"
        $SUDO kratos mode offline 2>&1 || true
        sleep 2
        for t in wifi bluetooth wwan; do
            if command -v rfkill >/dev/null 2>&1; then
                echo "rfkill $t:"; rfkill list "$t" 2>/dev/null | sed 's/^/    /' || true
            fi
        done
        echo "physical links:"; ip -brief link 2>/dev/null | sed 's/^/    /'
        echo "(expect Wi-Fi/Bluetooth/WWAN 'Soft blocked: yes' and physical NICs DOWN)"
        $SUDO kratos mode normal 2>&1 || true

        if (( stealth )); then
            echo; echo "### STEALTH ON (downloads+verifies Whonix ~1GB; needs nested KVM) …"
            $SUDO kratos stealth on 2>&1 || echo "(stealth on failed — see above; common in nested-virt or offline)"
            echo; echo "### vault QEMU-traversal ACL (R8-1)"
            echo "getfacl on the vault mount:"
            $SUDO getfacl -p /var/lib/kratos/vault 2>/dev/null | sed 's/^/    /' || true
            echo; echo "### THE sVirt CROSS-DISK TEST (DAC can't do this; AppArmor/sVirt must)"
            echo "try to read the Gateway disk as the Workstation's QEMU user:"
            $SUDO -u libvirt-qemu cat /var/lib/kratos/vault/gateway.qcow2 >/dev/null 2>&1
            echo "    libvirt-qemu read gateway.qcow2 exit=$?  (want NON-zero / denied)"
            echo; echo "### AppArmor / sVirt state"
            $SUDO aa-status 2>/dev/null | grep -iE 'libvirt|qemu' | sed 's/^/    /' || echo "    (aa-status unavailable)"
            echo "recent AppArmor denials:"
            $SUDO journalctl -k --no-pager 2>/dev/null | grep -i 'apparmor=\"DENIED\"' | tail -n 20 | sed 's/^/    /' || true
            echo; echo "### STEALTH OFF"
            $SUDO kratos stealth off 2>&1 || true
        else
            echo; echo "### (skipped Stealth/Whonix/sVirt test — re-run with: probe --stealth)"
            echo "    That phase downloads Whonix and starts nested VMs, so run it on"
            echo "    bare metal or a host with working nested virtualization."
        fi
        echo; echo "=== probe complete ==="
    } 2>&1 | tee "$rpt"
    b "wrote $rpt — send me that file."
}

# ── report: bundle everything to send back ────────────────────────────────────
phase_report() {
    mkout
    local tb="$WORK/kratos-validate-report.tar.gz"
    [[ -f "$PWD/kratos-probe-report.txt" ]] && cp -f "$PWD/kratos-probe-report.txt" "$OUT/" 2>/dev/null || true
    tar -czf "$tb" -C "$OUT" . 2>/dev/null || die "nothing to bundle yet"
    b "bundled: $tb"
    say "send me that file (or paste the .log/.txt/.ppm contents inside)."
}

usage() {
    cat <<EOF
kratos-validate.sh — validate KratosOS end-to-end.

ON YOUR DEV BOX (Linux + KVM):
  $0 deps          install host tooling (Debian/Ubuntu)
  $0 tests         run the source test suite
  $0 fetch         download the CI-built ISO (needs: gh auth login)
  $0 build         build the ISO locally instead (needs live-build)
  $0 boot          boot the ISO in QEMU so you can see it come up
  $0 all           deps → tests → fetch (or build) → boot
  $0 report        bundle ./kratos-validate/out into one file to send back

INSIDE A BOOTED KratosOS (the QEMU window / live USB / install):
  $0 probe [--stealth]   run the live isolation checks → kratos-probe-report.txt

Env: KRATOS_VM_MEM=6144  KRATOS_HEADLESS=0  KRATOS_VALIDATE_WORK=$PWD/kratos-validate
EOF
}

main() {
    case "${1:-all}" in
        deps) phase_deps ;;
        tests) phase_tests ;;
        fetch) phase_fetch ;;
        build) phase_build ;;
        boot) phase_boot ;;
        probe) shift || true; phase_probe "${1:-}" ;;
        report) phase_report ;;
        all)
            phase_deps
            phase_tests
            # Run fetch in a subshell so its die() can't abort 'all'; fall back to build.
            if ( phase_fetch ); then :; else warn "fetch did not get an ISO; trying a local build…"; phase_build; fi
            phase_boot
            ;;
        -h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
}
main "$@"
