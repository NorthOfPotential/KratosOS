# shellcheck shell=bash
# Network modes: normal | vpn | offline. Every switch goes through `offline`
# first, so there is never a moment without a firewall.

WG_IMPORTED="$KRATOS_ETC/wireguard/kratos0.conf"   # user's WireGuard config
WG_RUNTIME="$KRATOS_RUN/wg/kratos0.conf"           # copy without DNS= line
WG_IF="kratos0"

load_ruleset() {
    nft -f "$KRATOS_ETC/modes/$1.nft" || die "failed to load firewall ruleset '$1'"
}

# The ONLY keys a KratosOS WireGuard config may contain. wg-quick also honours
# PreUp/PostUp/PreDown/PostDown (which run arbitrary commands as root), Table and
# SaveConfig — none of which appear here, so an imported "VPN config" can never
# execute code. A config is data, and we treat it as data.
_WG_ALLOWED_KEYS=" privatekey address dns listenport mtu fwmark publickey presharedkey allowedips endpoint persistentkeepalive "
wg_validate() {
    local f="$1" line key sect="" n=0 lc
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" == \[*\] ]]; then
            lc="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
            [[ "$lc" == "[interface]" || "$lc" == "[peer]" ]] \
                || { err "WireGuard config (line $n): unexpected section '$line'"; return 1; }
            sect="$lc"; continue
        fi
        [[ -n "$sect" ]] || { err "WireGuard config (line $n): setting before any [Interface]/[Peer] section"; return 1; }
        [[ "$line" == *=* ]] || { err "WireGuard config (line $n): not a key = value line: '$line'"; return 1; }
        key="$(printf '%s' "${line%%=*}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        if [[ "$_WG_ALLOWED_KEYS" != *" $key "* ]]; then
            err "WireGuard config (line $n): rejected key '$key'. Only standard WireGuard settings are allowed — no PreUp/PostUp/PreDown/PostDown/Table/SaveConfig."
            return 1
        fi
    done < "$f"
    return 0
}

