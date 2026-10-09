#!/usr/bin/env bash
# Import an Export-WindowsData.ps1-style folder and check manifest verification.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
kratos="$here/../config/includes.chroot/usr/local/bin/kratos"
tmp="$(mktemp -d)"
chmod 755 "$tmp"   # so an unprivileged target user can traverse to the staging leaf
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
    env -u SUDO_USER -u PKEXEC_UID KRATOS_TEST=1 KRATOS_LIB="$lib" \
        KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run" \
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
if ! compgen -G "$tmp/state/migrate/import.*" >/dev/null && ! compgen -G "$home_dir/.kratos-import.*" >/dev/null; then pass "staging area cleaned up"; else flunk "staging left behind"; fi

echo "migration: manifest with a path-traversal entry is rejected"
make_export
printf '%s  Files/../../etc/evil\n' "$(printf evil | sha256sum | cut -d' ' -f1)" >> "$export_dir/manifest.sha256"
if out="$(run_migrate)"; then rc=0; else rc=1; fi
if (( rc != 0 )) && grep -qiE "unsafe paths|\.\." <<<"$out"; then pass "rejects a manifest with .. traversal"; else flunk "accepted unsafe manifest"; echo "$out"; fi

echo "migration: a symlinked source folder is refused (no root disclosure, R6-H1)"
rm -rf "${export_dir:?}" "${home_dir:?}"
mkdir -p "$tmp/secret" "$export_dir" "$home_dir"
echo topsecret > "$tmp/secret/secret.txt"
ln -s "$tmp/secret" "$export_dir/Files"                       # Files/ points at a secret dir
printf '%s  Files/secret.txt\n' "$(printf topsecret | sha256sum | cut -d' ' -f1)" > "$export_dir/manifest.sha256"
if out="$(run_migrate)"; then rc=0; else rc=1; fi
if (( rc != 0 )) && grep -qiE "symlink|escapes" <<<"$out" && [[ ! -e "$home_dir/secret.txt" ]]; then
    pass "a symlinked Files/ is refused and nothing is disclosed"
else
    flunk "symlinked source not refused (rc=$rc, leaked=$( [[ -e "$home_dir/secret.txt" ]] && echo yes || echo no ))"; echo "$out"
fi

echo "migration: an extra file not in the manifest is rejected (R6-16)"
make_export
echo "unlisted" > "$export_dir/Files/Documents/evil.desktop"   # present but NOT in the manifest
if out="$(run_migrate)"; then rc=0; else rc=1; fi
if (( rc != 0 )) && grep -qiE "not listed in the manifest|unlisted extras" <<<"$out" && [[ ! -e "$home_dir/Documents/evil.desktop" ]]; then
    pass "an unmanifested extra file is refused (set equality enforced)"
else
    flunk "unmanifested extra was accepted (rc=$rc)"; echo "$out"
fi

echo "migration: a home-root dotfile in the backup is refused (R8-9 autostart injection)"
make_export
mkdir -p "$export_dir/Files/.config/autostart"
echo "[Desktop Entry]" > "$export_dir/Files/.config/autostart/evil.desktop"
# Rebuild the manifest so the tampered file is LISTED (simulating a manifest an
# attacker regenerated) — set-equality alone would then pass.
( cd "$export_dir" && find Files -type f -print0 | xargs -0 sha256sum ) > "$export_dir/manifest.sha256"
if out="$(run_migrate)"; then rc=0; else rc=1; fi
if (( rc != 0 )) && grep -qiE "dotfile|dotdir|\.config" <<<"$out" && [[ ! -e "$home_dir/.config/autostart/evil.desktop" ]]; then
    pass "a home-root dotdir (autostart) in the backup is refused even when manifested"
else
    flunk "home-root dotfile import was accepted (rc=$rc)"; echo "$out"
fi

echo "migration: elevated --to outside the invoker's home is refused"
mhome="$(getent passwd mallory 2>/dev/null | cut -d: -f6)"
if [[ $EUID -eq 0 && -n "$mhome" ]]; then
    make_export
    if out="$(env KRATOS_TEST=1 KRATOS_LIB="$lib" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run" SUDO_USER=mallory \
                 "$kratos" migrate --from "$export_dir" --to "$tmp/outside" 2>&1)"; then rc=0; else rc=1; fi
    if (( rc != 0 )) && grep -qiE "must be inside|refusing elevated" <<<"$out"; then
        pass "elevated migration is confined to the invoker's home"
    else
        flunk "elevated --to confinement not enforced"; echo "$out"
    fi
else
    echo "  SKIP  needs root + a 'mallory' user to test home confinement"
fi

echo "migration: elevated publish never writes the destination as root (pre-existing files untouched)"
if [[ $EUID -eq 0 && -n "$mhome" ]]; then
    make_export
    idest="$mhome/kratos-import-test"
    rm -rf "$idest"; mkdir -p "$idest"; chown mallory: "$idest"   # a real user-owned home dir
    # A pre-existing root-owned file in the destination must NOT be touched:
    # the publish rsyncs AS mallory, who cannot modify a root-owned file.
    echo keep > "$idest/preexisting-root-file"; chown root:root "$idest/preexisting-root-file"
    env KRATOS_TEST=1 KRATOS_LIB="$lib" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run" SUDO_USER=mallory \
        "$kratos" migrate --from "$export_dir" --to "$idest" >/dev/null 2>&1 || true
    pre_owner="$(stat -c %U "$idest/preexisting-root-file" 2>/dev/null)"
    imp_owner="$(stat -c %U "$idest/Documents/Taxes 2025/notes.txt" 2>/dev/null)"
    if [[ "$pre_owner" == root ]]; then
        pass "pre-existing root-owned file left untouched"
    else
        flunk "pre-existing file became '$pre_owner'"
    fi
    if [[ "$imp_owner" == mallory ]]; then
        pass "imported files are owned by the target user"
    else
        flunk "imported file owner is '$imp_owner', expected mallory"
    fi
    rm -rf "$idest"
else
    echo "  SKIP  needs root + a 'mallory' user to test import-scoped ownership"
fi

echo "migration: a root-owned destination is NOT written via root (no root-write primitive, R5-1)"
if [[ $EUID -eq 0 && -n "$mhome" ]]; then
    make_export
    # Destination is root-owned and NOT writable by mallory. This stands in for
    # the TOCTOU where $dest, validated inside the home, is swapped at write time
    # for a path only root can write: a correct publish-as-user must FAIL CLOSED
    # here instead of silently writing it as root.
    victim="$mhome/victim-root-dir"
    rm -rf "$victim"; mkdir -p "$victim"; chown root:root "$victim"; chmod 755 "$victim"
    if out="$(env KRATOS_TEST=1 KRATOS_LIB="$lib" KRATOS_STATE="$tmp/state" KRATOS_RUN="$tmp/run" SUDO_USER=mallory \
                 "$kratos" migrate --from "$export_dir" --to "$victim" 2>&1)"; then rc=0; else rc=1; fi
    if (( rc != 0 )) && [[ -z "$(ls -A "$victim" 2>/dev/null)" ]]; then
        pass "root-owned destination fails closed (root never writes it)"
    else
        flunk "imported into a root-owned dir via root (rc=$rc, contents='$(ls -A "$victim" 2>/dev/null)')"; echo "$out"
    fi
    rm -rf "$victim"
else
    echo "  SKIP  needs root + a 'mallory' user to test the root-write property"
fi

exit "$fail"
