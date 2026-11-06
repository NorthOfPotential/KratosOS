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
chk "$nm" '^connection\.mdns=0'                  "mDNS off"
chk "$nm" '^connection\.llmnr=0'                 "LLMNR off"

echo "— DNS goes to the configured resolver, not the network's (live-probe finding) —"
# NetworkManager must not hand the DHCP/RA-advertised resolver to
# systemd-resolved as per-link DNS (it would be used alongside / instead of
# global Quad9 DoT). NM does this whenever resolved runs unless told not to;
# the old per-connection ipv4/ipv6.ignore-auto-dns "defaults" were silently
# ignored by NM ("unknown key"; VM install test: ens3 got DNS 10.0.2.3).
main="$(sed -n '/^\[main\]/,/^\[/p' "$nm")"
if grep -qx 'dns=none' <<<"$main" && grep -qx 'systemd-resolved=false' <<<"$main"; then
    pass "NetworkManager never pushes network-provided DNS to the resolver"
else
    flunk "NetworkManager can push DHCP/RA DNS to systemd-resolved (need [main] dns=none + systemd-resolved=false)"
fi
# [connection] only honours a fixed set of keys; anything else is dropped with
# a log warning, i.e. a privacy setting that silently does nothing. Allowlist =
# keys NetworkManager 1.52 (trixie) accepted in the VM test.
conn_ok=" wifi.cloned-mac-address ethernet.cloned-mac-address ipv4.dhcp-send-hostname ipv4.dhcp-client-id ipv6.dhcp-duid ipv6.ip6-privacy connection.mdns connection.llmnr "
bad_keys=""
while IFS='=' read -r k _; do
    [[ -z "$k" || "$k" == \#* || "$k" == \[* ]] && continue
    [[ "$conn_ok" == *" $k "* ]] || bad_keys="$bad_keys $k"
done < <(sed -n '/^\[connection\]/,/^\[/p' "$nm")
if [[ -z "$bad_keys" ]]; then
    pass "every [connection] default is one NetworkManager actually honours"
else
    flunk "[connection] keys NetworkManager ignores (no effect):$bad_keys"
fi
# /etc/resolv.conf must point at resolved's stub. live-build ships it as an
# empty regular file and the vendor tmpfiles rule ("L!") never replaces an
# existing file, so the installed system had an empty resolv.conf.
tmpf="$root/etc/tmpfiles.d/systemd-resolve.conf"
chk "$tmpf" '^L\+!?[[:space:]]+/etc/resolv\.conf[[:space:]].*\.\./run/systemd/resolve/stub-resolv\.conf$' \
    "/etc/resolv.conf is forced to the systemd-resolved stub at boot"
# The system resolver itself must be configured for Quad9 over authenticated DoT
# (a #hostname on each server so the TLS certificate name is verified).
rc="$root/etc/systemd/resolved.conf.d/kratos-privacy.conf"
chk "$rc" '^DNSOverTLS=yes'                       "system resolver: DNS over TLS required"
chk "$rc" '^DNS=9\.9\.9\.9#dns\.quad9\.net'       "system resolver: Quad9 with authenticated DoT (#hostname)"

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

echo "— defenses survive a USB-less / freshly-installed machine (live-probe findings) —"
# usbguard crash-looped on a VM with no USB controller (/sys/bus/usb absent).
ugdrop="$root/etc/systemd/system/usbguard.service.d/10-kratos-usb-present.conf"
if [[ -f "$ugdrop" ]] && grep -qE '^ConditionPathExists=/sys/bus/usb/devices' "$ugdrop"; then
    pass "usbguard only starts when a USB bus exists (no crash-loop on USB-less hosts)"
else
    flunk "no usbguard drop-in gating on /sys/bus/usb/devices"
fi
# firecfg writes an allow-list at BUILD time (no human user yet) that locks the
# installed user out of Firejail; the hook must drop it so the sandbox is usable.
hook="$here/../config/hooks/live/0100-kratos.hook.chroot"
if grep -qE '^firecfg' "$hook" && grep -qE '^rm -f /etc/firejail/firejail\.users' "$hook"; then
    pass "build removes the firejail allow-list so the installed user can sandbox"
else
    flunk "firejail allow-list not cleared after firecfg (installed user locked out)"
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
