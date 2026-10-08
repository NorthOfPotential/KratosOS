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

echo "— optional Gateway hardening helper (vanguards + padding) —"
gwh="$here/../workstation/gateway/kratos-gw-harden"
if [[ -f "$gwh" ]]; then
    # Assert the real logic (not just the word 'vanguards' in a comment): the
    # padding directives, an actual `systemctl enable --now vanguards`, and an
    # `apt-get install ... vanguards` fallback; and that it parses.
    if grep -qE '^ConnectionPadding 1' "$gwh" && grep -qE '^ReducedConnectionPadding 0' "$gwh" \
       && grep -qE 'systemctl enable --now vanguards' "$gwh" \
       && grep -qE 'apt-get install .*vanguards' "$gwh" && bash -n "$gwh"; then
        pass "gw-harden enables full padding + actually enables/installs vanguards, and parses"
    else
        flunk "gw-harden missing padding/vanguards LOGIC or has a syntax error"
    fi
else
    flunk "Gateway hardening helper not shipped"
fi

echo "— networking is a hard dependent of the firewall (finding 6) —"
nmdrop="$root/etc/systemd/system/NetworkManager.service.d/10-kratos-firewall.conf"
fw="$root/etc/systemd/system/kratos-firewall.service"
if [[ -f "$nmdrop" ]] && grep -qE '^Requires=kratos-firewall\.service' "$nmdrop"; then
    pass "NetworkManager Requires the firewall unit (fails closed if it fails)"
else
    flunk "no NetworkManager drop-in requiring kratos-firewall.service"
fi
if grep -qE 'ExecStartPre=.*offline\.nft' "$fw"; then
    pass "firewall preloads a minimal default-drop before the full ruleset"
else
    flunk "firewall unit does not preload the default-drop layer"
fi

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
