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
# The actual workflow pipes inventory output through tee. With ordinary
# "bash -e", the pipeline incorrectly succeeds because tee exits 0. Enforce
# pipefail and exercise the SAME pipeline used by the release workflow.
if bash -euo pipefail -c '"$1" "$2" | tee "$3"' bash "$audit" "$root" "$root/inventory.txt" >/dev/null 2>&1; then
    flunk "release pipeline hid an unexpected SUID binary behind tee"
else
    pass "release pipeline preserves inventory failure through tee"
fi
rm -rf "$root"

echo "— CI step explicitly opts into pipefail —"
if grep -A 15 'name: Privileged-binary inventory' "$here/../.github/workflows/ci.yml" \
   | grep -qE '^[[:space:]]+shell: bash
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
; then
    pass "privileged-binary CI step runs bash with pipefail"
else
    flunk "privileged-binary CI step does not request a pipefail shell"
fi

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
