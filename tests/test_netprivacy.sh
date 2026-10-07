#!/usr/bin/env bash
# Network privacy posture: DHCP/MAC identity (finding 23) and libvirt
# authorization (finding 26).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../config/includes.chroot"
nm="$root/etc/NetworkManager/conf.d/00-kratos-privacy.conf"
lvrule="$root/etc/polkit-1/rules.d/90-kratos-libvirt.rules"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }
# chk <file> <regex> <desc>: pass if the regex is present, else flunk.
chk() { if grep -qiE "$2" "$1"; then pass "$3"; else flunk "$3"; fi; }

echo "— DHCP / MAC identity (finding 23) —"
chk "$nm" '^wifi\.cloned-mac-address=random'     "Wi-Fi MAC randomized per connection"
chk "$nm" '^ethernet\.cloned-mac-address=random' "Ethernet MAC randomized per connection"
chk "$nm" '^ipv4\.dhcp-send-hostname=false'      "hostname not sent in DHCP"
chk "$nm" '^ipv4\.dhcp-client-id=mac'            "DHCP client-id tied to the (random) MAC, not a stable DUID"
chk "$nm" '^ipv4\.dhcp-fqdn=$'                   "no DHCP FQDN sent"
chk "$nm" '^connection\.mdns=0'                  "mDNS off"
chk "$nm" '^connection\.llmnr=0'                 "LLMNR off"

echo "— libvirt authorization (finding 26) —"
if [[ -f "$lvrule" ]] && grep -qE 'org\.libvirt\.' "$lvrule" && grep -qE 'polkit\.Result\.NO' "$lvrule"; then
    pass "an explicit polkit rule denies non-root libvirt management"
else
    flunk "no explicit libvirt authorization rule that denies non-root"
fi

# Live check (test-gap item 14): on a real system with libvirt running, an
# ordinary user must not be able to drive qemu:///system. Skips off-libvirt.
victim="${ATTACKER:-mallory}"
if [[ $EUID -eq 0 ]] && command -v virsh >/dev/null && id "$victim" >/dev/null 2>&1 \
   && systemctl is-active --quiet libvirtd 2>/dev/null; then
    if runuser -u "$victim" -- virsh -c qemu:///system list >/dev/null 2>&1; then
        flunk "ordinary user CAN manage qemu:///system (libvirt authz not enforced)"
    else
        pass "ordinary user cannot manage qemu:///system"
    fi
else
    echo "  SKIP  live qemu:///system check needs root + a running libvirtd + '$victim'"
fi

exit "$fail"
