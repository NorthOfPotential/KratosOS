#!/usr/bin/env bash
# Traffic-shaping tests. Run as root in a network namespace (tests/run.sh uses
# unshare -rn). Validates the tc qdiscs the shaper installs and removes. The
# decoy's rate math is covered deterministically by tests/test_decoy.py.
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

echo
if (( fail )); then echo "SHAPING TESTS FAILED"; else echo "shaping tests passed"; fi
exit "$fail"