# Write the nft defines (WG_IF/WG_ENDPOINT/WG_PORT) that vpn.nft and
# vpn-bootstrap.nft include, from the STORED config. Does NOT bring the tunnel
# up, so it is safe to call at cold boot before the network exists. Returns
# non-zero (writing nothing) when there is no valid config/endpoint.
_wg_write_defines() {
    [[ -r "$WG_IMPORTED" ]] || return 1
    wg_validate "$WG_IMPORTED" || return 1
    local endpoint host port dns ip dnsset=""
    endpoint="$(awk -F' *= *' 'tolower($1)=="endpoint"{print $2; exit}' "$WG_IMPORTED")"
    host="${endpoint%:*}"
    port="${endpoint##*:}"
    # A hostname would need a clear-text DNS lookup outside the tunnel
    [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    # The VPN's own DNS resolver address(es), so vpn.nft can allow DNS ONLY to
    # them, INSIDE the tunnel (finding R8-7). Only literal IPv4 addresses count;
    # anything else is ignored (an empty set => DNS fully blocked, fail-closed).
    dns="$(awk -F' *= *' 'tolower($1)=="dns"{print $2; exit}' "$WG_IMPORTED" | tr ',' ' ')"
    for ip in $dns; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        dnsset="${dnsset:+$dnsset, }$ip"
    done
    install -d -m 755 "$KRATOS_RUN"
    cat > "$KRATOS_RUN/vpn.nft" <<EOF
define WG_IF = "$WG_IF"
define WG_ENDPOINT = $host
define WG_PORT = $port
define WG_DNS = { ${dnsset:-127.0.0.1} }
EOF
}

wg_up() {
    [[ -r "$WG_IMPORTED" ]] || die "no VPN configured; run: sudo kratos vpn-import <wireguard.conf>"
    wg_validate "$WG_IMPORTED" || die "stored VPN config failed validation; re-import a clean one"
    _wg_write_defines || die "VPN Endpoint must be a literal IPv4 address with a port (no hostname — that would need a clear-text lookup)"

    local dns
    dns="$(awk -F' *= *' 'tolower($1)=="dns"{print $2; exit}' "$WG_IMPORTED" | tr ',' ' ')"

    install -d -m 700 "$KRATOS_RUN/wg"
    # wg-quick would hand DNS to resolvconf; we configure resolved ourselves
    grep -iv '^[[:space:]]*dns[[:space:]]*=' "$WG_IMPORTED" > "$WG_RUNTIME"
    chmod 600 "$WG_RUNTIME"

    wg-quick up "$WG_RUNTIME" >/dev/null
    if [[ -n "$dns" ]]; then
        # shellcheck disable=SC2086
        resolvectl dns "$WG_IF" $dns
        resolvectl domain "$WG_IF" '~.'
        resolvectl dnsovertls "$WG_IF" no
    fi
}

wg_down() {
    if ip link show "$WG_IF" >/dev/null 2>&1; then
        wg-quick down "$WG_RUNTIME" >/dev/null 2>&1 || ip link del "$WG_IF"
    fi
}

net_mode() {
    local mode="${1:-}"
    is_valid_mode "$mode" || die "usage: kratos mode {${KRATOS_MODES[*]}}"
    need_root mode "$mode"
    serialize
    install -d -m 755 "$KRATOS_RUN" "$KRATOS_STATE"

    info "Switching to ${BOLD}$mode${RESET} (network blocked during the switch)..."
    load_ruleset offline
    wg_down

    case "$mode" in
        vpn)
            # Transactional bring-up (finding R8-9): route through the SAME
            # bootstrap kill-switch the cold-boot path uses (DHCP + WG endpoint
            # only, no clearnet) BEFORE raising the tunnel, instead of sitting on
            # the full vpn ruleset while the link is still re-acquiring DHCP.
            # There is never a clearnet window and never a full-vpn-without-route
            # window. Then wait for a route, raise the tunnel, install full vpn.
            _wg_write_defines || die "VPN Endpoint must be a literal IPv4 address with a port"
            load_ruleset vpn-bootstrap
            net_links on
            _wait_for_default_route 20 \
                || warn "no default route yet; raising the tunnel anyway (it connects once the link is ready)"
            wg_up
            load_ruleset vpn
            ;;
        normal)
            net_links on
            load_ruleset normal
            ;;
        offline)
            # True offline: the inet ruleset blocks IPv4/IPv6, but link-layer
            # frames (ARP, etc.) still reveal presence/MAC to the LAN (finding
            # R6-18). Bring NetworkManager's devices down so NOTHING leaves,
            # not even at layer 2. Best-effort; the kill-switch ruleset stays as
            # the backstop. Re-enabled when switching to normal/vpn above.
            net_links off
            ;;
    esac
    echo "$mode" > "$KRATOS_STATE/mode"
    ok "network mode: $mode"
}

# Wait up to <timeout> seconds for a default route (an acquired lease), so the
# offline->vpn transition doesn't raise the tunnel before the link is ready.
_wait_for_default_route() {
    local timeout="${1:-20}" t=0
    while (( t < timeout )); do
        ip route show default 2>/dev/null | grep -q . && return 0
        sleep 1; t=$((t + 1))
    done
    return 1
}

# Bring links up/off for a mode switch. Best-effort: a missing tool (or a non-NM
# setup) must not break switching — the firewall is the real boundary. We do NOT
# globally block ARP in nftables (that would break normal/vpn neighbour
# resolution); instead offline simply has no up links.
#
# offline aims at genuine LAYER-1 silence, not just "no IP" (finding R9-13):
# beyond telling NetworkManager to stop, it rfkill-blocks the Wi-Fi and WWAN
# RADIOS (so no probe/association frames leave even on NM-unmanaged radios) and
# administratively downs every PHYSICAL interface, including ones NM does not
# manage. It is still best-effort and hardware-dependent (some radios ignore
# rfkill, USB modems vary), so the kill-switch ruleset remains the backstop.
# Enumerate real (physical) NICs, skipping loopback, the Stealth bridges, the
# WireGuard tunnel and VM taps.
_physical_ifaces() {
    local dev
    for dev in /sys/class/net/*; do
        dev="${dev##*/}"
        [[ "$dev" == lo || "$dev" == kx-* || "$dev" == "$WG_IF" || "$dev" == vnet* ]] && continue
        [[ -e "/sys/class/net/$dev/device" ]] || continue
        printf '%s\n' "$dev"
    done
}

