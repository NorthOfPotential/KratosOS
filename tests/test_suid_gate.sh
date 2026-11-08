#!/usr/bin/env bash
# The privileged-binary release gate (suid-audit.sh + suid-allowlist.txt):
# an unexpected SUID/SGID/cap binary must FAIL the build; an allowlisted one
# must not. Also guards that components we KNOW ship setuid (firejail) stay on
# the allowlist, so flipping the CI gate to blocking can't spuriously break.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
audit="$here/suid-audit.sh"
allow="$here/suid-allowlist.txt"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

echo "— firejail (SUID by design, we ship it) is on the allowlist —"
if grep -qxF '/usr/bin/firejail' "$allow"; then pass "firejail allowlisted"; else flunk "firejail missing from allowlist (gate would block the build)"; fi

echo "— an UNEXPECTED setuid binary fails the gate —"
root="$(mktemp -d)"; mkdir -p "$root/usr/bin"
: > "$root/usr/bin/firejail"; chmod 4755 "$root/usr/bin/firejail"   # allowlisted
: > "$root/usr/bin/evil";     chmod 4755 "$root/usr/bin/evil"       # not allowlisted
if "$audit" "$root" >/dev/null 2>&1; then
    flunk "audit passed despite an unexpected SUID binary"
else
    pass "audit fails closed on an unexpected SUID binary"
fi
# The release workflow runs the audit through tee: the pipeline MUST keep
# the status of the audit, not just the exit code of tee.
if bash -euo pipefail -c '"$1" "$2" | tee "$3"' bash "$audit" "$root" "$root/inventory.txt" >/dev/null 2>&1; then
    flunk "release pipeline hid an unexpected privileged binary behind tee"
else
    pass "release pipeline preserves audit failures through tee"
fi
rm -rf "$root"

echo "— GitHub Actions uses a pipefail-aware shell for its release gate —"
if grep -A 15 'name: Privileged-binary inventory' "$here/../.github/workflows/ci.yml" \
    | grep -qE '^[[:space:]]+shell: bash$'; then
    pass "privileged inventory step has shell: bash"
else
    flunk "privileged inventory step could mask a failed audit"
fi

echo "— an image with only allowlisted privileged binaries passes —"
root="$(mktemp -d)"; mkdir -p "$root/usr/bin"
: > "$root/usr/bin/firejail"; chmod 4755 "$root/usr/bin/firejail"
: > "$root/usr/bin/sudo";     chmod 4755 "$root/usr/bin/sudo"
if "$audit" "$root" >/dev/null 2>&1; then
    pass "audit passes when everything is allowlisted"
else
    flunk "audit flagged an allowlisted-only image"
fi
echo "— scanner failures and absent allowlist must NOT permit a release —"
tools="$(mktemp -d)"
printf '#!/bin/sh\nexit 42\n' > "$tools/getcap"
chmod 755 "$tools/getcap"
if PATH="$tools:$PATH" "$audit" "$root" >/dev/null 2>&1; then
    flunk "privileged inventory passed after the capability scanner failed"
else
    pass "capability scanner failure blocks release"
fi
if "$audit" "$root" "$root/does-not-exist.allowlist" >/dev/null 2>&1; then
    flunk "privileged inventory passed without an allowlist"
else
    pass "missing allowlist blocks release"
fi
rm -rf "$tools"
rm -rf "$root"

echo "— privileged binaries the OS does not need are removed, not allowlisted —"
hook="$here/../config/hooks/live/0100-kratos.hook.chroot"
pin="$here/../config/includes.chroot_before_packages/etc/apt/preferences.d/kratos-no-mta.pref"
for p in /usr/sbin/exim4 /usr/sbin/ssmtp /usr/sbin/pppd /usr/bin/ntfs-3g /usr/libexec/spice-client-glib-usb-acl-helper \
         /usr/bin/chfn /usr/bin/chsh /usr/lib/openssh/ssh-keysign; do
    if grep -qxF "$p" "$allow"; then flunk "$p is allowlisted (it should be removed/de-privileged instead)"
    else pass "$p is not on the allowlist"; fi
done
if [[ -f "$pin" ]] && grep -qE '^Package: exim4\*' "$pin" && grep -qE '^Pin-Priority: -1' "$pin"; then
    pass "apt pin keeps an MTA (exim4) out of the image and the installed system"
else flunk "no apt pin blocking exim4"; fi
# Blocking exim4 alone is not enough: bsd-mailx hard-depends on ANY MTA, so apt
# substituted ssmtp (CI run #242). The pin must cover the mailx clients that
# pull an MTA in and the other MTA providers too.
for pkg in ssmtp nullmailer dma msmtp-mta opensmtpd bsd-mailx s-nail mailutils; do
    if awk -v p="$pkg" '/^Package:/ {for (i = 2; i <= NF; i++) if ($i == p) hit = 1}
                        /^Pin-Priority: -1/ && hit {ok = 1} /^$/ {hit = 0} END {exit !ok}' "$pin"; then
        pass "apt pin blocks $pkg"
    else flunk "apt pin does not block $pkg (apt could substitute it as the MTA)"; fi
done
if grep -qE 'apt-get purge -y' "$hook" && grep -q "'exim4\*'" "$hook" && grep -qw ssmtp "$hook"; then
    pass "build hook purges exim4 as a backstop"
else flunk "build hook does not purge exim4"; fi
for p in /usr/sbin/pppd /usr/bin/ntfs-3g /usr/libexec/spice-client-glib-usb-acl-helper \
         /usr/bin/chfn /usr/bin/chsh /usr/lib/openssh/ssh-keysign; do
    if grep -qE "^root (root|dip) +07[0-9]{2} $p$" "$hook"; then
        pass "setuid stripped (dpkg-statoverride) from $p"
    else flunk "setuid not stripped from $p"; fi
done

exit "$fail"
