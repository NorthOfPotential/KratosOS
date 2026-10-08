#!/usr/bin/env bash
# Traffic-shaping tests. Run as root in a network namespace (tests/run.sh uses
# unshare -n). Validates the tc qdiscs the shaper installs and removes. The
# decoy's rate math is covered deterministically by tests/test_decoy.py.
#
# The profile section sources the kratos libs and stubs load_config/
# corr_shape_iface, which the linter can't see across the sourced files:
# shellcheck disable=SC1091,SC2317,SC2329
set -uo pipefail
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

ip link set lo up 2>/dev/null

echo "— uplink rate-limiting (tbf) —"
if tc qdisc replace dev lo root handle 1: tbf rate 1mbit burst 32kbit latency 400ms 2>/dev/null \
   && tc qdisc show dev lo | grep -q 'tbf.*rate 1Mbit'; then
    pass "token-bucket rate limit installs"
else
    flunk "tbf qdisc did not install"
fi

echo "— timing jitter (netem) —"
if tc qdisc replace dev lo parent 1:1 handle 10: netem delay 15ms 15ms distribution normal 2>/dev/null; then
    if tc qdisc show dev lo | grep -q netem; then pass "netem jitter installs"; else flunk "netem missing after add"; fi
else
    echo "  SKIP  netem (sch_netem module not available in this sandbox; present on CI)"
fi
tc qdisc del dev lo root 2>/dev/null
if tc qdisc show dev lo | grep -q 'tbf\|netem'; then flunk "qdisc not removed"; else pass "shaping removes cleanly"; fi

# The decoy's cover-traffic RATE is pure math (parse_rate + packet size) and is
# covered deterministically by tests/test_decoy.py — no fragile subprocess /
# loopback / timeout integration here.

echo "— Stealth correlation profile (CORR_STEALTH_PROFILE) —"
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
rundir="$(mktemp -d)"
export KRATOS_RUN="$rundir" KRATOS_LIB="$lib" KRATOS_ETC=/tmp KRATOS_STATE=/tmp
# shellcheck source=/dev/null
. "$lib/common.sh"; . "$lib/net.sh"; . "$lib/corr.sh"
load_config() { :; }                 # keep env-set CORR_* values
corr_shape_iface() { echo lo; }      # shape loopback in this netns
shaped() { tc qdisc show dev lo | grep -q 'tbf\|netem'; }

tc qdisc del dev lo root 2>/dev/null
if CORR_STEALTH_PROFILE=off corr_stealth_apply >/dev/null 2>&1; then :; fi
if shaped; then flunk "profile=off still shaped the uplink"; else pass "profile=off shapes nothing"; fi

if CORR_SHAPE_RATE=1mbit CORR_SHAPE_JITTER=15ms CORR_STEALTH_PROFILE=balanced \
       corr_stealth_apply >/dev/null 2>&1; then :; fi
if tc qdisc show dev lo | grep -q tbf; then pass "profile=balanced rate-limits the uplink (tbf)"; else flunk "balanced did not shape the uplink"; fi
corr_stealth_clear >/dev/null 2>&1
if shaped; then flunk "corr_stealth_clear did not remove shaping"; else pass "clear removes shaping cleanly"; fi

# max applies the same host shaping as balanced (never weaker) AND warns the
# user the Nym mixnet is NOT active — it does not silently imply mixnet cover.
if CORR_SHAPE_RATE=1mbit CORR_STEALTH_PROFILE=max corr_stealth_apply 2>"$rundir/max.err" >/dev/null; then :; fi
if tc qdisc show dev lo | grep -q tbf; then pass "profile=max is never weaker than balanced (shapes the uplink)"; else flunk "profile=max applied no protection"; fi
if grep -qi "nym mixnet is NOT active" "$rundir/max.err"; then pass "profile=max warns that the mixnet is not active"; else flunk "profile=max did not warn about the inactive mixnet"; fi
corr_stealth_clear >/dev/null 2>&1

# finding R5-3: an administrator's existing qdisc must survive a Stealth
# apply+clear cycle — apply refuses to overwrite it, and clear must NOT delete
# the qdisc Kratos never recorded installing.
tc qdisc del dev lo root 2>/dev/null
if tc qdisc replace dev lo root handle 1: htb default 10 2>/dev/null; then
    CORR_SHAPE_RATE=1mbit CORR_STEALTH_PROFILE=balanced corr_stealth_apply >/dev/null 2>&1 || true
    if tc qdisc show dev lo | grep -q htb; then pass "apply refuses to overwrite an existing custom qdisc"; else flunk "apply clobbered the admin qdisc"; fi
    corr_stealth_clear >/dev/null 2>&1
    if tc qdisc show dev lo | grep -q htb; then pass "clear leaves the admin qdisc intact (no untracked fallback)"; else flunk "clear deleted the admin qdisc Kratos never installed"; fi
    tc qdisc del dev lo root 2>/dev/null
else
    echo "  SKIP  sch_htb not available to test QoS preservation"
fi
tc qdisc del dev lo root 2>/dev/null

# finding R5-5: CORR_DECOY=off must stop the automatic profile from starting
# cover traffic, even when a sink is configured and the mode is vpn.
saved_mode() { echo vpn; }
rm -f "$CORR_DECOY_PIDFILE" 2>/dev/null
CORR_DECOY=off CORR_DECOY_SINK="10.0.0.1:9" corr_decoy_start >/dev/null 2>&1 || true
if [[ ! -e "$CORR_DECOY_PIDFILE" ]]; then pass "CORR_DECOY=off does not start cover traffic"; else flunk "decoy started despite CORR_DECOY=off"; fi

# findings R6-H6/H7: inert privacy switches must make Stealth refuse to start.
# corr_assert_implemented calls die (exit) on refusal, so run it in a subshell.
if ( CORR_BRIDGES=obfs4 CORR_MODE=tor corr_assert_implemented ) >/dev/null 2>&1; then
    flunk "CORR_BRIDGES!=off was accepted (inert setting not refused)"
else
    pass "CORR_BRIDGES!=off is refused (not implemented)"
fi
if ( CORR_BRIDGES=off CORR_MODE=mixnet corr_assert_implemented ) >/dev/null 2>&1; then
    flunk "CORR_MODE=mixnet was accepted (inert setting not refused)"
else
    pass "CORR_MODE=mixnet is refused (not implemented)"
fi
if ( CORR_BRIDGES=off CORR_MODE=tor corr_assert_implemented ) >/dev/null 2>&1; then
    pass "default (bridges off, tor) is accepted"
else
    flunk "default correlation settings were wrongly refused"
fi
rm -rf "$rundir"

echo
if (( fail )); then echo "SHAPING TESTS FAILED"; else echo "shaping tests passed"; fi
exit "$fail"
