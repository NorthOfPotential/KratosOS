#!/usr/bin/env bash
# kratos-calamares-finalize + image branding/kernel guards (VM install test
# findings). Proves:
#   1. the build-time settings.conf patch puts kratos-finalize directly before
#      initramfs (so the initramfs reflects RESUME=none), idempotently, and fails
#      when it can't anchor;
#   2. on an installed-target tree: hibernation/resume is removed (initramfs
#      RESUME=none, no resume= on GRUB's command line), "discard" is stripped
#      from fstab and crypttab without touching anything else, fstrim.timer is
#      masked, and the installer is removed;
#   3. the image hooks select the KratosOS Calamares branding, brand the live
#      boot menu, keep exactly one kernel, and the systemd sleep config forbids
#      hibernation.
# shellcheck disable=SC2015,SC2016
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
inc="$here/../config/includes.chroot"
helper="$inc/usr/local/libexec/kratos/kratos-calamares-finalize"
desc="$inc/usr/lib/calamares/modules/kratos-finalize/module.desc"
hook="$here/../config/hooks/live/0100-kratos.hook.chroot"
sechook="$here/../config/hooks/live/0080-kratos-apt-security.hook.chroot"
binhook="$here/../config/hooks/live/0200-kratos-bootmenu.hook.binary"
brand="$inc/etc/calamares/branding/kratos"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

# ── 1. wiring + settings.conf patch ────────────────────────────────────────
[[ -x "$helper" ]] && pass "finalize helper is executable" || flunk "finalize helper missing or not executable"
if grep -q 'interface:[[:space:]]*"process"' "$desc" \
   && grep -q 'command:[[:space:]]*"/usr/local/libexec/kratos/kratos-calamares-finalize"' "$desc"; then
    pass "module.desc runs the finalize helper as a process job"
else
    flunk "module.desc does not run the finalize helper"
fi
grep -q -- "kratos-calamares-finalize --patch-settings /etc/calamares/settings.conf" "$hook" \
    && pass "image hook patches settings.conf for finalize" || flunk "image hook does not patch settings.conf for finalize"

cat > "$tmp/settings.conf" <<'EOF'
---
sequence:
- exec:
  - partition
  - grubcfg
  - bootloader
  - packages
  - initramfscfg
  - initramfs
  - umount
branding: debian
EOF
"$helper" --patch-settings "$tmp/settings.conf" >/dev/null
"$helper" --patch-settings "$tmp/settings.conf" >/dev/null
if [[ "$(grep -A1 -- '- kratos-finalize' "$tmp/settings.conf" | tail -1)" == "  - initramfs" ]] \
   && [[ "$(grep -c -- '- kratos-finalize' "$tmp/settings.conf")" == 1 ]] \
   && grep -q -- '  - initramfscfg' "$tmp/settings.conf"; then
    pass "kratos-finalize inserted once, directly before initramfs (not initramfscfg)"
else
    flunk "settings.conf patch wrong: $(tr '\n' ' ' < "$tmp/settings.conf")"
fi
printf -- '---\nsequence:\n- exec:\n  - partition\n' > "$tmp/noanchor.conf"
if "$helper" --patch-settings "$tmp/noanchor.conf" >/dev/null 2>&1; then
    flunk "patch succeeded without an initramfs step (build would ship without finalize)"
else
    pass "patch fails loudly without an initramfs step"
fi

# ── 2. finalize an installed-target tree ───────────────────────────────────
T="$tmp/target"; mkdir -p "$T/etc/default" "$T/boot/grub" "$T/usr/lib/calamares/modules/kratos-unmount" \
    "$T/usr/local/libexec/kratos" "$T/etc/calamares"
cat > "$T/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash resume=/dev/mapper/luks-1234"
GRUB_CMDLINE_LINUX="resume=UUID=abcd cryptdevice=x"
EOF
: > "$T/boot/grub/grub.cfg"
cat > "$T/etc/fstab" <<'EOF'
# /etc/fstab: discard in a comment stays
UUID=aaaa  /      ext4  defaults,noatime,discard  0 1
UUID=bbbb  /boot  ext4  defaults,noatime          0 2
/dev/mapper/luks-swap  swap  swap  discard  0 0
EOF
cat > "$T/etc/crypttab" <<'EOF'
luks-root UUID=1111 /crypto_keyfile.bin luks,keyscript=/bin/cat,discard
luks-swap UUID=2222 /crypto_keyfile.bin luks,keyscript=/bin/cat
EOF
: > "$T/usr/lib/calamares/modules/kratos-unmount/module.desc"
: > "$T/usr/local/libexec/kratos/kratos-calamares-unmount"
: > "$T/usr/local/libexec/kratos/kratos-other-tool"
out="$(KRATOS_FINALIZE_SKIP_CHROOT=1 "$helper" --root "$T" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "finalize exits 0" || flunk "finalize exit $rc: $out"

