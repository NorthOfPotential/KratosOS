#!/usr/bin/env bash
# `kratos shred` runs elevated (sudo / the kratos-shred polkit helper). As root,
# a shred of a path in a user-writable folder could be raced: anything running
# as that user swaps the file for a symlink to /etc/shadow or a raw disk, and
# root's shred overwrites THAT. shred must (a) refuse symlinks outright and
# (b) do the overwrite as the invoking user, never as root.
#
# Nothing is ever really shredded here: run_as_invoker is stubbed to RECORD the
# command it would run. confirm/run_as_invoker are called via the sourced
# library, which the linter can't see:
# shellcheck disable=SC1091,SC2317,SC2329
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log="$tmp/log"
mkdir -p "$tmp/dir"
echo secret > "$tmp/file"
echo victim > "$tmp/victim"
echo data > "$tmp/dir/a"
ln -s "$tmp/victim" "$tmp/link"

(
    export KRATOS_TEST=1
    . "$lib/common.sh"; . "$lib/opsec.sh"
    confirm() { return 0; }
    run_as_invoker() { printf 'invoker %s\n' "$*" >> "$log"; }
    opsec_shred "$tmp/file" "$tmp/link" "$tmp/dir"
) >/dev/null 2>&1

if grep -q "^invoker shred -uz -- $tmp/file$" "$log"; then
    pass "a regular file is shredded through run_as_invoker (as the invoking user)"
else
    flunk "file not shredded via run_as_invoker: $(cat "$log" 2>/dev/null)"
fi
if grep -q "$tmp/link" "$log"; then
    flunk "a symlink was handed to shred (its target would be overwritten)"
else
    pass "symlinks are refused, never followed"
fi
if [[ "$(cat "$tmp/victim")" == victim ]]; then pass "symlink target untouched"; else flunk "symlink target modified"; fi
if grep -q "^invoker find $tmp/dir -xdev -type f -exec shred -uz -- {} +$" "$log" \
   && grep -q "^invoker rm -rf -- $tmp/dir$" "$log"; then
    pass "directories are shredded and removed as the invoking user (no symlink follow, one filesystem)"
else
    flunk "directory not handled via run_as_invoker: $(cat "$log" 2>/dev/null)"
fi
# Static guard: no bare (root) shred/rm left in opsec_shred.
body="$(sed -n '/^opsec_shred()/,/^}/p' "$lib/opsec.sh")"
if grep -vE '^\s*#' <<<"$body" | grep -E '(^|[^_a-z])(shred -uz|rm -rf)' | grep -vq 'run_as_invoker'; then
    flunk "opsec_shred still runs shred/rm directly as root"
else
    pass "opsec_shred never runs shred/rm as root"
fi

echo
if (( fail )); then echo "SHRED PRIVILEGE TESTS FAILED"; exit 1; else echo "kratos shred cannot be turned against system files"; exit 0; fi
