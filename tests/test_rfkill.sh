#!/usr/bin/env bash
# rfkill offline-mode handling (findings R13-4/5): snapshot/block/restore work
# through /sys/class/rfkill (overridable via KRATOS_RFKILL_SYS), cover Bluetooth
# as well as Wi-Fi/WWAN, key state by a STABLE identity, and restore only what
# was on before offline.
# shellcheck disable=SC1091
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

# Fake rfkill tree: Wi-Fi + Bluetooth unblocked, WWAN already blocked.
sys="$tmp/rfkill"
mkrf() { # <n> <type> <name> <soft>
    mkdir -p "$sys/rfkill$1"
    echo "$2" > "$sys/rfkill$1/type"
    echo "$3" > "$sys/rfkill$1/name"
    echo "$4" > "$sys/rfkill$1/soft"
}
mkrf 0 wlan      phy0 0
mkrf 1 bluetooth hci0 0
mkrf 2 wwan      wwan0 1

export KRATOS_RFKILL_SYS="$sys"
export KRATOS_ETC="$tmp/etc" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run"
mkdir -p "$KRATOS_ETC" "$KRATOS_STATE" "$KRATOS_RUN"
. "$lib/common.sh"; . "$lib/net.sh"

# ── snapshot includes Bluetooth and records per-device state ────────────────
snap="$(_rfkill_snapshot)"
if grep -q 'bluetooth unblocked$' <<<"$snap"; then
    pass "snapshot covers Bluetooth (R13-5)"
else
    flunk "Bluetooth not in snapshot: $snap"
fi
if grep -q 'name:phy0 wlan unblocked$' <<<"$snap" && grep -q 'name:wwan0 wwan blocked$' <<<"$snap"; then
    pass "snapshot records per-device state keyed by stable identity"
else
    flunk "snapshot identity/state wrong: $snap"
fi

# ── block_all soft-blocks every radio class via sysfs ───────────────────────
_rfkill_block_all
if [[ "$(cat "$sys/rfkill0/soft")" == 1 && "$(cat "$sys/rfkill1/soft")" == 1 && "$(cat "$sys/rfkill2/soft")" == 1 ]]; then
    pass "block_all blocked Wi-Fi, Bluetooth and WWAN"
else
    flunk "block_all left a radio unblocked: $(cat "$sys"/rfkill*/soft | tr '\n' ' ')"
fi

# ── restore unblocks ONLY the matched device by stable identity ─────────────
# The Bluetooth radio was unblocked before offline; restoring it must unblock
# rfkill1 only, and leave the already-blocked WWAN blocked.
_rfkill_unblock_identity "name:hci0"
if [[ "$(cat "$sys/rfkill1/soft")" == 0 ]]; then
    pass "restore unblocked the matched Bluetooth device"
else
    flunk "restore did not unblock hci0"
fi
if [[ "$(cat "$sys/rfkill2/soft")" == 1 && "$(cat "$sys/rfkill0/soft")" == 1 ]]; then
    pass "restore left other devices as offline set them (no blanket unblock)"
else
    flunk "restore touched devices it should not have"
fi

# ── identity is stable across index reorder (name match survives) ───────────
# Rename the dirs so indexes swap; identity (name:) must still resolve.
mv "$sys/rfkill0" "$sys/rfkill9"   # phy0 now at a different index
if _rfkill_unblock_identity "name:phy0" && [[ "$(cat "$sys/rfkill9/soft")" == 0 ]]; then
    pass "identity resolves across index reorder (R13-4)"
else
    flunk "identity did not survive an index change"
fi

exit "$fail"
