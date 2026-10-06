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
hook="$here/../config/hooks/live/0100-kratos.hook.chroot"
if grep -q 'Name=Install KratosOS' "$hook"; then
    pass "build hook renames the installer launcher to KratosOS"
else
    flunk "installer rename missing from build hook"
fi

# ── Hacker-green accent: KDE color scheme + Konsole + apply-look ────────────
cs="$inc/usr/share/color-schemes/KratosOSDark.colors"
if grep -q '^Name=KratosOS Dark' "$cs" && grep -q '^accentColor=57,224,122' "$cs"; then
    pass "KDE color scheme KratosOS Dark has the green accent"
else
    flunk "KDE green color scheme missing/incomplete"
fi
grep -q 'plasma-apply-colorscheme KratosOSDark' "$inc/usr/local/bin/kratos-apply-look" \
    && pass "apply-look applies the green color scheme" \
    || flunk "apply-look does not apply KratosOSDark"
if grep -q '^ColorScheme=KratosOS' "$inc/usr/share/konsole/KratosOS.profile" 2>/dev/null \
   && grep -q '^Color=57,224,122' "$inc/usr/share/konsole/KratosOS.colorscheme" 2>/dev/null; then
    pass "Konsole KratosOS profile + green colorscheme present"
else
    flunk "Konsole green profile/colorscheme missing"
fi
grep -q 'DefaultProfile=KratosOS.profile' "$inc/etc/xdg/konsolerc" \
    && pass "Konsole defaults to the KratosOS profile" \
    || flunk "Konsole default profile not set"

# ── GRUB: installed-system menu branded + green ────────────────────────────
grub="$inc/etc/default/grub.d/kratos.cfg"
if grep -q '^GRUB_DISTRIBUTOR="KratosOS"' "$grub" \
   && grep -q '^GRUB_COLOR_NORMAL="green/black"' "$grub"; then
    pass "GRUB menu is branded KratosOS with green colors"
else
    flunk "GRUB branding/colors missing"
fi

# ── Plymouth: packages pulled in, logo staged, hook builds the theme ───────
if grep -qx 'plymouth' "$here/../config/package-lists/kratos.list.chroot" \
   && grep -qx 'plymouth-themes' "$here/../config/package-lists/kratos.list.chroot"; then
    pass "Plymouth packages are in the image"
else
    flunk "Plymouth packages missing from the package list"
fi
logo="$inc/usr/share/kratos-assets/plymouth-logo.png"
if [[ -f "$logo" ]] && [[ "$(head -c8 "$logo" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]]; then
    pass "Plymouth logo asset present (PNG)"
else
    flunk "Plymouth logo asset missing/not PNG"
fi
grep -q 'plymouth-set-default-theme kratos' "$hook" \
    && pass "build hook builds + enables the KratosOS Plymouth theme" \
    || flunk "Plymouth theme build missing from hook"

echo
if (( fail )); then echo "BRANDING TESTS FAILED"; exit 1; else echo "branding assets OK"; exit 0; fi
