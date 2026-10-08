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
CORR_SHAPED_FILE="$KRATOS_RUN/corr.shaped"  # ifaces shaped by `corr shape on`
# The Stealth correlation profile records its shaping SEPARATELY, so turning
# Stealth off never tears down link shaping the user set up by hand.
CORR_STEALTH_SHAPED_FILE="$KRATOS_RUN/corr.stealth.shaped"

corr_shape_iface() {
    # Shape the physical path the ISP sees. With the VPN up that is the real
    # NIC carrying WireGuard; find the interface holding the default route.
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# Apply constant-rate shaping + jitter to ONE interface and record it in the
# given record file so teardown restores only what that feature touched.
# Shared by `corr shape on` and the Stealth correlation profile (separate files).
_corr_shape_dev() {   # <dev> <rate> <jitter> <record-file>
    local dev="$1" rate="$2" jitter="$3" record="$4" cur
    # Don't clobber an administrator's or application's existing QoS (finding 11):
    # refuse if the root qdisc is already a custom shaper we'd overwrite.
    cur="$(tc qdisc show dev "$dev" root 2>/dev/null)"
    if grep -qE 'htb|hfsc|cake|tbf|netem|drr|qfq' <<<"$cur"; then
        warn "refusing to shape $dev: it already has a custom qdisc; not overwriting QoS ($cur)"
        return 1
    fi
    # Record our INTENT to shape $dev BEFORE touching it, so teardown has
    # positive evidence Kratos modified this interface even if we die midway.
    # Cleanup deletes a qdisc ONLY when it is in a record file — never on a
    # guess — so an administrator's QoS we refused to overwrite is never removed
    # by us (finding R5-3).
    install -d -m 755 "$KRATOS_RUN"; printf '%s\n' "$dev" >> "$record"
    # Root: token-bucket filter caps the sustained rate (smooths bursts).
    # Child: netem adds random jitter (breaks fine-grained timing correlation).
    tc qdisc replace dev "$dev" root handle 1: tbf rate "$rate" burst 32kbit latency 400ms
    tc qdisc replace dev "$dev" parent 1:1 handle 10: netem delay "$jitter" "$jitter" distribution normal
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

    _corr_shape_dev "$dev" "$CORR_SHAPE_RATE" "$CORR_SHAPE_JITTER" "$CORR_SHAPED_FILE" \
        || die "not shaping $dev (it already has a custom qdisc)"
    ok "shaping $dev at $CORR_SHAPE_RATE, jitter $CORR_SHAPE_JITTER"

    if [[ "$CORR_DECOY" == on ]]; then
        corr_decoy_start
    fi
}

# ── Stealth correlation profile (applied automatically when Stealth starts) ──
# Driven by CORR_STEALTH_PROFILE:
#   off      - DEFAULT. Nothing beyond Tor's own defaults (ConnectionPadding +
#              vanguards-lite are already on inside the Whonix Gateway).
#   balanced - Rate-limit the host uplink + add jitter so a LOCAL observer sees a
#              smoother volume/timing profile on top of Tor's padding. This is a
#              rate LIMITER, not a traffic generator: with no decoy it hides
#              bursts but NOT idle-vs-active, so it is not constant-rate. Low
#              latency, a little slower. Does NOT defeat a global passive adversary
#              (an unsolved problem for low-latency onion routing).
#   max      - same host shaping as 'balanced'. It is NOT the Nym mixnet
#              (KratosOS does not yet provision nym-client into the persona), so
#              it only warns and then applies the balanced shaping; a decoy cover
#              stream is added by either profile when network mode is 'vpn' and
#              CORR_DECOY_SINK routes through the tunnel. For real end-to-end
#              mixing set CORR_MODE=mixnet (experimental, seconds of latency).
corr_stealth_apply() {
    load_config
    local profile="${CORR_STEALTH_PROFILE:-off}"
    case "$profile" in
        off) return 0 ;;
        max)
            # HONEST (finding R4-5): KratosOS does NOT yet deploy Nym into the
            # persona Workstation, so `max` cannot actually route through the
            # mixnet. Say so plainly and fall back to the rate-limit+jitter
            # shaping — never let the strongest-looking option imply mixnet
            # protection that is not active.
            warn "CORR_STEALTH_PROFILE=max: the Nym mixnet is NOT active — KratosOS does not yet"
            warn "provision nym-client into the persona. 'max' currently applies host rate-limit"
            warn "+ jitter only (same as a decoy-less 'balanced'). Do not assume mixnet protection."
            ;;
        balanced) : ;;
        *) warn "unknown CORR_STEALTH_PROFILE '$profile'; treating as balanced" ;;
    esac
    if ! command -v tc >/dev/null 2>&1; then
        warn "tc unavailable; skipping uplink shaping"; return 0
    fi
    local dev; dev="$(corr_shape_iface)"
    if [[ -z "$dev" ]]; then
        warn "no default-route interface to shape; skipping"; return 0
    fi
    if ! _corr_shape_dev "$dev" "${CORR_SHAPE_RATE:-1mbit}" "${CORR_SHAPE_JITTER:-15ms}" "$CORR_STEALTH_SHAPED_FILE"; then
        return 0   # refused to clobber existing QoS; already warned
    fi
    # HONEST naming (finding R4-3): TBF is a rate LIMITER, not a traffic
    # generator. Without a running cover stream this hides bursts and adds
    # jitter but does NOT hide idle-vs-active — it is not "constant-rate".
    # The decoy only runs when the user actually asked for it (CORR_DECOY=on,
    # finding R5-5), with a sink, in vpn mode.
    if [[ "${CORR_DECOY:-off}" == on ]] && [[ -n "${CORR_DECOY_SINK:-}" ]] && [[ "$(saved_mode)" == vpn ]]; then
        corr_decoy_start   # a real cover stream through the tunnel => constant-rate
        ok "uplink rate-limited + jitter + decoy cover stream (constant-rate via the tunnel)"
    else
        ok "uplink rate-limited to ${CORR_SHAPE_RATE:-1mbit} + jitter (NOT constant-rate: no decoy)"
        info "for true constant-rate volume-hiding, use network mode vpn and set CORR_DECOY_SINK to a tunnel sink"
    fi
}

