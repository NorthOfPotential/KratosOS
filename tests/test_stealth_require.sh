#!/usr/bin/env bash
# Stealth "required vs best-effort" protections (finding 16): a protection the
# user lists in STEALTH_REQUIRE must fail CLOSED (die) when it can't be applied,
# while anything else is best-effort (warn and continue).
#
# STEALTH_REQUIRE is read by the sourced stealth.sh, which the linter can't see;
# the chown/chmod stubs are called indirectly from give_display:
# shellcheck disable=SC1091,SC2034,SC2317,SC2329
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

# Source the library with just enough environment; common.sh provides die/warn.
load() {
    export KRATOS_LIB="$lib"
    export KRATOS_ETC="$lib/../../../etc/kratos"
    export KRATOS_STATE="/tmp" KRATOS_RUN="/tmp"
    # shellcheck source=/dev/null
    . "$lib/common.sh"
    # shellcheck source=/dev/null
    . "$lib/stealth.sh"
}

echo "— membership (_stealth_required) —"
(
    load; STEALTH_REQUIRE="swap,sleep"
    _stealth_required swap   || exit 11
    _stealth_required sleep  || exit 12
    _stealth_required camera && exit 13
    exit 0
)
case $? in
    0) pass "parses a comma list: swap/sleep required, camera not" ;;
    *) flunk "membership test wrong" ;;
esac

echo "— a REQUIRED protection fails closed —"
out="$( ( load; STEALTH_REQUIRE="swap,sleep"
          _protect_failed swap "no RAM"; echo REACHED ) 2>&1 )"; rc=$?
if (( rc != 0 )) && ! grep -q REACHED <<<"$out" && grep -qi "refusing to start" <<<"$out"; then
    pass "required protection dies before continuing"
else
    flunk "required protection did not fail closed (rc=$rc): $out"
fi

echo "— a BEST-EFFORT protection warns and continues —"
out="$( ( load; STEALTH_REQUIRE="swap,sleep"
          _protect_failed camera "camera busy"; echo REACHED ) 2>&1 )"; rc=$?
if (( rc == 0 )) && grep -q REACHED <<<"$out" && grep -qi "best-effort" <<<"$out"; then
    pass "best-effort protection warns and keeps going"
else
    flunk "best-effort protection did not continue (rc=$rc): $out"
fi

echo "— empty STEALTH_REQUIRE makes everything best-effort —"
out="$( ( load; STEALTH_REQUIRE=""
          _protect_failed swap "no RAM"; echo REACHED ) 2>&1 )"; rc=$?
if (( rc == 0 )) && grep -q REACHED <<<"$out"; then
    pass "nothing required -> swap failure is non-fatal"
else
    flunk "empty require list still fatal (rc=$rc): $out"
fi

echo "— give_display refuses a symlinked socket (TOCTOU, finding 18) —"
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
# A real UNIX socket as the symlink target, so [[ -S ]] is true and the symlink
# branch is what decides.
python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$tmpd/real.sock" 2>/dev/null
ln -s "$tmpd/real.sock" "$tmpd/kx-ws.sock"
out="$( ( load
          SPICE_DIR="$tmpd"; STEALTH_USER="root"
          chown() { echo "chown $*"; }      # must never run on a symlink
          chmod() { echo "chmod $*"; }
          give_display kx-ws; echo REACHED ) 2>&1 )"; rc=$?
if (( rc != 0 )) && ! grep -q REACHED <<<"$out" && grep -qi "symlink" <<<"$out" \
   && ! grep -q "^chmod" <<<"$out"; then
    pass "symlinked display socket is refused before any chmod"
elif [[ -S "$tmpd/real.sock" ]]; then
    flunk "give_display did not fail closed on a symlink (rc=$rc): $out"
else
    # Some minimal environments can't create AF_UNIX sockets; don't false-fail.
    echo "  SKIP  could not create an AF_UNIX socket in this sandbox"
fi

exit "$fail"
