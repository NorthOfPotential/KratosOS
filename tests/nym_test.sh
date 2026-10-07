#!/usr/bin/env bash
# Nym workstation enforcement: the fail-closed firewall must let ONLY the
# kratos-nym user reach the network, and the generated config must keep Loopix
# cover traffic on. Run as root in a netns (tests/run.sh uses unshare).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
nftfile="$here/../workstation/nym/nym.nft"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

# A low-privileged uid stands in for kratos-nym; another for a normal app.
NYM_UID=4000
APP_UID=4001

echo "— nym.nft is valid and fail-closed —"
rules="$(sed "s/@NYM_UID@/$NYM_UID/" "$nftfile")"
if nft -c -f - <<<"$rules" 2>/dev/null; then pass "nym.nft parses"; else flunk "nym.nft invalid"; fi

# Ordering: IPv6 must be dropped BEFORE any established-state accept, and every
# established accept must be gated by the nym uid — otherwise a connection
# opened before the ruleset loaded (or over IPv6) could be grandfathered in.
ipv6_line="$(grep -n 'nfproto ipv6 drop' <<<"$rules" | head -1 | cut -d: -f1)"
est_line="$(grep -n 'ct state established' <<<"$rules" | head -1 | cut -d: -f1)"
if [[ -n "$ipv6_line" && ( -z "$est_line" || "$ipv6_line" -lt "$est_line" ) ]]; then
    pass "IPv6 dropped before any established-state accept"
else
    flunk "IPv6 not dropped before established accept (pre-existing v6 could leak)"
fi
bad_est="$(grep 'ct state established' <<<"$rules" | grep -i 'accept' | grep -v 'skuid' || true)"
if [[ -z "$bad_est" ]]; then
    pass "established-state accept is scoped to the nym user only"
else
    flunk "an established-state accept is not gated by the nym uid (bypass): $bad_est"
fi

# Load it for real in this netns and probe egress as two users.
ip link set lo up 2>/dev/null
# A stand-in network so egress actually reaches the firewall (not ENETUNREACH).
ip link add kxnet type bridge 2>/dev/null && ip addr add 10.0.0.2/24 dev kxnet && ip link set kxnet up
ip route add default via 10.0.0.1 2>/dev/null || true
ip neigh add 10.0.0.1 lladdr 02:00:00:00:00:01 dev kxnet nud permanent 2>/dev/null || true
if nft -f - <<<"$rules" 2>/dev/null; then
    # The nym user may open a socket (reaches the SYN stage: "sent"/timeout),
    # a normal app is rejected immediately (ECONNREFUSED/EPERM).
    probe() { # $1 uid
        setpriv --reuid "$1" python3 - <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(0.4)
try:
    s.connect(("10.0.0.1", 80)); print("ok")
except socket.timeout: print("ok")          # SYN left; no reply
except OSError as e: print(f"blocked:{e.errno}")
PY
    }
    if command -v setpriv >/dev/null; then
        n="$(probe $NYM_UID)"; a="$(probe $APP_UID)"
        if [[ "$n" == "blocked:101" ]]; then
            echo "  SKIP  no route in sandbox to exercise egress"
        elif [[ "$n" == ok ]]; then pass "nym user can egress"; else flunk "nym user blocked ($n)"; fi
        if [[ "$a" == blocked:* ]]; then pass "normal app blocked (fail-closed)"; else flunk "normal app escaped ($a)"; fi
    else
        echo "  SKIP  setpriv unavailable; parsed-only"
    fi
    nft delete table inet kratos_nym 2>/dev/null
else
    echo "  SKIP  could not load ruleset in this sandbox (parsed-only)"
fi

echo "— generated config keeps Loopix cover traffic ON —"
cfg="$(python3 - <<PY
import importlib.util, os
from importlib.machinery import SourceFileLoader
p=os.path.join("$here","..","workstation","nym","kratos-nym")
spec=importlib.util.spec_from_loader("kn", SourceFileLoader("kn",p))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.build_config("kratos","mix.example.provider"))
PY
)"
if grep -q 'disable_loop_cover_traffic_stream = false' <<<"$cfg"; then pass "loop cover traffic enabled"; else flunk "cover traffic not enabled"; fi
if grep -q 'disable_main_poisson_packet_distribution = false' <<<"$cfg"; then pass "poisson timing enabled"; else flunk "poisson timing off"; fi
if grep -q 'disabled = true' <<<"$cfg"; then pass "client logging disabled"; else flunk "logging not disabled"; fi

echo "— provider address is validated (no TOML injection) —"
rc=0
python3 - <<PY || rc=$?
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
p=os.path.join("$here","..","workstation","nym","kratos-nym")
spec=importlib.util.spec_from_loader("kn", SourceFileLoader("kn",p)); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.build_config("c", 'evil"\ndisable_loop_cover_traffic_stream = true')
    sys.exit(0)        # accepted -> bad
except ValueError:
    sys.exit(3)        # rejected -> good
PY
if [[ $rc -eq 3 ]]; then pass "rejects a provider address with quotes/newlines"; else flunk "accepted an injecting provider address (rc=$rc)"; fi

echo
if (( fail )); then echo "NYM TESTS FAILED"; else echo "nym tests passed"; fi
exit "$fail"