[[ "$(cat "$T/etc/initramfs-tools/conf.d/resume" 2>/dev/null)" == "RESUME=none" ]] \
    && pass "initramfs RESUME=none (no resume-device wait at boot)" || flunk "initramfs resume not disabled"
if ! grep -q 'resume=' "$T/etc/default/grub" \
   && grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' "$T/etc/default/grub" \
   && grep -qx 'GRUB_CMDLINE_LINUX="cryptdevice=x"' "$T/etc/default/grub"; then
    pass "resume= stripped from GRUB's command line, other parameters kept"
else
    flunk "grub cmdline wrong: $(grep CMDLINE "$T/etc/default/grub" | tr '\n' ' ')"
fi
grep -q 'update-grub' <<<"$out" && pass "grub.cfg is regenerated" || flunk "update-grub not run"

# The form Calamares actually writes (VM install test): SINGLE quotes with
# resume= last. Treating only " as a quote ate the closing ' and left an
# unterminated string, so grub-mkconfig dropped the hardening parameters that
# /etc/default/grub.d/kratos.cfg appends. The edited file must still parse and
# yield the right values, with the drop-in's additions intact.
T2="$tmp/target2"; mkdir -p "$T2/etc/default/grub.d" "$T2/boot/grub"
cat > "$T2/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_DISTRIBUTOR='KratosOS'
GRUB_CMDLINE_LINUX_DEFAULT='quiet cryptdevice=UUID=a1:luks-a1 root=/dev/mapper/luks-a1 splash resume=/dev/mapper/luks-b2'
GRUB_CMDLINE_LINUX=""
GRUB_ENABLE_CRYPTODISK=y
EOF
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT slab_nomerge apparmor=1"' \
    > "$T2/etc/default/grub.d/kratos.cfg"
: > "$T2/boot/grub/grub.cfg"
KRATOS_FINALIZE_SKIP_CHROOT=1 "$helper" --root "$T2" >/dev/null 2>&1
got="$(sh -c '. "$1"; . "$2"; printf "%s|%s" "$GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_ENABLE_CRYPTODISK"' _ \
       "$T2/etc/default/grub" "$T2/etc/default/grub.d/kratos.cfg" 2>&1)"
want='quiet cryptdevice=UUID=a1:luks-a1 root=/dev/mapper/luks-a1 splash slab_nomerge apparmor=1|y'
if sh -n "$T2/etc/default/grub" && [[ "$got" == "$want" ]] && [[ ! -e "$T2/etc/default/grub.kratos-orig" ]]; then
    pass "single-quoted (Calamares) cmdline: resume= stripped, file parses, hardening drop-in still applies"
else
    flunk "single-quoted cmdline broken: got [$got]; file: $(grep CMDLINE "$T2/etc/default/grub" | tr '\n' ' ')"
fi

if grep -Eq '^UUID=aaaa +/ +ext4 +defaults,noatime +0 +1$' "$T/etc/fstab" \
   && grep -Eq '^/dev/mapper/luks-swap +swap +swap +defaults +0 +0$' "$T/etc/fstab" \
   && grep -q '^# /etc/fstab: discard in a comment stays$' "$T/etc/fstab" \
   && grep -q '^UUID=bbbb  /boot  ext4  defaults,noatime          0 2$' "$T/etc/fstab"; then
    pass "fstab: discard removed, emptied options -> defaults, other lines untouched"
else
    flunk "fstab wrong: $(cat "$T/etc/fstab")"
fi
if grep -Eq '^luks-root +UUID=1111 +/crypto_keyfile.bin +luks,keyscript=/bin/cat$' "$T/etc/crypttab" \
   && grep -q '^luks-swap UUID=2222 /crypto_keyfile.bin luks,keyscript=/bin/cat$' "$T/etc/crypttab"; then
    pass "crypttab: discard removed, unlock options kept"