# Soft-block state of an rfkill type: blocked | unblocked | absent.
_rfkill_soft() {
    local t="$1" out
    command -v rfkill >/dev/null 2>&1 || { echo absent; return; }
    out="$(rfkill list "$t" 2>/dev/null)"
    [[ -n "$out" ]] || { echo absent; return; }
    if grep -qi 'Soft blocked: yes' <<<"$out"; then echo blocked; else echo unblocked; fi
}

net_links() {
    local state="$KRATOS_STATE/offline-links.state" dev kind a b
    case "$1" in
        off)
            # SNAPSHOT what we are about to change, ONCE, so leaving offline can
            # restore the user's prior radio/link state instead of blindly
            # enabling everything (findings R10-4/5/6). Don't overwrite an
            # existing snapshot (offline may be re-applied within one session).
            if [[ ! -f "$state" ]]; then
                install -d -m 755 "$KRATOS_STATE" 2>/dev/null || true
                {
                    printf 'rfkill wifi %s\n' "$(_rfkill_soft wifi)"
                    printf 'rfkill wwan %s\n' "$(_rfkill_soft wwan)"
                    for dev in $(_physical_ifaces); do
                        if ip -o link show "$dev" 2>/dev/null | grep -qw UP; then
                            printf 'link %s up\n' "$dev"
                        else
                            printf 'link %s down\n' "$dev"
                        fi
                    done
                } > "$state" 2>/dev/null || true
            fi
            command -v nmcli >/dev/null 2>&1 && nmcli networking off >/dev/null 2>&1
            if command -v rfkill >/dev/null 2>&1; then
                rfkill block wifi >/dev/null 2>&1 || true
                rfkill block wwan >/dev/null 2>&1 || true
            fi
            for dev in $(_physical_ifaces); do
                ip link set "$dev" down 2>/dev/null || true
            done
            ;;
        on)
            command -v nmcli >/dev/null 2>&1 && nmcli networking on >/dev/null 2>&1
            # Restore ONLY what offline changed, from the snapshot. With NO
            # snapshot (we were never offline) we touch no radios or links — never
            # unconditionally unblock a radio the user had disabled (R10-4), and
            # never leave an unmanaged NIC we downed stuck down (R10-5).
            if [[ -f "$state" ]]; then
                while read -r kind a b; do
                    case "$kind" in
                        rfkill) [[ "$b" == unblocked ]] && command -v rfkill >/dev/null 2>&1 \
                                    && rfkill unblock "$a" >/dev/null 2>&1 || true ;;
                        link)   [[ "$b" == up ]] && ip link set "$a" up 2>/dev/null || true ;;
                    esac
                done < "$state"
                rm -f "$state"
            fi
            ;;
    esac
    return 0
}

# Called by kratos-offline-links.service AFTER NetworkManager exists (finding
# R10-3): the early kratos-firewall boot loads the offline IP ruleset, but it
# runs before NetworkManager, which then brings links/radios back up — so a
# machine booted in offline never got the layer-1 shutdown. This runs post-NM
# and enforces it when (and only when) the saved mode is offline.
net_offline_links() {
    need_root offline-links
    load_config
    [[ "$(saved_mode)" == offline ]] || return 0
    install -d -m 755 "$KRATOS_RUN" "$KRATOS_STATE"
    net_links off
}

