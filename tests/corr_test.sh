#!/usr/bin/env bash
# Traffic-shaping tests. Run as root in a network namespace (tests/run.sh uses
# unshare -rn). Validates the tc qdiscs the shaper installs and removes. The
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

echo "— constant-rate shaping (tbf) —"
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
if tc qdisc show dev lo | grep -q tbf; then pass "profile=balanced installs constant-rate padding"; else flunk "balanced did not pad the uplink"; fi
corr_stealth_clear >/dev/null 2>&1
if shaped; then flunk "corr_stealth_clear did not remove padding"; else pass "clear removes padding cleanly"; fi

# max applies the balanced host padding as a FLOOR (never weaker than balanced)
# AND tells the user to enable the Nym mixnet for the real global defense.
if CORR_SHAPE_RATE=1mbit CORR_STEALTH_PROFILE=max corr_stealth_apply >/dev/null 2>&1; then :; fi
if tc qdisc show dev lo | grep -q tbf; then pass "profile=max is never weaker than balanced (pads the uplink)"; else flunk "profile=max applied no protection"; fi
corr_stealth_clear >/dev/null 2>&1
tc qdisc del dev lo root 2>/dev/null; rm -rf "$rundir"

echo
if (( fail )); then echo "SHAPING TESTS FAILED"; else echo "shaping tests passed"; fi
exit "$fail"
