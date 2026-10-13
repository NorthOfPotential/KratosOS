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
if grep -q 'name:phy0:wlan wlan unblocked$' <<<"$snap" && grep -q 'name:wwan0:wwan wwan blocked$' <<<"$snap"; then
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
_rfkill_unblock_identity "name:hci0:bluetooth"
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
if _rfkill_unblock_identity "name:phy0:wlan" && [[ "$(cat "$sys/rfkill9/soft")" == 0 ]]; then
    pass "identity resolves across index reorder (R13-4)"
else
    flunk "identity did not survive an index change"
fi

# ── radio type disambiguates switches exposed under one hardware parent ──────
# This topology exists on WMI/ACPI platforms: Wi-Fi and BT share a device link.
mkdir -p "$tmp/hardware/parent0"
ln -s "$tmp/hardware/parent0" "$sys/rfkill9/device"
ln -s "$tmp/hardware/parent0" "$sys/rfkill1/device"
echo 1 > "$sys/rfkill9/soft"
echo 1 > "$sys/rfkill1/soft"
wifi_id="$(_rfkill_identity "$sys/rfkill9")"
bt_id="$(_rfkill_identity "$sys/rfkill1")"
if [[ "$wifi_id" != "$bt_id" ]] && _rfkill_unblock_identity "$bt_id" \
   && [[ "$(cat "$sys/rfkill1/soft")" == 0 && "$(cat "$sys/rfkill9/soft")" == 1 ]]; then
    pass "shared hardware parent: restoring BT never re-enables blocked Wi-Fi"
else
    flunk "shared parent collision re-enabled the wrong transmitter"
fi

# Two switches of the same type under the same parent must fail CLOSED, not
# arbitrarily match the first rfkillN in enumeration order.
mkrf 4 wlan extra0 1
ln -s "$tmp/hardware/parent0" "$sys/rfkill4/device"
if _rfkill_unblock_identity "$wifi_id"; then
    flunk "two Wi-Fi switches with identical identity were unblocked ambiguously"
elif [[ "$(cat "$sys/rfkill9/soft")" == 1 && "$(cat "$sys/rfkill4/soft")" == 1 ]]; then
    pass "ambiguous same-type hardware identity refuses unsafe restoration"
else
    flunk "ambiguous hardware restore modified an adapter"
fi

# Additional Linux rfkill radio types need coverage for a true offline mode.
mkrf 5 uwb uwb0 0
mkrf 6 nfc nfc0 0
_rfkill_block_all
if [[ "$(cat "$sys/rfkill5/soft")" == 1 && "$(cat "$sys/rfkill6/soft")" == 1 ]]; then
    pass "offline mode also blocks UWB and NFC transmitters"
else
    flunk "offline mode omitted UWB/NFC"
fi

# Stealth's undo token must restore just the Bluetooth adapter that was
# previously enabled, never run a broad 'rfkill unblock bluetooth'.
. "$lib/stealth.sh"
echo 1 > "$sys/rfkill1/soft"
echo 1 > "$sys/rfkill9/soft"
: > "$STEALTH_UNDO"
undo "rfkill-restore $bt_id"
host_restore
if [[ "$(cat "$sys/rfkill1/soft")" == 0 && "$(cat "$sys/rfkill9/soft")" == 1 ]]; then
    pass "Stealth restores only the previously active BT adapter"
else
    flunk "Stealth restored an unrelated radio"
fi

exit "$fail"
