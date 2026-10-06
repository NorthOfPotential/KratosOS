#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2086,SC2294
# kratos.conf is parsed as DATA, never sourced. These tests prove a tampered
# or hostile config can set values but can NEVER execute commands as root, and
# that a config which isn't root-owned-and-secure is ignored entirely.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

mkdir -p "$tmp/etc"
conf="$tmp/etc/kratos.conf"

# Load the config in a clean subshell and print "VAR=value" for each requested
# variable (or VAR=<unset>). Uses the REAL load_config from common.sh.
load_and_dump() {
    ( export KRATOS_ETC="$tmp/etc"
      # shellcheck source=/dev/null
      . "$lib/common.sh"
      load_config
      for v in "$@"; do eval "printf '%s=%s\n' \"$v\" \"\${$v:-<unset>}\""; done )
}

# ── 1. Config can never execute code ───────────────────────────────────────
marker="$tmp/PWNED"
cat > "$conf" <<EOF
DEFAULT_MODE=normal
STEALTH_VAULT_SIZE=\$(touch $marker)
CORR_SHAPE_RATE=\`touch $marker\`
STEALTH_HACK=x; touch $marker
GUARD_START_JITTER=0
EOF
load_and_dump DEFAULT_MODE >/dev/null
if [[ -e "$marker" ]]; then
    flunk "config injection executed a command (marker created)"
else
    pass "no command execution from config (command-substitution/; are inert)"
fi

# ── 2. Unsafe values are rejected, not stored ──────────────────────────────
out="$(load_and_dump STEALTH_VAULT_SIZE CORR_SHAPE_RATE)"
if grep -q 'touch' <<<"$out"; then
    flunk "an unsafe value was stored: $out"
else
    pass "values containing shell metacharacters are dropped"
fi

# The root-owned/secure checks below only mean something when we are root and
# can actually own a file as root and compare against a non-secure one.
if [[ $EUID -ne 0 ]]; then
    echo "  (skipping root-owned/secure-parse checks; not root)"
    if (( fail )); then exit 1; else exit 0; fi
fi

# ── 3. A valid, secure config parses correctly ─────────────────────────────
chown -R root:root "$tmp/etc"
chmod 755 "$tmp/etc"
cat > "$conf" <<'EOF'
DEFAULT_MODE=vpn
STEALTH_VAULT_SIZE=64G
STEALTH_SHUTDOWN_TIMEOUT=60
CORR_DECOY_SINK=10.8.0.1:9    # inline comment is stripped
CORR_SHAPE_JITTER=15ms
EOF
chmod 644 "$conf"
out="$(load_and_dump DEFAULT_MODE STEALTH_VAULT_SIZE CORR_DECOY_SINK CORR_SHAPE_JITTER)"
check() {
    if grep -qx "$1" <<<"$out"; then pass "parsed $1"; else flunk "expected '$1' in: $out"; fi
}
check "DEFAULT_MODE=vpn"
check "STEALTH_VAULT_SIZE=64G"
check "CORR_DECOY_SINK=10.8.0.1:9"
check "CORR_SHAPE_JITTER=15ms"

# ── 4. A writable (insecure) config is ignored ─────────────────────────────
chmod 666 "$conf"
out="$(load_and_dump DEFAULT_MODE)"
if grep -qx "DEFAULT_MODE=<unset>" <<<"$out"; then
    pass "a group/other-writable config is ignored (not trusted)"
else
    flunk "insecure config was still read: $out"
fi
chmod 644 "$conf"

echo
if (( fail )); then echo "CONFIG PARSER TESTS FAILED"; exit 1; else echo "config parser safe"; exit 0; fi
