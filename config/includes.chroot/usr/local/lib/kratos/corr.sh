# shellcheck shell=bash
# Correlation resistance: traffic shaping, jitter and decoy on the local
# uplink, plus the persona network path (Tor vs Nym mixnet).
#
# HONESTY FIRST (see docs/CORRELATION-RESISTANCE.md):
#   * None of this defeats a global adversary who watches both ends of Tor.
#   * Link shaping only blinds a LOCAL observer (your ISP), and only helps if
#     it doesn't make you stand out. It is off by default for that reason.
#   * Real unobservability against a global adversary needs a mixnet (Nym).

CORR_SHAPE_IF="${CORR_SHAPE_IF:-kratos0}"   # the WireGuard uplink
CORR_DECOY_PIDFILE="$KRATOS_RUN/decoy.pid"
CORR_SHAPED_FILE="$KRATOS_RUN/corr.shaped"  # records which iface(s) we shaped

corr_shape_iface() {
    # Shape the physical path the ISP sees. With the VPN up that is the real
    # NIC carrying WireGuard; find the interface holding the default route.
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

corr_shape_on() {
    load_config
    need_cmd tc ip
    [[ "$(saved_mode)" == vpn ]] || die "link shaping needs network mode 'vpn' (so only the tunnel is shaped); run: sudo kratos mode vpn"
    local dev; dev="$(corr_shape_iface)"
    [[ -n "$dev" ]] || die "no default-route interface to shape"

    warn "Link shaping makes your uplink look UNUSUAL to your ISP. That blinds"
    warn "volume/timing analysis but is itself a signal you are doing something."
    warn "It does NOT defeat a global adversary. See docs/CORRELATION-RESISTANCE.md."

    # Root: token-bucket filter for a constant sustained rate (hides bursts).
    # Child: netem adds random jitter (breaks fine-grained timing correlation).
    tc qdisc replace dev "$dev" root handle 1: tbf \
        rate "$CORR_SHAPE_RATE" burst 32kbit latency 400ms
    tc qdisc replace dev "$dev" parent 1:1 handle 10: netem \
        delay "$CORR_SHAPE_JITTER" "$CORR_SHAPE_JITTER" distribution normal
    # Record exactly which interface we touched, so shaping off restores only it.
    install -d -m 755 "$KRATOS_RUN"; printf '%s\n' "$dev" >> "$CORR_SHAPED_FILE"
    ok "shaping $dev at $CORR_SHAPE_RATE, jitter $CORR_SHAPE_JITTER"

    if [[ "$CORR_DECOY" == on ]]; then
        corr_decoy_start
    fi
}

corr_shape_off() {
    need_cmd tc ip
    corr_decoy_stop
    local dev
    # Restore ONLY the interface(s) Kratos actually shaped — never blow away
    # an administrator's or another app's QoS on unrelated interfaces.
    if [[ -r "$CORR_SHAPED_FILE" ]]; then
        while read -r dev; do
            if [[ -n "$dev" ]]; then tc qdisc del dev "$dev" root 2>/dev/null || true; fi
        done < "$CORR_SHAPED_FILE"
        rm -f "$CORR_SHAPED_FILE"
    fi
    # Belt-and-suspenders: also clear the current default-route iface.
    dev="$(corr_shape_iface)"
    if [[ -n "$dev" ]]; then tc qdisc del dev "$dev" root 2>/dev/null || true; fi
    ok "shaping removed"
}

corr_decoy_start() {
    load_config
    [[ -n "$CORR_DECOY_SINK" ]] || { warn "CORR_DECOY on but CORR_DECOY_SINK empty; skipping decoy"; return 0; }
    corr_decoy_stop
    # Dummy traffic INSIDE the tunnel to a sink, so the ISP sees a filled,
    # constant pipe instead of your real bursts. It only needs to send UDP, so
    # run it UNPRIVILEGED (nobody) rather than from the root kratos process.
    if command -v setpriv >/dev/null 2>&1; then
        setpriv --reuid 65534 --regid 65534 --clear-groups \
            kratos-decoy "$CORR_DECOY_SINK" "$CORR_SHAPE_RATE" &
    else
        warn "setpriv unavailable; running decoy without dropping privileges"
        kratos-decoy "$CORR_DECOY_SINK" "$CORR_SHAPE_RATE" &
    fi
    echo $! > "$CORR_DECOY_PIDFILE"
    ok "decoy traffic to $CORR_DECOY_SINK started"
}

corr_decoy_stop() {
    [[ -r "$CORR_DECOY_PIDFILE" ]] || return 0
    local pid; pid="$(cat "$CORR_DECOY_PIDFILE")"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    rm -f "$CORR_DECOY_PIDFILE"
}

corr_status() {
    load_config
    info "${BOLD}Correlation resistance${RESET}"
    info "  persona path: $CORR_MODE   bridges: $CORR_BRIDGES"
    local dev; dev="$(corr_shape_iface)"
    if [[ -n "$dev" ]] && tc qdisc show dev "$dev" 2>/dev/null | grep -q 'tbf\|netem'; then
        ok "link shaping ACTIVE on $dev"
    else
        info "  link shaping: off (default; blends with normal traffic)"
    fi
    if [[ "$CORR_MODE" == mixnet ]]; then
        warn "mixnet mode is experimental and needs nym-client in the Workstation"
    fi
}

# Live check: does THIS machine stand out? Reports signals an observer could
# use to single KratosOS (or you) out. Complements tests/test_fingerprint.py,
# which guards the shipped defaults.
corr_fingerprint() {
    load_config
    info "${BOLD}Fingerprint check${RESET} (does this machine blend in?)"
    local h; h="$(hostname 2>/dev/null)"
    if [[ "$h" == localhost || "$h" == localhost.localdomain ]]; then
        ok "hostname is generic ($h)"
    else
        bad "hostname '$h' is distinctive — set it to localhost"
    fi
    if [[ "$(cat /proc/sys/net/ipv4/tcp_timestamps 2>/dev/null)" == 0 ]]; then
        ok "TCP timestamps off (no uptime/stack fingerprint)"
    else
        bad "TCP timestamps on — reveals uptime and helps OS fingerprinting"
    fi
    if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == 1 ]]; then
        ok "IPv6 disabled"
    else
        bad "IPv6 enabled — possible leak and extra fingerprint surface"
    fi
    local dev; dev="$(corr_shape_iface)"
    if [[ -n "$dev" ]] && tc qdisc show dev "$dev" 2>/dev/null | grep -q 'tbf\|netem'; then
        warn "link shaping is ACTIVE — this makes your uplink look unusual to your ISP"
    else
        ok "no custom link shaping (uplink looks like an ordinary connection)"
    fi
    info "Blend-in reminders: use Tor Browser at its default size, don't install"
    info "extensions, and keep the persona's behaviour like everyone else's."
}

corr_main() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        status) corr_status ;;
        shape)
            need_root corr shape
            serialize
            case "${1:-}" in
                on) corr_shape_on ;;
                off) corr_shape_off ;;
                *) die "usage: kratos corr shape {on|off}" ;;
            esac ;;
        *) die "usage: kratos corr {status|shape on|shape off}" ;;
    esac
}