# Called by kratos-firewall.service before any network interface comes up.
net_boot() {
    need_root boot
    install -d -m 755 "$KRATOS_RUN" "$KRATOS_STATE"
    # Load config so DEFAULT_MODE is in scope: when no mode has been persisted
    # yet (first boot) saved_mode() falls back to DEFAULT_MODE, so DEFAULT_MODE=vpn
    # actually boots into the VPN kill-switch instead of clearnet (finding R8).
    load_config
    # Make DEFAULT_MODE a genuine FIRST-RUN default (finding R9-4): the build no
    # longer bakes /var/lib/kratos/mode, so on a fresh install (or the live ISO's
    # ephemeral overlay) there is no persisted mode yet. Latch the validated
    # DEFAULT_MODE now, so an installed user who sets DEFAULT_MODE=vpn truly boots
    # into the VPN kill-switch — and so the value persists exactly as a mode the
    # user later sets with `kratos mode` does (that is what sticks thereafter).
    if ! is_valid_mode "$(cat "$KRATOS_STATE/mode" 2>/dev/null)"; then
        local _dm="${DEFAULT_MODE:-normal}"
        is_valid_mode "$_dm" || _dm=normal
        printf '%s\n' "$_dm" > "$KRATOS_STATE/mode"
    fi
    load_ruleset offline
    case "$(saved_mode)" in
        normal) load_ruleset normal ;;
        vpn)
            # Cold boot with a saved VPN (finding R6-17): plain offline blocks
            # DHCP, but NetworkManager needs a lease to reach
            # network-online.target, which kratos-mode.service waits for before
            # it can bring the tunnel up — a fail-closed deadlock. Load a
            # bootstrap kill-switch that permits ONLY DHCP + the WireGuard
            # endpoint (no clear-text app traffic, no DNS, so no leak window);
            # the tunnel and full vpn.nft follow in kratos-mode.service. If no
            # valid VPN config exists, stay fully offline (fail closed).
            if _wg_write_defines; then
                load_ruleset vpn-bootstrap
            else
                warn "saved mode is vpn but no valid VPN config found; staying offline until one is imported"
            fi
            ;;
        # offline stays on the default-drop ruleset already loaded above.
        offline) ;;
    esac
}

# Called by kratos-mode.service once the network is online.
net_restore() {
    need_root restore
    [[ "$(saved_mode)" == vpn ]] && net_mode vpn
    return 0
}

net_vpn_import() {
    local src="${1:-}"
    need_root vpn-import "$src"
    serialize
    [[ -r "$src" ]] || die "usage: kratos vpn-import <wireguard.conf>"
    if ! grep -qi '^\[Interface\]' "$src" || ! grep -qi '^\[Peer\]' "$src"; then
        die "$src doesn't look like a WireGuard config"
    fi
    # Treat the imported file as untrusted data: refuse anything that isn't a
    # plain WireGuard setting (so it can never run commands as root via wg-quick).
    wg_validate "$src" || die "refusing to import $src: it contains directives that are not safe WireGuard settings"
    install -d -m 700 "$KRATOS_ETC/wireguard"
    install -m 600 "$src" "$WG_IMPORTED"
    ok "VPN config installed. Activate with: sudo kratos mode vpn"
    warn "Test the kill switch: in vpn mode, run 'sudo ip link set $WG_IF down' and confirm nothing loads."
}

net_mac() {
    local dev cur perm
    for dev in /sys/class/net/*; do
        dev="${dev##*/}"
        [[ "$dev" == lo || "$dev" == kx-* || "$dev" == "$WG_IF" || "$dev" == vnet* ]] && continue
        [[ -e "/sys/class/net/$dev/device" ]] || continue
        cur="$(cat "/sys/class/net/$dev/address")"
        perm="$(ethtool -P "$dev" 2>/dev/null | awk '{print $NF}')"
        if [[ -n "$perm" && "$cur" != "$perm" ]]; then
            ok "$dev: $cur (randomized; hardware $perm hidden)"
        else
            bad "$dev: $cur is the hardware address"
        fi
    done
}

net_status() {
    load_config
    info "${BOLD}Network mode:${RESET} $(saved_mode)"
    if nft list table inet kratos >/dev/null 2>&1; then
        ok "firewall loaded"
    else
        bad "firewall NOT loaded"
    fi
    if ip link show "$WG_IF" >/dev/null 2>&1; then
        ok "VPN tunnel up ($WG_IF)"
    elif [[ "$(saved_mode)" == vpn ]]; then
        bad "VPN mode but tunnel is down: traffic is blocked (kill switch)"
    fi
    if [[ ! -e /proc/sys/net/ipv6 ]] || [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == 1 ]]; then
        ok "IPv6 disabled"
    else
        bad "IPv6 enabled"
    fi
    # Be honest about what protects DNS in each mode: DoT in normal mode;
    # inside the WireGuard tunnel (NOT DoT) in vpn mode (finding R6-61).
    if [[ "$(saved_mode)" == vpn ]]; then
        info "  DNS: via the VPN's resolver, inside the WireGuard tunnel (not DoT)"
    elif resolvectl status 2>/dev/null | grep -q '+DNSOverTLS'; then
        ok "DNS over TLS (system resolver; plain port-53 blocked)"
    else
        warn "DNS over TLS not active"
    fi
    net_mac
    echo
    stealth_status
}
