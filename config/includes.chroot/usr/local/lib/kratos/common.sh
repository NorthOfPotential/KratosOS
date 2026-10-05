# shellcheck shell=bash
# Shared helpers for the kratos tool.

KRATOS_ETC="${KRATOS_ETC:-/etc/kratos}"
KRATOS_STATE="${KRATOS_STATE:-/var/lib/kratos}"
KRATOS_RUN="${KRATOS_RUN:-/run/kratos}"
KRATOS_MODES=(tor vpn-tor vpn offline)
TOR_CONTROL_SOCKET="/run/tor/control"
TOR_COOKIE="/run/tor/control.authcookie"

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
err()  { printf '%skratos:%s %s\n' "$RED" "$RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
    [[ $EUID -eq 0 ]] || die "this command needs root; run: sudo kratos $*"
}

need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "missing required program: $c"
    done
}

confirm() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

is_valid_mode() {
    local m
    for m in "${KRATOS_MODES[@]}"; do
        [[ "$m" == "$1" ]] && return 0
    done
    return 1
}

saved_mode() {
    local m
    m="$(cat "$KRATOS_STATE/mode" 2>/dev/null || true)"
    if is_valid_mode "$m"; then echo "$m"; else echo tor; fi
}

# Send commands to Tor's control socket, authenticating with the cookie.
tor_control() {
    need_cmd nc od
    [[ -S "$TOR_CONTROL_SOCKET" && -r "$TOR_COOKIE" ]] || return 1
    local cookie
    cookie="$(od -An -tx1 -v "$TOR_COOKIE" | tr -d ' \n')"
    {
        printf 'AUTHENTICATE %s\r\n' "$cookie"
        local c
        for c in "$@"; do printf '%s\r\n' "$c"; done
        printf 'QUIT\r\n'
    } | nc -U -w 5 "$TOR_CONTROL_SOCKET"
}
