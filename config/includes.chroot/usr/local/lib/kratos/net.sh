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
    local endpoint host port
    endpoint="$(awk -F' *= *' 'tolower($1)=="endpoint"{print $2; exit}' "$WG_IMPORTED")"
    host="${endpoint%:*}"
    port="${endpoint##*:}"
    # A hostname would need a clear-text DNS lookup outside the tunnel
    [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    install -d -m 755 "$KRATOS_RUN"
    cat > "$KRATOS_RUN/vpn.nft" <<EOF
define WG_IF = "$WG_IF"
define WG_ENDPOINT = $host
define WG_PORT = $port
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
            net_links on
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

# Bring NetworkManager-managed links up/off. Best-effort: absence of nmcli (or
# a non-NM setup) must not break mode switching — the firewall is the real
# boundary. We do NOT globally block ARP in nftables (that would break normal
# and vpn neighbour resolution); instead offline simply has no up links.
net_links() {
    command -v nmcli >/dev/null 2>&1 || return 0
    case "$1" in
        off) nmcli networking off >/dev/null 2>&1 || true ;;
        on)  nmcli networking on  >/dev/null 2>&1 || true ;;
    esac
}

# Called by kratos-firewall.service before any network interface comes up.
net_boot() {
    need_root boot
    install -d -m 755 "$KRATOS_RUN" "$KRATOS_STATE"
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
