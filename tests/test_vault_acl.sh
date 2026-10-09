#!/usr/bin/env bash
# The VMs run as libvirt-qemu, not root, so QEMU must be able to TRAVERSE the
# 0700 vault mount to reach its disk — without the directory becoming readable
# or listable to anyone (finding R8-1). _vault_grant_qemu_traverse adds an
# execute-only POSIX ACL for the QEMU user and nothing more.
# shellcheck disable=SC1091
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

if ! command -v setfacl >/dev/null || ! command -v getfacl >/dev/null; then
    echo "  SKIP  acl tools (setfacl/getfacl) not installed"; exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export KRATOS_TEST=1 KRATOS_LIB="$lib" KRATOS_ETC="$tmp/etc" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run"
mkdir -p "$KRATOS_ETC" "$KRATOS_STATE" "$KRATOS_RUN"
# shellcheck source=/dev/null
. "$lib/common.sh"; . "$lib/net.sh"; . "$lib/stealth.sh"

# A real, unprivileged user that exists everywhere, standing in for libvirt-qemu.
qemu_user="nobody"
VAULT_MNT="$tmp/vault"
install -d -m 700 "$VAULT_MNT"

if ! setfacl -m u:"$qemu_user":x "$VAULT_MNT" 2>/dev/null; then
    echo "  SKIP  filesystem does not support POSIX ACLs here"; exit 0
fi
setfacl -b "$VAULT_MNT"   # reset; now exercise the real function

STEALTH_QEMU_USER="$qemu_user" _vault_grant_qemu_traverse

acl="$(getfacl -p "$VAULT_MNT" 2>/dev/null)"
if grep -q "user:$qemu_user:--x" <<<"$acl"; then
    pass "QEMU user gets execute-only (traverse) on the vault"
else
    flunk "QEMU user did not get an execute-only ACL: $acl"
fi
# It must NOT get read or write (would expose the persona disks / listing).
if grep -qE "user:$qemu_user:(r|.w|..x$)" <<<"$acl" && grep -qE "user:$qemu_user:r|user:$qemu_user:.w" <<<"$acl"; then
    flunk "QEMU user ACL grants read/write (too permissive): $acl"
else
    pass "QEMU user ACL grants no read/write"
fi
# The base mode stays 0700: group/other still fully excluded.
mode="$(stat -c '%a' "$VAULT_MNT")"
if [[ "$mode" == 700 ]]; then pass "vault base mode stays 0700"; else flunk "vault base mode changed to $mode"; fi

exit "$fail"
