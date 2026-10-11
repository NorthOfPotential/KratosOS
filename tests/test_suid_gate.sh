#!/usr/bin/env bash
# The privileged-binary release gate (suid-audit.sh + suid-allowlist.txt):
# an unexpected SUID/SGID/cap binary must FAIL the build; an allowlisted one
# must not. Also guards that components we KNOW ship setuid (firejail) stay on
# the allowlist, so flipping the CI gate to blocking can't spuriously break.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
audit="$here/suid-audit.sh"
allow="$here/suid-allowlist.txt"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

echo "— firejail (SUID by design, we ship it) is on the allowlist —"
if grep -qxF '/usr/bin/firejail' "$allow"; then pass "firejail allowlisted"; else flunk "firejail missing from allowlist (gate would block the build)"; fi

echo "— an UNEXPECTED setuid binary fails the gate —"
root="$(mktemp -d)"; mkdir -p "$root/usr/bin"
: > "$root/usr/bin/firejail"; chmod 4755 "$root/usr/bin/firejail"   # allowlisted
: > "$root/usr/bin/evil";     chmod 4755 "$root/usr/bin/evil"       # not allowlisted
if "$audit" "$root" >/dev/null 2>&1; then
    flunk "audit passed despite an unexpected SUID binary"
else
    pass "audit fails closed on an unexpected SUID binary"
fi
rm -rf "$root"

echo "— an image with only allowlisted privileged binaries passes —"
root="$(mktemp -d)"; mkdir -p "$root/usr/bin"
: > "$root/usr/bin/firejail"; chmod 4755 "$root/usr/bin/firejail"
: > "$root/usr/bin/sudo";     chmod 4755 "$root/usr/bin/sudo"
if "$audit" "$root" >/dev/null 2>&1; then
    pass "audit passes when everything is allowlisted"
else
    flunk "audit flagged an allowlisted-only image"
fi
rm -rf "$root"

exit "$fail"