else
    flunk "crypttab wrong: $(cat "$T/etc/crypttab")"
fi
[[ "$(readlink "$T/etc/systemd/system/fstrim.timer")" == /dev/null ]] \
    && pass "fstrim.timer masked" || flunk "fstrim.timer not masked"
if [[ ! -e "$T/etc/calamares" && ! -e "$T/usr/lib/calamares" \
      && ! -e "$T/usr/local/libexec/kratos/kratos-calamares-unmount" \
      && -e "$T/usr/local/libexec/kratos/kratos-other-tool" ]] \
   && grep -q 'apt-get -y purge calamares' <<<"$out"; then
    pass "installer purged from the target; other KratosOS tools kept"
else
    flunk "installer not cleanly removed: $out"
fi

# No target mounted: a no-op that never fails the install.
if KRATOS_FINALIZE_SKIP_CHROOT=1 "$helper" >/dev/null 2>&1; then
    pass "no Calamares target -> harmless no-op"
else
    flunk "finalize fails when no target is mounted"
fi

# ── 3. image hooks and shipped config ──────────────────────────────────────
sleepc="$inc/etc/systemd/sleep.conf.d/kratos-no-hibernate.conf"
grep -qx 'AllowHibernation=no' "$sleepc" && grep -qx 'AllowHybridSleep=no' "$sleepc" \
    && grep -qx 'AllowSuspendThenHibernate=no' "$sleepc" \
    && pass "systemd sleep config forbids hibernation" || flunk "hibernation not disabled in sleep.conf.d"

grep -q "branding: kratos" "$hook" && grep -q 'branding/kratos/branding.desc' "$hook" \
    && pass "image hook selects (and verifies) the kratos Calamares branding" || flunk "kratos branding not selected"
if grep -q '^componentName:[[:space:]]*kratos$' "$brand/branding.desc" \
   && ! grep -qi 'debian' <(grep -v '^#' "$brand/branding.desc"); then
    pass "Calamares branding.desc is KratosOS (no Debian strings)"
else
    flunk "Calamares branding.desc still Debian"
fi
missing=""
for img in $(grep -oE '"[^"]+\.png"' "$brand/branding.desc" | tr -d '"' | sort -u) \
           $(grep -oE 'source: "[^"]+"' "$brand/show.qml" | sed 's/source: //; s/"//g'); do
    [[ -f "$brand/$img" ]] || missing+=" $img"
done
[[ -z "$missing" ]] && pass "every image the branding references exists" || flunk "branding images missing:$missing"

grub_bg="$inc/usr/share/kratos-assets/grub-background.png"
grubcfg="$inc/etc/default/grub.d/kratos.cfg"
if grep -q '^GRUB_BACKGROUND="/usr/share/kratos-assets/grub-background.png"$' "$grubcfg" \
   && [[ "$(head -c 8 "$grub_bg" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]] \
   && [[ "$(od -An -tu1 -j24 -N1 "$grub_bg" | tr -d ' ')" == 8 ]]; then
    pass "installed GRUB uses the KratosOS background (8-bit PNG GRUB can read)"
else
    flunk "GRUB background not set or not an 8-bit PNG"
fi
splash="$inc/usr/share/kratos-assets/live-splash.png"
if [[ -x "$binhook" ]] && grep -q 'live-splash.png' "$binhook" \
   && [[ "$(od -An -tu4 --endian=big -j16 -N8 "$splash" | tr -s ' ')" == " 640 480" ]]; then
    pass "live boot menu hook brands a 640x480 splash"
else
    flunk "live boot menu branding hook/splash wrong"
fi
# The logo lives in the splash's top third, so nothing may be drawn there:
# GRUB's theme title line is blanked (it overlapped the logo in the VM test).
if grep -q "title-text:" "$binhook" && grep -q '\\1""' "$binhook"; then
    pass "live GRUB theme title is blanked (no text over the logo)"
else
    flunk "live boot menu branding hook/splash wrong"
fi

if grep -q "dpkg-query -W -f='\${Depends}" "$sechook" && grep -q 'apt-get -y purge \$old' "$sechook" \
   && grep -q 'expected exactly 1' "$sechook"; then
    pass "security hook keeps exactly one kernel (and fails the build otherwise)"
else
    flunk "security hook does not prune superseded kernels"
fi

exit "$fail"
