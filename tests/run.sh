#!/usr/bin/env bash
# Run all KratosOS checks. Firewall tests need root (they use a throwaway
# network namespace and don't touch the host's firewall).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
inc=config/includes.chroot
status=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run() { "$@" || status=1; }

step "shellcheck"
run shellcheck -x $inc/usr/local/bin/kratos $inc/usr/local/bin/kratos-panic \
    $inc/usr/local/lib/kratos/*.sh build.sh config/hooks/live/*.chroot tests/*.sh && echo ok

step "nftables syntax"
tmp="$(mktemp -d)"
printf 'define WG_IF = "wg0"\ndefine WG_ENDPOINT = 198.51.100.7\ndefine WG_PORT = 51820\n' > "$tmp/defs"
for f in "$inc"/etc/kratos/modes/*.nft "$inc"/etc/kratos/stealth.nft; do
    sed "s|/run/kratos/vpn.nft|$tmp/defs|" "$f" > "$tmp/x.nft"
    if nft -c -f "$tmp/x.nft"; then echo "ok   $f"; else echo "FAIL $f"; status=1; fi
done
rm -rf "$tmp"

step "python syntax"
run python3 -m py_compile $inc/usr/local/bin/kratos-tray $inc/usr/local/lib/kratos/harden-whonix.py && echo ok
run python3 -m json.tool $inc/etc/firefox/policies/policies.json >/dev/null && echo "ok   policies.json"

step "Whonix isolation check"
run python3 -m unittest tests.test_harden_whonix

step "Stealth Mode on/off ordering"
run tests/test_stealth_order.sh

step "migration"
run tests/test_migrate.sh

step "firewall behaviour (network namespace)"
if [[ $EUID -eq 0 ]]; then
    run unshare -n python3 tests/firewall_test.py
else
    echo "skipped (needs root)"
fi

echo
if (( status == 0 )); then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$status"
