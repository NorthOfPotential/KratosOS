#!/usr/bin/env bash
# The privileged GUI surface is split per polkit action (findings R6-12/R6-25):
# each kratos subcommand the tray can run has its OWN helper + action, so a
# cached authorization for one surface never covers another, and the
# destructive arbitrary-path surfaces (migrate, shred) are never retained.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../config/includes.chroot"
pol="$root/usr/share/polkit-1/actions/org.kratos.policy"
helpers="$root/usr/local/libexec/kratos"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

echo "— polkit policy is well-formed and split per surface —"
if command -v xmllint >/dev/null && xmllint --noout "$pol" 2>/dev/null; then
    pass "org.kratos.policy is valid XML"
else
    command -v xmllint >/dev/null && flunk "org.kratos.policy is not valid XML" || echo "  SKIP  xmllint not available"
fi

# There must be NO single action pointing at the whole kratos binary anymore.
if grep -q '>/usr/local/bin/kratos<' "$pol"; then
    flunk "a polkit action still covers the whole /usr/local/bin/kratos (catch-all not removed)"
else
    pass "no catch-all action over the whole kratos binary"
fi

# Each surface: action id, its helper exec.path, and the helper fixes one subcommand.
check_action() {  # <action-id> <helper-name> <expected-auth>
    local id="$1" helper="$2" auth="$3" hp="$helpers/$2"
    if grep -q "id=\"$id\"" "$pol"; then pass "action $id exists"; else flunk "action $id missing"; fi
    if grep -q "exec.path\">/usr/local/libexec/kratos/$helper<" "$pol"; then
        pass "$id points at its own helper ($helper)"
    else
        flunk "$id does not point at /usr/local/libexec/kratos/$helper"
    fi
    local got
    got="$(awk -v id="$id" '
        $0 ~ "id=\""id"\"" {inact=1}
        inact && /allow_active/ {gsub(/.*<allow_active>|<\/allow_active>.*/,""); print; exit}
    ' "$pol")"
    if [[ "$got" == "$auth" ]]; then pass "$id uses $auth"; else flunk "$id uses '$got', expected '$auth'"; fi
    if [[ -f "$hp" && -x "$hp" ]]; then pass "$helper exists and is executable"; else flunk "$helper missing/not executable"; fi
}

# A simple helper fixes one subcommand with a bare exec.
check_fixed_sub() {  # <helper-name> <subcommand>
    if grep -qE "^exec /usr/local/bin/kratos $2 \"\\\$@\"" "$helpers/$1"; then
        pass "$1 fixes the '$2' subcommand"
    else
        flunk "$1 does not fix the '$2' subcommand"
    fi
}

echo "— low-risk surfaces keep a cached auth (tray usability) —"
check_action org.kratos.net     kratos-net     auth_admin_keep ; check_fixed_sub kratos-net mode
check_action org.kratos.stealth kratos-stealth auth_admin_keep
check_action org.kratos.status  kratos-status  auth_admin_keep

echo "— destructive / provisioning surfaces are NEVER retained —"
check_action org.kratos.migrate       kratos-migrate       auth_admin ; check_fixed_sub kratos-migrate migrate
check_action org.kratos.shred         kratos-shred         auth_admin ; check_fixed_sub kratos-shred shred
check_action "org.kratos.stealth-admin" kratos-stealth-admin auth_admin

echo "— the everyday Stealth helper allows ONLY on/off/view (setup/reset go to the admin helper, R8-16) —"
sh="$helpers/kratos-stealth"
if grep -qE 'on\|off\|view\) +exec ' "$sh" && ! grep -qE '(setup|reset).*exec ' "$sh"; then
    pass "kratos-stealth is limited to on|off|view"
else
    flunk "kratos-stealth is not limited to on|off|view"
fi
adm="$helpers/kratos-stealth-admin"
if grep -qE 'setup\|reset\)' "$adm"; then
    pass "kratos-stealth-admin handles setup|reset (non-retained action)"
else
    flunk "kratos-stealth-admin does not handle setup|reset"
fi
# The read-only status helper must not accept anything but 'status'.
if grep -qE 'status\|"\"\)' "$helpers/kratos-status" || grep -qE 'status\|""\)' "$helpers/kratos-status"; then
    pass "kratos-status is limited to the read-only status subcommand"
else
    flunk "kratos-status is not limited to status"
fi

echo "— the Stealth Desktop launcher uses the helper via pkexec (not bare kratos) —"
desk="$root/usr/share/applications/kratos-stealth.desktop"
if grep -qE '^Exec=pkexec /usr/local/libexec/kratos/kratos-stealth view' "$desk"; then
    pass "launcher runs the stealth helper under pkexec"
else
    flunk "launcher does not use the pkexec stealth helper"
fi

exit "$fail"
