# shellcheck shell=bash
# Shared helpers for the kratos tool.

KRATOS_ETC="${KRATOS_ETC:-/etc/kratos}"
KRATOS_STATE="${KRATOS_STATE:-/var/lib/kratos}"
KRATOS_RUN="${KRATOS_RUN:-/run/kratos}"
KRATOS_MODES=(normal vpn offline)

# shellcheck disable=SC2034  # colours are used by the other modules
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

# Serialize mutating operations (mode switches, Stealth on/off, shaping, ...)
# so two concurrent invocations can never interleave and leave the firewall,
# network or vault in a mixed state. Non-blocking: a second operation fails
# fast rather than queueing. `kratos panic` deliberately never calls this, so
# it always runs even while another operation holds the lock.
serialize() {
    [[ -n "${_KRATOS_LOCKED:-}" ]] && return 0   # already held in this process
    command -v flock >/dev/null 2>&1 || return 0 # no flock: skip rather than fail
    install -d -m 755 "$KRATOS_RUN" 2>/dev/null || true
    exec {_KRATOS_LOCK_FD}>"$KRATOS_RUN/lock" || return 0
    flock -n "$_KRATOS_LOCK_FD" \
        || die "another kratos operation is in progress; try again in a moment"
    _KRATOS_LOCKED=1
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
    if is_valid_mode "$m"; then echo "$m"; else echo "${DEFAULT_MODE:-normal}"; fi
}

# Load kratos.conf as DATA, never as code. The file is parsed line by line as
# strict KEY=value pairs; it is never sourced, so a tampered config can set
# values but can NEVER execute commands as root. Only known keys are accepted,
# and only after verifying the file (and its directory) are root-owned and not
# writable by anyone else.
#   key   must match DEFAULT_MODE or one of the STEALTH_/CORR_/GUARD_ families
#   value is taken literally (quotes stripped, trailing comment removed) and
#         must be drawn from a safe character set — no command substitution,
#         no shell metacharacters are ever interpreted.
load_config() {
    local conf="$KRATOS_ETC/kratos.conf"
    [[ -r "$conf" ]] || return 0
    # Refuse a config that an unprivileged user could have tampered with.
    if ! _is_root_owned_secure "$KRATOS_ETC" || ! _is_root_owned_secure "$conf"; then
        warn "ignoring $conf: it or its directory is not root-owned/secure"
        return 0
    fi
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                       # strip comments
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        key="${key//[[:space:]]/}"               # trim whitespace around key
        val="${val#"${val%%[![:space:]]*}"}"     # ltrim value
        val="${val%"${val##*[![:space:]]}"}"     # rtrim value
        val="${val%\"}"; val="${val#\"}"         # strip optional quotes
        val="${val%\'}"; val="${val#\'}"
        [[ "$key" =~ ^(DEFAULT_MODE|STEALTH_[A-Z0-9_]+|CORR_[A-Z0-9_]+|GUARD_[A-Z0-9_]+)$ ]] || continue
        # Values are config scalars: letters, digits and a few punctuation marks
        # used by sizes/rates/host:port. Anything else is rejected, not run.
        [[ "$val" =~ ^[A-Za-z0-9_.:/,%+@~-]*$ ]] || { warn "ignoring unsafe value for $key in $conf"; continue; }
        printf -v "$key" '%s' "$val"
    done < "$conf"
    return 0
}

# True if $1 is owned by root and not writable by group or other.
_is_root_owned_secure() {
    local info owner mode
    info="$(stat -c '%u %a' "$1" 2>/dev/null)" || return 0  # missing: nothing to trust
    owner="${info%% *}"; mode="${info##* }"
    [[ "$owner" == 0 ]] || return 1
    # last two octal digits are group/other perms; reject any write bit (2)
    (( (0$mode & 022) == 0 ))
}

# The desktop user who invoked sudo/pkexec (empty if unknown).
desktop_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    elif [[ -n "${PKEXEC_UID:-}" ]]; then
        id -nu "$PKEXEC_UID"
    fi
}
