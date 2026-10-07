#!/usr/bin/env bash
# SUID/SGID + file-capability inventory of a built image (finding 46 / test
# gap 22). Shipping ~87 security tools expands the privileged attack surface,
# so every setuid/setgid binary and every file with capabilities in the image
# must be accounted for.
#
# Usage: tests/suid-audit.sh <root-dir> [allowlist]
#   <root-dir>   the built filesystem (live-build's ./chroot) to scan
#   [allowlist]  optional file of approved paths (default tests/suid-allowlist.txt)
#
# Prints the full inventory to stdout (CI uploads it as an artifact). If an
# allowlist exists, any path NOT on it is printed as "UNEXPECTED" and the script
# exits non-zero, so a release can gate on an unreviewed privileged binary.
set -uo pipefail
root="${1:?usage: suid-audit.sh <root-dir> [allowlist]}"
allow="${2:-$(cd "$(dirname "$0")" && pwd)/suid-allowlist.txt}"

[ -d "$root" ] || { echo "suid-audit: no such root: $root" >&2; exit 2; }

inv="$(mktemp)"; trap 'rm -f "$inv"' EXIT
# setuid/setgid regular files, as paths relative to the image root.
find "$root" -xdev -type f -perm /6000 -printf '/%P\tSUID/SGID\n' 2>/dev/null | sort >> "$inv"
# files carrying capabilities (getcap reads the security.capability xattr).
if command -v getcap >/dev/null 2>&1; then
    getcap -r "$root" 2>/dev/null \
        | sed -E "s#^$root##; s/[[:space:]]+/\tCAP /" | sort >> "$inv"
fi

echo "=== KratosOS privileged-binary inventory ==="
cat "$inv"
echo "=== $(wc -l < "$inv") entr$([ "$(wc -l < "$inv")" = 1 ] && echo y || echo ies) ==="

if [ ! -f "$allow" ]; then
    echo "note: no allowlist at $allow — inventory only (nothing gated)."
    exit 0
fi

# Anything in the inventory whose path is not on the allowlist is unexpected.
unexpected="$(cut -f1 "$inv" | grep -vxF -f <(grep -vE '^\s*(#|$)' "$allow") || true)"
if [ -n "$unexpected" ]; then
    echo
    echo "UNEXPECTED privileged binaries (not in $(basename "$allow")):"
    while IFS= read -r line; do echo "  $line"; done <<< "$unexpected"
    echo "Review each, then add to the allowlist or remove the package."
    exit 1
fi
echo "all privileged binaries are on the allowlist"
