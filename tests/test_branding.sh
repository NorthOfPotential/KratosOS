#!/usr/bin/env bash
# shellcheck disable=SC2015
# Verify the KratosOS branding assets are present and well-formed. These are
# shipped files, so this checks the image tree directly (no boot needed).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
inc="$here/../config/includes.chroot"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

# ── OS identity ────────────────────────────────────────────────────────────
osr="$inc/etc/os-release"
if grep -q '^NAME="KratosOS"' "$osr" && grep -q '^ID=kratos' "$osr" \
   && grep -q '^ID_LIKE=debian' "$osr"; then
    pass "/etc/os-release identifies KratosOS (ID_LIKE=debian kept)"
else
    flunk "/etc/os-release missing KratosOS identity"
fi
grep -q 'KratosOS' "$inc/etc/issue" && pass "/etc/issue branded" || flunk "/etc/issue not branded"

# ── Hostname is generic (anti-fingerprint; never sent via DHCP) ────────────
if [[ "$(tr -d '[:space:]' < "$inc/etc/hostname")" == localhost ]]; then
    pass "/etc/hostname is generic (localhost)"
else
    flunk "/etc/hostname is not localhost"
fi

# ── Live session identity ──────────────────────────────────────────────────
lc="$inc/etc/live/config.conf.d/0100-kratos.conf"
if grep -q 'LIVE_USER_FULLNAME="KratosOS Live"' "$lc" && grep -q 'LIVE_HOSTNAME="localhost"' "$lc"; then
    pass "live-config sets KratosOS user + localhost hostname"
else
    flunk "live-config identity not set"
fi

# ── Wallpaper package ──────────────────────────────────────────────────────
wpd="$inc/usr/share/wallpapers/KratosOS/contents/images"
ok_wp=1
for f in "$wpd/1920x1080.png" "$wpd/2560x1440.png"; do
    if [[ -f "$f" ]] && [[ "$(stat -c %s "$f")" -gt 50000 ]] \
       && [[ "$(head -c8 "$f" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]]; then
        : # real, non-trivial PNG
    else
        ok_wp=0
    fi
done
(( ok_wp )) && pass "wallpaper PNGs present and valid (1920x1080, 2560x1440)" \
            || flunk "wallpaper PNGs missing/too small/not PNG"
python3 -m json.tool "$inc/usr/share/wallpapers/KratosOS/metadata.json" >/dev/null 2>&1 \
    && pass "wallpaper metadata.json is valid JSON" || flunk "wallpaper metadata.json invalid"

# ── Look autostart wires the apply script ──────────────────────────────────
as="$inc/etc/xdg/autostart/kratos-look.desktop"
if grep -q '^Exec=/usr/local/bin/kratos-apply-look' "$as" \
   && [[ -x "$inc/usr/local/bin/kratos-apply-look" ]]; then
    pass "look autostart points to the executable apply-look script"
else
    flunk "look autostart / apply-look script not wired"
fi
bash -n "$inc/usr/local/bin/kratos-apply-look" && pass "apply-look script parses" \
    || flunk "apply-look script has a syntax error"

# ── Installer rename is present in the build hook ──────────────────────────
if grep -q 'Name=Install KratosOS' "$here/../config/hooks/live/0100-kratos.hook.chroot"; then
    pass "build hook renames the installer launcher to KratosOS"
else
    flunk "installer rename missing from build hook"
fi

echo
if (( fail )); then echo "BRANDING TESTS FAILED"; exit 1; else echo "branding assets OK"; exit 0; fi
