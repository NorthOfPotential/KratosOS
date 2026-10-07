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
    KRATOS_LIB="$lib" KRATOS_RUN="$tmp/run" "$kratos" migrate --from "$export_dir" --to "$home_dir" 2>&1
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

echo "migration: export with a corrupted file"
make_export
echo "tampered" > "$export_dir/Files/Documents/Taxes 2025/notes.txt"
out="$(run_migrate)"
if grep -q "1 file(s) differ" <<<"$out"; then pass "corruption detected"; else flunk "corruption detected"; echo "$out"; fi

exit "$fail"