corr_stealth_clear() {
    command -v tc >/dev/null 2>&1 || return 0
    corr_decoy_stop
    local dev
    # Remove ONLY the interfaces the Stealth profile recorded (never the user's
    # own `corr shape on`, which uses a different record file).
    if [[ -r "$CORR_STEALTH_SHAPED_FILE" ]]; then
        while read -r dev; do
            if [[ -n "$dev" ]]; then tc qdisc del dev "$dev" root 2>/dev/null || true; fi
        done < "$CORR_STEALTH_SHAPED_FILE"
        rm -f "$CORR_STEALTH_SHAPED_FILE"
    fi
    # No untracked fallback: we delete a qdisc only when the record says Kratos
    # installed it. The intent is recorded before the qdisc is applied
    # (_corr_shape_dev), so there is no "applied but unrecorded" window to cover,
    # and guessing would risk deleting an administrator's QoS (finding R5-3).
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
    # No untracked fallback (finding R5-3): only interfaces Kratos recorded are
    # restored, so we never delete an administrator's or another app's QoS.
    ok "shaping removed"
}

# Does the decoy sink route through the tunnel interface (not the clear NIC)?
_corr_sink_via_tunnel() {
    local host="${1%%:*}" dev
    dev="$(ip route get "$host" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
    [[ -n "$dev" && "$dev" == "${CORR_SHAPE_IF:-kratos0}" ]]
}

corr_decoy_start() {
    load_config
    # Defense-in-depth (finding R5-5): the decoy is fingerprint-producing cover
    # traffic, so it runs ONLY when explicitly enabled, no matter who called us.
    [[ "${CORR_DECOY:-off}" == on ]] || { warn "CORR_DECOY is off; not starting cover traffic"; return 0; }
    [[ -n "$CORR_DECOY_SINK" ]] || { warn "CORR_DECOY on but CORR_DECOY_SINK empty; skipping decoy"; return 0; }
    # NEVER send Stealth-correlated cover traffic down the clear host path
    # (finding R4-4): require VPN mode AND confirm the sink routes through the
    # tunnel interface, or a normal-mode decoy would leak from the host IP at
    # exactly the time the persona goes active — a gift to a correlator.
    if [[ "$(saved_mode)" != vpn ]]; then
        warn "decoy NOT started: cover traffic needs network mode 'vpn' so it goes through the tunnel, not the host IP"
        return 0
    fi
    if ! _corr_sink_via_tunnel "$CORR_DECOY_SINK"; then
        warn "decoy NOT started: $CORR_DECOY_SINK does not route via the tunnel (${CORR_SHAPE_IF:-kratos0}); refusing to leak cover traffic on the clear path"
        return 0
    fi
    corr_decoy_stop
    # Dummy traffic INSIDE the tunnel to a sink, so the ISP sees a filled pipe
    # instead of your real bursts. It only needs to send UDP, so run it
    # UNPRIVILEGED (nobody); if we can't drop privileges, refuse (finding 14).
    if ! command -v setpriv >/dev/null 2>&1; then
        warn "setpriv unavailable; NOT starting the decoy (it must not run as root)"
        return 0
    fi
    setpriv --reuid 65534 --regid 65534 --clear-groups \
        kratos-decoy "$CORR_DECOY_SINK" "$CORR_SHAPE_RATE" &
    echo $! > "$CORR_DECOY_PIDFILE"
    ok "decoy traffic to $CORR_DECOY_SINK started (via the tunnel)"
}

corr_decoy_stop() {
    [[ -r "$CORR_DECOY_PIDFILE" ]] || return 0
    local pid; pid="$(cat "$CORR_DECOY_PIDFILE")"
    # Only kill it if it is still OUR decoy — guard against PID reuse (finding 12).
    if [[ -n "$pid" && "$(cat "/proc/$pid/comm" 2>/dev/null)" == kratos-decoy ]]; then
        kill "$pid" 2>/dev/null
    fi
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
