#!/usr/bin/env bash
# kratos-calamares-unmount: the installer's final unmount must not depend on
# Calamares' hard-coded 10-second `umount -lv` (VM install test: a good
# ext4-on-LUKS install was reported "could not be unmounted. Installation
# failed." because the last unmount took >10 s). Proves:
#   1. the build-time settings.conf patch puts kratos-unmount directly before
#      umount, is idempotent, and fails loudly when it can't anchor;
#   2. (root) the target tree is really unmounted and its data flushed, a busy
#      mount is waited for, a stuck one is detached, and what is left for
#      Calamares' own capped `umount -lv <root>` unmounts instantly.
# shellcheck disable=SC2015,SC2317
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
inc="$here/../config/includes.chroot"
helper="$inc/usr/local/libexec/kratos/kratos-calamares-unmount"
desc="$inc/usr/lib/calamares/modules/kratos-unmount/module.desc"
hook="$here/../config/hooks/live/0100-kratos.hook.chroot"
tmp="$(mktemp -d)"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

cleanup() {
    [[ -n "${holder:-}" ]] && kill "$holder" 2>/dev/null
    if [[ $EUID -eq 0 ]]; then
        findmnt -Rrn -o TARGET "$tmp" 2>/dev/null | sort -r | while read -r m; do umount -l "$m" 2>/dev/null; done
        [[ -n "${loopdev:-}" ]] && losetup -d "$loopdev" 2>/dev/null
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

# ── 1. wiring + settings.conf patch ────────────────────────────────────────
[[ -x "$helper" ]] && pass "helper is executable" || flunk "helper missing or not executable"
if grep -q 'interface:[[:space:]]*"process"' "$desc" \
   && grep -q "command:[[:space:]]*\"/usr/local/libexec/kratos/kratos-calamares-unmount\"" "$desc" \
   && grep -Eq 'timeout:[[:space:]]*[0-9]{3,}' "$desc"; then
    pass "module.desc runs the helper as a process job with a long timeout"
else
    flunk "module.desc does not run the helper with a long timeout"
fi
grep -q -- "kratos-calamares-unmount --patch-settings /etc/calamares/settings.conf" "$hook" \
    && pass "image hook patches settings.conf" || flunk "image hook does not patch settings.conf"

# Shape of calamares-settings-debian 13's settings.conf exec sequence.
cat > "$tmp/settings.conf" <<'EOF'
---
modules-search: [ local, /usr/lib/calamares/modules ]
sequence:
- show:
  - welcome
  - partition
- exec:
  - partition
  - mount
  - unpackfs
  - initramfs
  - sources-media-unmount
  - sources-final
  - umount
- show:
  - finished
branding: debian
EOF
"$helper" --patch-settings "$tmp/settings.conf" >/dev/null
"$helper" --patch-settings "$tmp/settings.conf" >/dev/null   # idempotent
if [[ "$(grep -c -- '- kratos-unmount$' "$tmp/settings.conf")" == 1 ]] \
   && grep -A1 -- '  - sources-final$' "$tmp/settings.conf" | grep -q -- '  - kratos-unmount$' \
   && grep -A1 -- '  - kratos-unmount$' "$tmp/settings.conf" | grep -q -- '  - umount$'; then
    pass "kratos-unmount inserted once, directly before umount (same indent)"
else
    flunk "settings.conf patch wrong:"; sed 's/^/        /' "$tmp/settings.conf"
fi
printf -- '---\nsequence:\n- exec:\n  - partition\n' > "$tmp/noumount.conf"
if "$helper" --patch-settings "$tmp/noumount.conf" >/dev/null 2>&1; then
    flunk "patch 'succeeded' on a settings.conf with no umount step"
else
    pass "patch fails loudly when there is no umount step to anchor on"
fi

# ── 2. real unmount behaviour (needs root) ─────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "  SKIP  mount tests (need root)"
    exit "$fail"
fi

root="$tmp/calamares-root-test"
mkdir -p "$root"
# Target root on a real ext4 loop image when possible (proves data is flushed
# and the image is cleanly unmounted), else tmpfs.
if command -v mkfs.ext4 >/dev/null && truncate -s 64M "$tmp/disk.img" \
   && mkfs.ext4 -q -F "$tmp/disk.img" && loopdev=$(losetup -f --show "$tmp/disk.img"); then
    mount "$loopdev" "$root"
else
    loopdev=""; mount -t tmpfs t "$root"
fi
mkdir -p "$root/boot" "$root/proc" "$root/dev" "$root/run"
mount -t tmpfs boot "$root/boot"
mount -t proc proc "$root/proc"
mount -t tmpfs devtmp "$root/dev"; mkdir -p "$root/dev/pts"; mount -t tmpfs pts "$root/dev/pts"
mount -t tmpfs run1 "$root/run"; mount -t tmpfs run2 "$root/run"     # stacked
echo "installed" > "$root/etc-marker"

# Hold the target busy for ~3 s (like an auto-mounter/file manager would).
( cd "$root/boot" && exec sleep 3 ) & holder=$!
sleep 0.3
start=$SECONDS
out=$(KRATOS_UNMOUNT_PAUSE=0.5 "$helper" "$root" 2>&1); rc=$?
holder=""
left=$(findmnt -Rrn -o TARGET,SOURCE,FSTYPE "$root")
if [[ $rc -eq 0 && "$left" == "$root kratos-unmounted tmpfs" ]]; then
    pass "whole target tree unmounted (busy mount waited for, stacked mounts too)"
else
    flunk "target not cleanly unmounted (rc=$rc, after $((SECONDS - start))s):"
    printf '%s\n%s\n' "$out" "$left" | sed 's/^/        /'
fi
if echo "$out" | grep -q "detaching"; then
    flunk "a briefly-busy mount was detached lazily instead of waited for"
else
    pass "briefly-busy mount was waited for, not lazily detached"
fi
# What Calamares' own umount job then runs, with its 10 s cap.
if timeout 10 umount -lv "$root" >/dev/null 2>&1 && ! mountpoint -q "$root"; then
    pass "Calamares' capped 'umount -lv <root>' now succeeds at once"
else
    flunk "Calamares' 'umount -lv <root>' would still fail"
fi
if [[ -n "$loopdev" ]]; then
    if e2fsck -fn "$loopdev" >/dev/null 2>&1; then
        pass "target filesystem is clean after unmount"
    else
        flunk "target filesystem not clean after unmount"
    fi
    mount -o ro "$loopdev" "$root"
    [[ "$(cat "$root/etc-marker" 2>/dev/null)" == installed ]] \
        && pass "data written before unmount is on disk" || flunk "data lost across unmount"
    umount "$root"
fi

# A mount that NEVER frees up: bounded wait, then lazy detach; still succeeds.
mount -t tmpfs t "$root"; mkdir -p "$root/boot"; mount -t tmpfs boot "$root/boot"
( cd "$root/boot" && exec sleep 60 ) & holder=$!
sleep 0.3
out=$(KRATOS_UNMOUNT_TRIES=3 KRATOS_UNMOUNT_PAUSE=0.2 timeout 30 "$helper" "$root" 2>&1); rc=$?
left=$(findmnt -Rrn -o TARGET,SOURCE "$root")
if [[ $rc -eq 0 && "$left" == "$root kratos-unmounted" ]] && echo "$out" | grep -q "detaching"; then
    pass "permanently busy mount: bounded wait, holder reported, lazily detached"
else
    flunk "permanently busy mount not handled (rc=$rc):"; printf '%s\n%s\n' "$out" "$left" | sed 's/^/        /'
fi
kill "$holder" 2>/dev/null; holder=""
umount "$root" 2>/dev/null

# Default discovery: only /tmp/calamares-root-* mounts, and none -> no-op success.
if out=$(PATH="$PATH" "$helper" 2>&1) && echo "$out" | grep -qE "nothing to do|unmounted"; then
    pass "no-argument run discovers targets (no-op when none mounted)"
else
    flunk "no-argument run failed: $out"
fi

exit "$fail"
