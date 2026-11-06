#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2317,SC2329
# `kratos status` firewall line. Reading the nft ruleset needs root, so an
# unprivileged `kratos status` (what the login banner suggests) used to print
# "[FAIL] firewall NOT loaded" on a correctly firewalled system (VM install
# test). Unprivileged it must report the service state and point to sudo; as
# root (or whenever the ruleset is readable) the real ruleset check decides.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export KRATOS_ETC="$tmp/etc" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run" KRATOS_LIB="$lib"
mkdir -p "$KRATOS_ETC" "$KRATOS_STATE" "$KRATOS_RUN"
. "$lib/common.sh"; . "$lib/net.sh"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

# Stubs: only the firewall line is under test.
nft() { return "$NFT_RC"; }
systemctl() { [[ "$*" == *"is-active"*"kratos-firewall.service"* ]] && return "$SVC_RC"; return 0; }
ip() { return 1; }
saved_mode() { echo normal; }
dns_status() { :; }; net_mac() { :; }; stealth_status() { :; }; load_config() { :; }

fwline() {  # $1=nft rc  $2=service rc  $3=euid
    NFT_RC=$1 SVC_RC=$2 KRATOS_TEST_EUID=$3 net_status 2>&1 | grep -i firewall
}
out=$(fwline 1 0 1000)
if [[ "$out" == *WARN*"service active"*"sudo kratos status"* && "$out" != *FAIL* ]]; then
    pass "unprivileged + service active: no false FAIL, points to sudo"
else flunk "unprivileged + service active: $out"; fi
out=$(fwline 1 3 1000)
if [[ "$out" == *FAIL*"NOT active"* ]]; then
    pass "unprivileged + service inactive: FAIL"
else flunk "unprivileged + service inactive: $out"; fi
out=$(fwline 1 0 0)
if [[ "$out" == *FAIL*"firewall NOT loaded"* ]]; then
    pass "root + ruleset missing: FAIL even if the service claims active"
else flunk "root + ruleset missing: $out"; fi
out=$(fwline 0 3 0)
if [[ "$out" == *OK*"firewall loaded"* ]]; then
    pass "ruleset readable and present: OK"
else flunk "ruleset present: $out"; fi
exit "$fail"
