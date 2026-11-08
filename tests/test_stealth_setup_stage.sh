#!/usr/bin/env bash
# `kratos stealth setup <archive>`: the archive usually lives in a user-writable
# folder. Verifying it there and then extracting it again BY PATH was a
# verify-then-use race: anything running as the desktop user could swap in an
# unsigned image after the signature check and before the root extraction.
# setup must copy archive + signature into a root-only staging dir and verify
# and provision THAT copy (the same bytes), never the user's path.
#
# verify_whonix/_stealth_provision/need_root/need_cmd/serialize are stubbed and
# called via the sourced library, which the linter can't see:
# shellcheck disable=SC1091,SC2034,SC2317,SC2329
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log="$tmp/log"

(
    export KRATOS_TEST=1
    export KRATOS_LIB="$lib" KRATOS_ETC="$tmp/etc" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run"
    mkdir -p "$KRATOS_ETC" "$KRATOS_STATE" "$KRATOS_RUN" "$tmp/home"
    : > "$KRATOS_ETC/whonix-signing-key.asc"
    . "$lib/common.sh"; . "$lib/net.sh"; . "$lib/stealth.sh"
    need_root() { :; }; need_cmd() { :; }; serialize() { :; }; load_config() { :; }
    stealth_is_active() { return 1; }
    # A stale staging dir from an earlier, failed run must be cleaned up.
    mkdir -p "$KRATOS_STATE/.setup.stale"
    echo genuine > "$tmp/home/Whonix.libvirt.xz"
    echo sig > "$tmp/home/Whonix.libvirt.xz.asc"
    verify_whonix() {
        printf 'verify %s %s %s\n' "$1" "$2" "$(stat -c %a "$(dirname "$1")")" >> "$log"
        # The attacker swaps the user's file right after the check.
        echo BACKDOORED > "$tmp/home/Whonix.libvirt.xz"
    }
    _stealth_provision() {
        printf 'provision %s %s\n' "$1" "$(cat "$1")" >> "$log"
        [[ -e "$KRATOS_STATE/.setup.stale" ]] && echo "stale-left" >> "$log"
    }
    stealth_setup "$tmp/home/Whonix.libvirt.xz"
    echo "after $(find "$KRATOS_STATE" -maxdepth 1 -name '.setup.*' | wc -l)" >> "$log"
) >/dev/null 2>&1

v="$(awk '$1=="verify"{print $2}' "$log")"
vsig="$(awk '$1=="verify"{print $3}' "$log")"
vmode="$(awk '$1=="verify"{print $4}' "$log")"
p="$(awk '$1=="provision"{print $2}' "$log")"
pcontent="$(awk '$1=="provision"{print $3}' "$log")"

if [[ -n "$v" && "$v" == "$tmp/state/.setup."* && "$vsig" == "$tmp/state/.setup."* ]]; then
    pass "verifies a staged copy under the root-only state dir, not the user's path"
else
    flunk "verified '$v' / '$vsig' (expected a copy under $tmp/state/.setup.*)"
fi
if [[ "$vmode" == 700 ]]; then pass "staging dir is mode 700"; else flunk "staging dir mode is '$vmode', want 700"; fi
if [[ -n "$p" && "$p" == "$v" ]]; then
    pass "provisions exactly the file that was verified"
else
    flunk "provisioned '$p' but verified '$v'"
fi
if [[ "$pcontent" == genuine ]]; then
    pass "a post-verification swap of the user's file is not extracted"
else
    flunk "extracted swapped content ('$pcontent')"
fi
if ! grep -q stale-left "$log"; then pass "stale staging dirs from failed runs are removed"; else flunk "stale staging dir left behind"; fi
if grep -q '^after 0$' "$log"; then pass "staging copy removed after setup"; else flunk "staging copy left behind ($(grep '^after' "$log"))"; fi

echo
if (( fail )); then echo "STEALTH SETUP STAGING TESTS FAILED"; exit 1; else echo "stealth setup verifies and uses the same bytes"; exit 0; fi
