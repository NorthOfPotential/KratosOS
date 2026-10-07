#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# host_restore replays the Stealth host-lockdown undo log as a real argv array,
# never through a shell, and only for an allowlist of commands. These tests
# prove: (a) allowed steps run, (b) a step whose program isn't allowlisted is
# refused, and (c) nothing in an undo line is ever shell-interpreted (no command
# substitution, no ';' chaining, no globbing) even if the log is corrupted.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

export KRATOS_RUN="$tmp/run" KRATOS_ETC="$tmp/etc" KRATOS_STATE="$tmp/state" KRATOS_LIB="$lib"
mkdir -p "$tmp/run"
# shellcheck source=/dev/null
. "$lib/common.sh"; . "$lib/stealth.sh"

# ── 1. An allowlisted step runs (rm is allowed) ────────────────────────────
touch "$tmp/legit_a" "$tmp/legit_b"
: > "$STEALTH_UNDO"
undo "rm -f $tmp/legit_a $tmp/legit_b"
host_restore
if [[ ! -e "$tmp/legit_a" && ! -e "$tmp/legit_b" ]]; then
    pass "allowlisted undo step executed (files removed)"
else
    flunk "allowlisted undo step did not run"
fi

# ── 2. A non-allowlisted program is refused ────────────────────────────────
: > "$STEALTH_UNDO"
undo "touch $tmp/should_not_exist"
host_restore 2>/dev/null
if [[ ! -e "$tmp/should_not_exist" ]]; then
    pass "non-allowlisted program ('touch') refused, not executed"
else
    flunk "non-allowlisted program ran"
fi

# ── 3. No shell interpretation of a corrupted/hostile undo line ────────────
# 'rm' is allowlisted, but the ';' and command substitution must be inert:
# they become literal argv to rm, never a second command.
: > "$STEALTH_UNDO"
undo "rm -f $tmp/x ; touch $tmp/injected"
undo 'rm -f $(touch '"$tmp"'/substituted)'
host_restore 2>/dev/null
if [[ ! -e "$tmp/injected" && ! -e "$tmp/substituted" ]]; then
    pass "';' chaining and command substitution in the log are inert"
else
    flunk "undo log was shell-interpreted (injection succeeded)"
fi

# ── 4. The undo log is removed after replay ────────────────────────────────
if [[ ! -e "$STEALTH_UNDO" ]]; then
    pass "undo log removed after restore"
else
    flunk "undo log left behind"
fi

echo
if (( fail )); then echo "UNDO-SAFETY TESTS FAILED"; exit 1; else echo "host_restore is injection-safe"; exit 0; fi
