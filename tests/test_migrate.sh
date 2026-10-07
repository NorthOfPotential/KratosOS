#!/usr/bin/env bash
# Import an Export-WindowsData.ps1-style folder and check manifest verification.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
kratos="$here/../config/includes.chroot/usr/local/bin/kratos"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export_dir="$tmp/export"
home_dir="$tmp/home"
fail=0

pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

make_export() {
    rm -rf "${export_dir:?}" "${home_dir:?}"
    mkdir -p "$export_dir/Files/Documents/Taxes 2025" "$export_dir/Files/Pictures" \
             "$export_dir/inventory" "$home_dir"
    echo "hello" > "$export_dir/Files/Documents/Taxes 2025/notes.txt"
    head -c 4096 /dev/urandom > "$export_dir/Files/Pictures/photo.jpg"
    printf '"DisplayName","DisplayVersion","Publisher"\n"Google Chrome","1","Google"\n"Steam","2","Valve"\n' \
        > "$export_dir/inventory/installed-software.csv"
    (cd "$export_dir" && find Files -type f -print0 | xargs -0 sha256sum) > "$export_dir/manifest.sha256"
}

run_migrate() {
    # Unset SUDO_USER/PKEXEC_UID so this is treated as a direct-root run (the
    # test's --to lives in /tmp, outside any desktop user's home); the home
    # confinement is exercised separately below.
    env -u SUDO_USER -u PKEXEC_UID KRATOS_TEST=1 KRATOS_LIB="$lib" KRATOS_RUN="$tmp/run" \
        "$kratos" migrate --from "$export_dir" --to "$home_dir" 2>&1
}

echo "migration: clean export"
make_export
out="$(run_migrate)"
if [[ -f "$home_dir/Documents/Taxes 2025/notes.txt" && -f "$home_dir/Pictures/photo.jpg" ]]; then
    pass "files copied (with spaces in names)"; else flunk "files copied"; fi
if grep -q "all files verified" <<<"$out"; then pass "manifest verified"; else flunk "manifest verified"; fi
if [[ ! -e "$home_dir/manifest.sha256" ]]; then pass "manifest itself not copied"; else flunk "manifest not copied"; fi
if grep -q "Steam" <<<"$out" && grep -q "Firefox" <<<"$out"; then
    pass "app suggestions shown"; else flunk "app suggestions shown"; fi
if [[ "$(stat -c %a "$home_dir/Pictures/photo.jpg")" == 600 ]]; then
    pass "copied files are private (600)"; else flunk "copied files are private"; fi

echo "migration: export with a corrupted file (must fail closed)"
make_export
echo "tampered" > "$export_dir/Files/Documents/Taxes 2025/notes.txt"
if out="$(run_migrate)"; then rc=0; else rc=1; fi
if (( rc != 0 )); then pass "import FAILS on a verification mismatch"; else flunk "import did not fail on mismatch"; fi
if grep -qiE "verification FAILED|incomplete or altered" <<<"$out"; then pass "reports the verification failure"; else flunk "no clear failure message"; echo "$out"; fi
if [[ ! -e "$home_dir/Documents/Taxes 2025/notes.txt" ]]; then pass "nothing published on failure (destination untouched)"; else flunk "tampered file was published anyway"; fi
if ! compgen -G "$home_dir/.kratos-import.*" >/dev/null; then pass "staging area cleaned up"; else flunk "staging left behind"; fi

echo "migration: manifest with a path-traversal entry is rejected"
make_export
printf '%s  Files/../../etc/evil\n' "$(printf evil | sha256sum | cut -d' ' -f1)" >> "$export_dir/manifest.sha256"
if out="$(run_migrate)"; then rc=0; else rc=1; fi
if (( rc != 0 )) && grep -qiE "unsafe paths|\.\." <<<"$out"; then pass "rejects a manifest with .. traversal"; else flunk "accepted unsafe manifest"; echo "$out"; fi

echo "migration: elevated --to outside the invoker's home is refused"
mhome="$(getent passwd mallory 2>/dev/null | cut -d: -f6)"
if [[ $EUID -eq 0 && -n "$mhome" ]]; then
    make_export
    if out="$(env KRATOS_TEST=1 KRATOS_LIB="$lib" KRATOS_RUN="$tmp/run" SUDO_USER=mallory \
                 "$kratos" migrate --from "$export_dir" --to "$tmp/outside" 2>&1)"; then rc=0; else rc=1; fi
    if (( rc != 0 )) && grep -qiE "must be inside|refusing elevated" <<<"$out"; then
        pass "elevated migration is confined to the invoker's home"
    else
        flunk "elevated --to confinement not enforced"; echo "$out"
    fi
else
    echo "  SKIP  needs root + a 'mallory' user to test home confinement"
fi

exit "$fail"
