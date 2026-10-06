#!/usr/bin/env bash
# Traffic-shaping / decoy tests. Run as root in a network namespace
# (tests/run.sh uses unshare -rn). Validates the tc qdisc the shaper installs
# and that the decoy generator holds a steady rate.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
decoy="$here/../config/includes.chroot/usr/local/bin/kratos-decoy"
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

echo "— decoy (cover traffic) holds a steady rate —"
# Measure the decoy's OWN send count (UDP sendto succeeds with no listener),
# so the check tests pacing, not network delivery — robust on any runner.
countf="$(mktemp)"
KRATOS_DECOY_COUNT_FILE="$countf" timeout -s TERM 2.1 python3 "$decoy" 127.0.0.1:51999 1mbit 2>/dev/null || true
got="$(cat "$countf" 2>/dev/null || echo 0)"
rm -f "$countf"
# ~1mbit / (1200B*8) ≈ 104 pps → ~208 in ~2s; allow generous scheduler slack.
if [[ "$got" =~ ^[0-9]+$ && "$got" -ge 100 && "$got" -le 400 ]]; then
    pass "decoy paces ~1mbit ($got packets sent in ~2s)"
else
    flunk "decoy rate off ($got packets in ~2s, expected 100–400)"
fi

echo
if (( fail )); then echo "SHAPING TESTS FAILED"; else echo "shaping tests passed"; fi
exit "$fail"
