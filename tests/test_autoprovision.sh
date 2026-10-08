#!/usr/bin/env bash
# Zero-touch Stealth provisioning: latest-image discovery, the signature-gated
# download, the provisioned check, and the auto-provision gating. Live network
# and real cryptsetup/qemu are mocked — this exercises the LOGIC, not a real
# Whonix download.
#
# curl/verify_whonix/_stealth_provision/saved_mode/need_cmd are stubbed and read
# back via the sourced library, which the linter can't see:
# shellcheck disable=SC1091,SC2034,SC2317,SC2329,SC2015,SC2030,SC2031
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

load() {
    tmp="$(mktemp -d)"
    export KRATOS_LIB="$lib" KRATOS_ETC="$tmp/etc" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run"
    mkdir -p "$KRATOS_ETC" "$KRATOS_STATE" "$KRATOS_RUN"
    : > "$KRATOS_ETC/whonix-signing-key.asc"     # presence is enough; verify is stubbed
    # shellcheck source=/dev/null
    . "$lib/common.sh"; . "$lib/net.sh"; . "$lib/stealth.sh"
}

echo "— _whonix_pick_latest chooses the newest image —"
(
    load
    idx="$tmp/idx.html"
    cat > "$idx" <<'HTML'
<a href="Whonix-Xfce-17.3.0.1.Intel_AMD64.qcow2.libvirt.xz">old</a>
<a href="Whonix-Xfce-17.4.9.7.Intel_AMD64.qcow2.libvirt.xz">new</a>
<a href="Whonix-Xfce-17.3.9.9.Intel_AMD64.qcow2.libvirt.xz">mid</a>
<a href="Whonix-CLI-17.5.0.0.Intel_AMD64.qcow2.libvirt.xz">wrong flavor</a>
HTML
    url="$(_whonix_pick_latest "$idx" "https://dl.example/libvirt/" Xfce)"
    [[ "$url" == "https://dl.example/libvirt/Whonix-Xfce-17.4.9.7.Intel_AMD64.qcow2.libvirt.xz" ]]
) && pass "picks the highest version of the chosen flavor" \
  || flunk "wrong latest-image selection"

echo "— stealth_fetch_whonix downloads image + .asc via (mocked) curl —"
out="$(
    load
    export STEALTH_WHONIX_BASEURL="https://dl.example/libvirt/"
    # Mock curl: find -o <file> and the URL (last arg); serve index or dummy data.
    curl() {
        local ofile="" url=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -o) ofile="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
        done
        if [[ "$url" == */libvirt/ ]]; then
            echo '<a href="Whonix-Xfce-17.4.0.0.Intel_AMD64.qcow2.libvirt.xz">x</a>' > "$ofile"
        else
            echo "dummy-$(basename "$url")" > "$ofile"
        fi
    }
    arc="$(stealth_fetch_whonix "$tmp/dl")"
    [[ -f "$arc" && -f "$arc.asc" ]] && echo "OK:$(basename "$arc")"
)"
if [[ "$out" == "OK:Whonix-Xfce-17.4.0.0.Intel_AMD64.qcow2.libvirt.xz" ]]; then
    pass "fetches the discovered image and its signature"
else
    flunk "fetch did not produce image + .asc ($out)"
fi

echo "— STEALTH_WHONIX_URL override skips discovery —"
out="$(
    load
    export STEALTH_WHONIX_URL="https://pin.example/W.libvirt.xz"
    hits=0
    curl() {
        local ofile="" url=""
        while [[ $# -gt 0 ]]; do case "$1" in -o) ofile="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
        case "$url" in */) echo INDEX > "$ofile"; echo "index-fetched" >&2 ;; *) echo d > "$ofile" ;; esac
    }
    stealth_fetch_whonix "$tmp/dl2" >/dev/null 2>"$tmp/err"
    grep -q index-fetched "$tmp/err" && echo "DISCOVERED" || echo "PINNED"
)"
[[ "$out" == PINNED ]] && pass "a pinned URL is used directly (no index fetch)" \
    || flunk "pinned URL still triggered discovery"

echo "— stealth_is_provisioned requires the key in amnesic mode —"
(
    load
    : > "$VAULT_IMG"                       # vault image exists
    ! stealth_is_provisioned || exit 1     # but no ephemeral key yet -> not provisioned
    stealth_make_ephemeral_key
    stealth_is_provisioned                 # now provisioned
) && pass "amnesic: provisioned only once the in-RAM key exists" \
  || flunk "provisioned check wrong for amnesic mode"

echo "— autoprovision refuses when disabled / offline —"
out="$( ( load; export STEALTH_AUTOPROVISION=no
          saved_mode() { echo normal; }
          stealth_autoprovision ) 2>&1 )"; rc=$?
if (( rc != 0 )) && grep -qi "AUTOPROVISION=no\|isn't set up" <<<"$out"; then
    pass "STEALTH_AUTOPROVISION=no refuses auto-provision"
else
    flunk "disabled auto-provision did not refuse (rc=$rc): $out"
fi
out="$( ( load; export STEALTH_AUTOPROVISION=yes
          saved_mode() { echo offline; }
          stealth_autoprovision ) 2>&1 )"; rc=$?
if (( rc != 0 )) && grep -qi "offline" <<<"$out"; then
    pass "offline refuses auto-provision"
else
    flunk "offline auto-provision did not refuse (rc=$rc): $out"
fi

echo "— autoprovision happy path fetches, verifies, provisions —"
(
    load
    export STEALTH_AUTOPROVISION=yes
    saved_mode() { echo normal; }
    need_cmd() { :; }
    stealth_fetch_whonix() { echo "$tmp/fake.libvirt.xz"; }
    verify_whonix() { echo "verify $*" >> "$tmp/calls"; }
    _stealth_provision() { echo "provision $1" >> "$tmp/calls"; }
    stealth_autoprovision >/dev/null 2>&1
    grep -q "^verify " "$tmp/calls" && grep -q "^provision $tmp/fake.libvirt.xz" "$tmp/calls"
) && pass "verifies the download, then provisions" \
  || flunk "autoprovision did not verify+provision in order"

exit "$fail"
