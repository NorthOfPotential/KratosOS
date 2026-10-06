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
ip link set lo up 2>/dev/null
# Preflight: can loopback deliver a UDP packet at all in this sandbox? Some
# rootless netns setups can't, which would make the rate check meaningless.
lo_ok="$(python3 - <<'PY'
import socket
try:
    r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); r.bind(("127.0.0.1", 51998)); r.settimeout(1.0)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(b"x", ("127.0.0.1", 51998))
    r.recvfrom(100); print("yes")
except OSError:
    print("no")
PY
)"
if [[ "$lo_ok" != yes ]]; then
    echo "  SKIP  loopback UDP not available in this sandbox; rate check needs it"
else
    python3 - <<'PY' &
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 51999)); s.settimeout(3.0)
n = 0; end = time.time() + 2.0
try:
    while time.time() < end:
        s.recvfrom(2000); n += 1
except OSError:
    pass
open("/tmp/kratos_decoy_count", "w").write(str(n))
PY
    sleep 0.3
    timeout 2.1 python3 "$decoy" 127.0.0.1:51999 1mbit 2>/dev/null || true
    wait 2>/dev/null
    got="$(cat /tmp/kratos_decoy_count 2>/dev/null || echo 0)"
    # ~1mbit / (1200B*8) ≈ 104 pps → ~208 in 2s; allow generous scheduler slack
    if [[ "$got" -ge 100 && "$got" -le 400 ]]; then
        pass "decoy ~1mbit rate (saw $got packets in ~2s)"
    else
        flunk "decoy rate off (saw $got packets in ~2s, expected 100–400)"
    fi
    rm -f /tmp/kratos_decoy_count
fi

echo
if (( fail )); then echo "SHAPING TESTS FAILED"; else echo "shaping tests passed"; fi
exit "$fail"
