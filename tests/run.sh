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
    $inc/usr/local/bin/kratos-apply-look $inc/usr/local/bin/kratos-logwatch \
    $inc/usr/local/bin/kratos-runscript $inc/usr/local/bin/kratos-sec \
    $inc/usr/local/lib/kratos/sectools-gen $inc/usr/local/lib/kratos/sec-shell \
    $inc/usr/local/lib/kratos/*.sh $inc/usr/local/lib/kratos/stealth-seat \
    build.sh config/hooks/live/*.chroot tests/*.sh && echo ok

step "nftables syntax"
tmp="$(mktemp -d)"
printf 'define WG_IF = "wg0"\ndefine WG_ENDPOINT = 198.51.100.7\ndefine WG_PORT = 51820\n' > "$tmp/defs"
for f in "$inc"/etc/kratos/modes/*.nft "$inc"/etc/kratos/stealth.nft; do
    sed "s|/run/kratos/vpn.nft|$tmp/defs|" "$f" > "$tmp/x.nft"
    if nft -c -f "$tmp/x.nft"; then echo "ok   $f"; else echo "FAIL $f"; status=1; fi
done
# workstation Nym ruleset (uid placeholder substituted)
sed "s/@NYM_UID@/1000/" workstation/nym/nym.nft > "$tmp/nym.nft"
if nft -c -f "$tmp/nym.nft"; then echo "ok   workstation/nym/nym.nft"; else echo "FAIL nym.nft"; status=1; fi
rm -rf "$tmp"

step "python syntax"
run python3 -m py_compile $inc/usr/local/bin/kratos-tray $inc/usr/local/bin/kratos-decoy $inc/usr/local/lib/kratos/harden-whonix.py $inc/usr/local/lib/kratos/stylo.py && echo ok
run python3 -m json.tool $inc/etc/firefox/policies/policies.json >/dev/null && echo "ok   policies.json"
run python3 -c "import ast,sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]" qubes/dom0/kratos-q workstation/nym/kratos-nym && echo "ok   kratos-q, kratos-nym"

step "Whonix isolation check"
run python3 -m unittest tests.test_harden_whonix

step "Stealth Mode on/off ordering"
run tests/test_stealth_order.sh

step "branding (KratosOS identity, wallpaper, installer rename)"
run tests/test_branding.sh

step "security toolset (catalog + generated menu)"
run tests/test_sectools.sh

step "WireGuard import safety (no PreUp/PostUp RCE)"
run tests/test_wg_validate.sh

step "config parser (never executes config as code)"
run tests/test_config.sh

step "host-lockdown undo replay (injection-safe argv)"
run tests/test_undo_safe.sh

step "migration"
run tests/test_migrate.sh

step "host/persona isolation (simulated attack)"
if [[ $EUID -eq 0 ]] && id "${ATTACKER:-mallory}" >/dev/null 2>&1 && id kstealth >/dev/null 2>&1; then
    run tests/attack_isolation.sh
else
    echo "skipped (needs root + 'mallory' and 'kstealth' users)"
fi

step "stylometry normalizer"
run python3 -m unittest tests.test_stylo

step "decoy rate math"
run python3 -m unittest tests.test_decoy

step "anti-fingerprint defaults"
run python3 -m unittest tests.test_fingerprint

step "Qubes layer (driver + persona policy audit)"
run python3 -m unittest tests.test_qubes

step "boot/firmware integrity"
run tests/bootcheck_test.sh

step "traffic shaping (network namespace)"
if [[ $EUID -eq 0 ]]; then
    run unshare -rn bash tests/corr_test.sh
else
    echo "skipped (needs root)"
fi

step "Nym mixnet enforcement (network namespace)"
if [[ $EUID -eq 0 ]]; then
    run unshare -n bash tests/nym_test.sh
else
    echo "skipped (needs root)"
fi

step "firewall behaviour (network namespace)"
if [[ $EUID -eq 0 ]]; then
    run unshare -n python3 tests/firewall_test.py
else
    echo "skipped (needs root)"
fi

echo
if (( status == 0 )); then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$status"
