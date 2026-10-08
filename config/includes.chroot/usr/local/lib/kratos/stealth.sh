# shellcheck shell=bash
# Stealth Mode: an isolated Whonix persona environment on top of the normal
# desktop.
#
#   ON:  host lockdown -> unlock vault -> firewall -> Gateway -> Workstation
#   OFF: Workstation off -> Gateway off -> firewall -> wipe artifacts
#        -> lock vault -> undo host lockdown
#
# The VMs and their networks are *transient* libvirt objects created from XML
# stored inside the encrypted vault. When Stealth Mode is off and the vault is
# locked, libvirt has no record of them.

WHONIX_SIGNING_FPR="916B8D99C38EAF5E8ADC7A2A8D66066A2EEACCDA"

VAULT_IMG="$KRATOS_STATE/stealth.vault"
VAULT_MAPPER="kratos-stealth"
VAULT_MNT="$KRATOS_STATE/vault"
# Ephemeral vault key for the zero-touch / amnesic flow. It lives on a dedicated
# ramfs (NEVER swapped, unlike tmpfs — so the key can't leak to disk via swap
# during provisioning, before host_lockdown's swapoff), under $KRATOS_RUN which
# is itself tmpfs, so nothing persists across a reboot: on a live boot the whole
# persona is amnesic by construction. Persistent installs set
# STEALTH_VAULT_PERSIST=yes and use a passphrase instead.
VAULT_KEYDIR="$KRATOS_RUN/keys"
VAULT_KEYFILE="$VAULT_KEYDIR/vault.key"
VAULT_XML="$VAULT_MNT/libvirt"
STEALTH_FLAG="$KRATOS_RUN/stealth.active"
STEALTH_ERROR="$KRATOS_RUN/stealth.error"
STEALTH_UNDO="$KRATOS_RUN/stealth.undo"
STEALTH_NFT="$KRATOS_ETC/stealth.nft"
HARDEN="$KRATOS_LIB/harden-whonix.py"
SPICE_DIR="$KRATOS_RUN/spice"
# Dedicated unprivileged user that owns the persona display and runs the
# viewer in its own login session, isolated from the normal desktop user.
STEALTH_USER="${STEALTH_USER:-kstealth}"
GW="kx-gw"
WS="kx-ws"

virsh_() { virsh -q -c qemu:///system "$@"; }

stealth_is_active() { [[ -e "$STEALTH_FLAG" ]]; }

vault_is_open() { [[ -e "/dev/mapper/$VAULT_MAPPER" ]]; }

# Passphrase given on stdin by the GUI (read once, since several steps need it).
# Empty means cryptsetup prompts on the terminal.
VAULT_PASS=""
read_stdin_pass() {
    IFS= read -r VAULT_PASS || true
    [[ -n "$VAULT_PASS" ]] || die "no passphrase on stdin"
}

# Run cryptsetup with the right key for the current vault mode.
#
# Amnesic mode (STEALTH_VAULT_PERSIST != yes, the default) ALWAYS uses the
# in-RAM ephemeral key and NEVER a user passphrase — even if one was handed in
# on stdin (finding R4-6). This is the authoritative enforcement: the tray/GUI
# cannot silently downgrade the amnesic design by prompting for a passphrase,
# and a persistence choice can't be made by whoever happens to type one.
# Only persistent mode (=yes) uses the GUI passphrase, falling back to an
# interactive prompt when none was supplied.
cryptsetup_pass() {
    if [[ "${STEALTH_VAULT_PERSIST:-no}" != yes ]]; then
        if [[ -r "$VAULT_KEYFILE" ]]; then
            cryptsetup "$@" --key-file "$VAULT_KEYFILE"
        else
            cryptsetup "$@"   # no ephemeral key yet (pre make_ephemeral_key)
        fi
    elif [[ -n "$VAULT_PASS" ]]; then
        printf '%s' "$VAULT_PASS" | cryptsetup "$@" --key-file -
    else
        cryptsetup "$@"
    fi
}

# Create the ephemeral vault key (amnesic flow) if it doesn't already exist.
# The runtime dir stays 0755 (listing it is harmless; the non-root tray reads
# stealth.active here); the KEY file itself is 0600 root.
stealth_make_ephemeral_key() {
    install -d -m 755 "$KRATOS_RUN"
    install -d -m 700 "$VAULT_KEYDIR"
    # Back the key dir with ramfs (unswappable). Best-effort: skip under the test
    # harness (no stray mounts in a tmpdir) and tolerate a missing ramfs.
    if [[ "${KRATOS_TEST:-}" != 1 ]] && ! mountpoint -q "$VAULT_KEYDIR"; then
        mount -t ramfs -o mode=700 ramfs "$VAULT_KEYDIR" \
            || warn "could not mount a ramfs for the vault key; it sits on tmpfs (swappable)"
    fi
    chmod 700 "$VAULT_KEYDIR"
    [[ -r "$VAULT_KEYFILE" ]] && return 0
    ( umask 077; head -c 64 /dev/urandom > "$VAULT_KEYFILE" )
    chmod 600 "$VAULT_KEYFILE"
}

# Drop the ephemeral key and release its ramfs (on teardown / panic).
stealth_clear_ephemeral_key() {
    [[ -e "$VAULT_KEYFILE" ]] && shred -u "$VAULT_KEYFILE" 2>/dev/null
    rm -f "$VAULT_KEYFILE" 2>/dev/null || true
    mountpoint -q "$VAULT_KEYDIR" 2>/dev/null && umount "$VAULT_KEYDIR" 2>/dev/null
    return 0
}

# Is the vault usable right now? It exists AND we can open it (a persistent
# passphrase vault, or an ephemeral vault whose in-RAM key is still present).
stealth_is_provisioned() {
    [[ -e "$VAULT_IMG" ]] || return 1
    [[ "${STEALTH_VAULT_PERSIST:-no}" == yes || -r "$VAULT_KEYFILE" ]]
}

vault_open() {
    vault_is_open || cryptsetup_pass open "$VAULT_IMG" "$VAULT_MAPPER" \
        || die "could not unlock the stealth vault"
    # 0700 root: even while unlocked, no other user can enter the vault or read
    # the VM disks, which hold the persona's whole filesystem.
    install -d -m 700 "$VAULT_MNT"
    chown root:root "$VAULT_MNT"
    mountpoint -q "$VAULT_MNT" \
        || mount -o nodev,nosuid,noexec "/dev/mapper/$VAULT_MAPPER" "$VAULT_MNT" \
        || die "could not mount the stealth vault"
    chmod 700 "$VAULT_MNT"
}

vault_close() {
    sync
    if mountpoint -q "$VAULT_MNT"; then
        # Normal shutdown is FAIL-CLOSED: a busy mount is an error to surface,
        # not something to hide behind a lazy unmount (which detaches the name
        # while references — and the plaintext mapping — may still be live).
        # Lazy unmount is reserved for the panic path (stealth_kill).
        if ! umount "$VAULT_MNT"; then
            bad "vault is still busy; refusing to lazy-unmount (run 'kratos panic' to force it down)"
            return 1
        fi
    fi
    if vault_is_open; then
        cryptsetup close "$VAULT_MAPPER" || { bad "vault could not be locked"; return 1; }
    fi
}

vault_create() {
    info "Creating the ${STEALTH_VAULT_SIZE} encrypted stealth vault."
    info "Use a passphrase you have never used anywhere else."
    install -d -m 755 "$KRATOS_STATE"
    fallocate -l "$STEALTH_VAULT_SIZE" "$VAULT_IMG"
    chmod 600 "$VAULT_IMG"
    local verify=()
    [[ -z "$VAULT_PASS" ]] && verify=(--verify-passphrase)
    cryptsetup_pass luksFormat --batch-mode --type luks2 --pbkdf argon2id "${verify[@]}" "$VAULT_IMG" \
        || { rm -f "$VAULT_IMG"; die "vault creation failed"; }
    cryptsetup_pass open "$VAULT_IMG" "$VAULT_MAPPER" || die "could not unlock the new vault"
    mkfs.ext4 -q -L kxvault "/dev/mapper/$VAULT_MAPPER"
    vault_open
}

# Check a Whonix download against the pinned signing key. Returns non-zero (and
# prints why) instead of dying, so callers can probe a cached image.
_whonix_verify_ok() {
    local archive="$1" sig="$2" key="$3" gnupg result=ok
    [[ -r "$archive" && -r "$sig" ]] || { echo "missing archive or signature" >&2; return 1; }
    gnupg="$(mktemp -d)"
    if ! GNUPGHOME="$gnupg" gpg -q --import "$key" 2>/dev/null; then
        result="cannot import key $key"
    elif ! GNUPGHOME="$gnupg" gpg --with-colons --fingerprint 2>/dev/null \
            | grep -q "^fpr:::::::::$WHONIX_SIGNING_FPR:"; then
        result="key file is not the Whonix signing key ($WHONIX_SIGNING_FPR)"
    elif ! GNUPGHOME="$gnupg" gpg --status-fd 1 --verify "$sig" "$archive" 2>/dev/null \
            | awk -v fpr="$WHONIX_SIGNING_FPR" '$2=="VALIDSIG" && $NF==fpr {found=1} END {exit !found}'; then
        result="SIGNATURE CHECK FAILED for $archive. Do not use this download."
    fi
    rm -rf "$gnupg"
    [[ "$result" == ok ]] && return 0
    echo "$result" >&2
    return 1
}

# Verify a Whonix download against the Whonix signing key (fatal on failure).
verify_whonix() {
    _whonix_verify_ok "$1" "$2" "$3" || die "Whonix verification failed — do not use this download"
    ok "Whonix signature verified"
}

stealth_setup() {
    local archive="" sig="" key=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sig) sig="$2"; shift 2 ;;
            --key) key="$2"; shift 2 ;;
            --passphrase-stdin) read_stdin_pass; shift ;;
            *) archive="$1"; shift ;;
        esac
    done
    need_root stealth setup
    serialize
    load_config
    need_cmd gpg tar xz qemu-img virsh cryptsetup python3
    [[ -r "$archive" ]] || die "usage: kratos stealth setup <Whonix-*.libvirt.xz> [--sig FILE.asc] [--key derivative.asc]
Download the KVM image, its .asc signature and the signing key from https://www.whonix.org/wiki/KVM"
    stealth_is_active && die "turn Stealth Mode off first"
    sig="${sig:-$archive.asc}"
    key="${key:-$KRATOS_ETC/whonix-signing-key.asc}"
    [[ -r "$sig" ]] || die "signature not found: $sig"
    [[ -r "$key" ]] || die "signing key not found: $key (download derivative.asc from whonix.org)"

    verify_whonix "$archive" "$sig" "$key"
    _stealth_provision "$archive"
    ok "Stealth Mode is ready. Turn it on from the tray, or: sudo kratos stealth on"
    warn "You can delete the downloaded archive now (kratos shred <file>)."
}

# Unlock/create the vault, extract an ALREADY-VERIFIED Whonix archive, harden
# the definitions, and re-lock. Shared by manual setup and auto-provision.
_stealth_provision() {
    local archive="$1"
    # From the moment the vault can be unlocked, guarantee it is re-locked on
    # EVERY exit path (a failed extract, missing archive member, hardener
    # rejection, ...), so a failed provision never leaves the vault open.
    trap 'vault_close' EXIT
    if [[ "${STEALTH_VAULT_PERSIST:-no}" != yes ]]; then
        # Amnesic vault: fresh random key in RAM, and always a fresh image so a
        # stale vault from a previous boot can't linger.
        stealth_make_ephemeral_key
        [[ -e "$VAULT_IMG" ]] && rm -f "$VAULT_IMG"
    fi
    if [[ -e "$VAULT_IMG" ]]; then
        vault_open
    else
        vault_create
    fi

    local imp="$VAULT_MNT/import"
    rm -rf "$imp"
    install -d -m 700 "$imp" "$VAULT_XML"
    info "Extracting Whonix (this takes a few minutes)..."
    tar -xJf "$archive" -C "$imp" --no-same-owner

    one() {
        local f
        f="$(find "$imp" -maxdepth 2 -iname "$1" | head -n1)"
        [[ -n "$f" ]] || die "Whonix archive is missing $1"
        echo "$f"
    }
    local gw_disk ws_disk gw_xml ws_xml ext_xml int_xml
    gw_disk="$(one '*Gateway*.qcow2')"
    ws_disk="$(one '*Workstation*.qcow2')"
    gw_xml="$(one '*Gateway*.xml')"
    ws_xml="$(one '*Workstation*.xml')"
    ext_xml="$(one '*external*network*.xml')"
    int_xml="$(one '*internal*network*.xml')"

    mv -f "$gw_disk" "$VAULT_MNT/gateway.qcow2"
    mv -f "$ws_disk" "$VAULT_MNT/workstation-base.qcow2"
    stealth_reset_overlay

    python3 "$HARDEN" prepare \
        --gw-xml "$gw_xml" --ws-xml "$ws_xml" --ext-xml "$ext_xml" --int-xml "$int_xml" \
        --gw-disk "$VAULT_MNT/gateway.qcow2" --ws-disk "$VAULT_MNT/workstation.qcow2" \
        --gw-ram "$STEALTH_GATEWAY_RAM" --ws-ram "$STEALTH_WORKSTATION_RAM" \
        --outdir "$VAULT_XML" || die "Whonix definitions failed the isolation check"
    rm -rf "$imp"
    vault_close
    trap - EXIT
}

# ── Auto-provision (zero-touch first run) ───────────────────
# Pick the newest Whonix KVM image URL from a download-directory index listing.
# Pure function so it can be unit-tested against a saved index.
_whonix_pick_latest() {   # <index-file> <baseurl> <flavor>
    local idx="$1" base="$2" flavor="$3" name
    base="${base%/}/"
    name="$(grep -oE "Whonix-${flavor}-[0-9][0-9.]*\.Intel_AMD64\.qcow2\.libvirt\.xz" "$idx" \
            | sort -V | tail -n1)"
    [[ -n "$name" ]] || return 1
    printf '%s%s\n' "$base" "$name"
}

# Version string embedded in a Whonix KVM image filename, or empty.
_whonix_file_version() {   # <path-or-name>
    local b="${1##*/}"
    [[ "$b" =~ Whonix-[^-]+-([0-9][0-9.]*)\.Intel_AMD64 ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

# Newest version the mirror currently advertises, or empty if it can't be
# reached. Best-effort and quiet: a freshness check must never block provisioning
# when offline. Honors STEALTH_WHONIX_URL (a pin means "this is latest").
_whonix_remote_latest_version() {
    local base="${STEALTH_WHONIX_BASEURL:-https://download.whonix.org/libvirt/}"
    local flavor="${STEALTH_WHONIX_FLAVOR:-Xfce}" url idx
    if [[ -n "${STEALTH_WHONIX_URL:-}" ]]; then
        _whonix_file_version "$STEALTH_WHONIX_URL"; return 0
    fi
    base="${base%/}/"
    idx="$(mktemp)"
    if curl -fL --proto "=https" --tlsv1.2 --connect-timeout 20 -sS "$base" -o "$idx" 2>/dev/null \
        && url="$(_whonix_pick_latest "$idx" "$base" "$flavor")"; then
        _whonix_file_version "$url"
    fi
    rm -f "$idx"
}

# Download the latest Whonix KVM image + its .asc into <destdir>. Echoes the
# archive path on stdout (progress/logs go to stderr). The signature is verified
# by the caller against the pinned key, so a hostile mirror cannot substitute an
# image. STEALTH_WHONIX_URL overrides discovery if a layout change breaks it.
stealth_fetch_whonix() {   # <destdir> -> echoes archive path
    local dest="$1"
    local base="${STEALTH_WHONIX_BASEURL:-https://download.whonix.org/libvirt/}"
    local url="${STEALTH_WHONIX_URL:-}" flavor="${STEALTH_WHONIX_FLAVOR:-Xfce}"
    base="${base%/}/"
    install -d -m 700 "$dest"
    local curl_opts=(-fL --proto "=https" --tlsv1.2 --connect-timeout 30)
    if [[ -z "$url" ]]; then
        local idx="$dest/index.html"
        curl "${curl_opts[@]}" -sS "$base" -o "$idx" >&2 || return 1
        url="$(_whonix_pick_latest "$idx" "$base" "$flavor")" || {
            # Some mirrors expose a 'latest/' directory; try it once.
            if curl "${curl_opts[@]}" -sS "${base}latest/" -o "$idx" 2>/dev/null; then
                url="$(_whonix_pick_latest "$idx" "${base}latest/" "$flavor")" || true
            fi
        }
        [[ -n "$url" ]] || { warn "could not find a Whonix KVM image at $base (set STEALTH_WHONIX_URL)"; return 1; }
        rm -f "$idx"
    fi
    local arc="$dest/${url##*/}"
    info "Downloading $(basename "$arc") (one time)..." >&2
    curl "${curl_opts[@]}" "$url"     -o "$arc"     >&2 || return 1
    curl "${curl_opts[@]}" "$url.asc" -o "$arc.asc" >&2 || return 1
    printf '%s\n' "$arc"
}

# First-run, zero-touch: download + verify Whonix, then provision. Runs over the
# current network mode (normal clearnet, or the VPN if STEALTH_REQUIRE_VPN=yes),
# since Tor isn't up yet. The persona itself only ever talks to the Gateway.
stealth_autoprovision() {
    [[ "${STEALTH_AUTOPROVISION:-yes}" == yes ]] \
        || die "Stealth Mode isn't set up and STEALTH_AUTOPROVISION=no; run: sudo kratos stealth setup <Whonix archive>"
    [[ "$(saved_mode)" == offline ]] \
        && die "cannot auto-provision while offline; switch to a network mode first (sudo kratos mode normal|vpn)"
    need_cmd curl gpg tar xz qemu-img cryptsetup python3
    local key="${KRATOS_ETC}/whonix-signing-key.asc"
    [[ -r "$key" ]] || die "the Whonix signing key is missing ($key); cannot verify a download"

    # Reuse a previously downloaded+verified image if one is cached, so an
    # installed system doesn't re-fetch ~1 GB of Whonix (and re-expose the
    # clearnet download) on every amnesic boot. On the live ISO the cache lives
    # on the ephemeral overlay, so a live boot still fetches fresh.
    local cache="$KRATOS_STATE/whonix-cache" archive="" cached=""
    # Pick the NEWEST cached image by version, never an arbitrary one, so an old
    # file lingering in the cache can't be resurrected over a newer one.
    if [[ "${STEALTH_WHONIX_CACHE:-yes}" == yes && -d "$cache" ]]; then
        cached="$(find "$cache" -maxdepth 1 -name 'Whonix-*.libvirt.xz' 2>/dev/null | sort -V | tail -n1)"
    fi
    local use_cache=no
    if [[ -n "$cached" ]] && _whonix_verify_ok "$cached" "$cached.asc" "$key"; then
        # A valid signature proves the image is GENUINE, not that it is CURRENT
        # (finding R4-7): an attacker who can serve you a stale-but-signed image,
        # or simple bit-rot over months, must not pin you to a vulnerable build.
        use_cache=yes
        local max_age="${STEALTH_WHONIX_MAX_AGE_DAYS:-90}"
        if [[ "$max_age" =~ ^[0-9]+$ ]] && (( max_age > 0 )) \
           && [[ -n "$(find "$cached" -maxdepth 0 -mtime +"$max_age" 2>/dev/null)" ]]; then
            warn "cached Whonix image is older than ${max_age} days; refreshing."
            use_cache=no
        else
            # If the mirror advertises a newer version, prefer it. Best-effort:
            # when offline (empty result) we keep using the verified cache.
            local remote_ver cached_ver
            remote_ver="$(_whonix_remote_latest_version)"
            cached_ver="$(_whonix_file_version "$cached")"
            if [[ -n "$remote_ver" && -n "$cached_ver" && "$remote_ver" != "$cached_ver" ]] \
               && [[ "$(printf '%s\n%s\n' "$cached_ver" "$remote_ver" | sort -V | tail -n1)" == "$remote_ver" ]]; then
                warn "a newer Whonix image ($remote_ver > $cached_ver) is available; refreshing."
                use_cache=no
            fi
        fi
    fi
    if [[ "$use_cache" == yes ]]; then
        info "Using the previously downloaded, signature-verified Whonix image ($(_whonix_file_version "$cached"))."
        archive="$cached"
    else
        info "${BOLD}Fetching and verifying Whonix${RESET} (one time per release; then just toggle)."
        local stage
        stage="$(mktemp -d)"
        # shellcheck disable=SC2064
        trap "rm -rf '$stage'" RETURN
        archive="$(stealth_fetch_whonix "$stage")" || die "could not download Whonix (check your connection, or set STEALTH_WHONIX_URL)"
        verify_whonix "$archive" "$archive.asc" "$key"
        if [[ "${STEALTH_WHONIX_CACHE:-yes}" == yes ]]; then
            # Replace the cache with ONLY this verified image, so stale older
            # builds don't accumulate and can't be picked up later.
            rm -rf "$cache"; install -d -m 700 "$cache"
            cp -f "$archive" "$archive.asc" "$cache/" && archive="$cache/$(basename "$archive")"
        fi
    fi
    _stealth_provision "$archive"
    ok "Whonix provisioned and verified."
}

# The Workstation runs from an overlay on top of a clean base image, so
# "disposable" is just throwing the overlay away.
stealth_reset_overlay() {
    rm -f "$VAULT_MNT/workstation.qcow2"
    qemu-img create -q -f qcow2 -F qcow2 -b "$VAULT_MNT/workstation-base.qcow2" \
        "$VAULT_MNT/workstation.qcow2"
}

# ── Host lockdown ───────────────────────────────────────────

# Record an undo step as a whitespace-separated argv line. It is replayed by
# host_restore as a real argv array (never through a shell), so nothing in the
# line is ever word-expanded, glob-expanded or command-substituted.
undo() { printf '%s\n' "$*" >> "$STEALTH_UNDO"; }

# The only programs host_restore is ever allowed to run to undo a lockdown.
# A line whose first word isn't here is refused, not executed — so even a
# corrupted undo log can't be turned into arbitrary root commands.
_UNDO_ALLOWED=" swapon systemctl rfkill rm modprobe usbguard sysctl "

# Is a named host-lockdown protection REQUIRED (Stealth refuses to start unless
# it is actually applied) rather than best-effort? Driven by STEALTH_REQUIRE, a
# comma-separated list drawn from: swap sleep bluetooth camera usb scan mac.
_stealth_required() {
    local IFS=',' t
    for t in ${STEALTH_REQUIRE:-}; do
        [[ "$t" == "$1" ]] && return 0
    done
    return 1
}

# A requested protection could not be fully applied. If the user listed it in
# STEALTH_REQUIRE, fail closed (die -> stealth_on rolls the lockdown back); if
# not, it is best-effort, so warn and carry on. This keeps "I asked for X and
# Stealth started" from silently meaning "X isn't actually in force".
_protect_failed() {   # <token> <message...>
    local token="$1"; shift
    if _stealth_required "$token"; then
        die "required protection '$token' is not in force: $* — refusing to start (edit STEALTH_REQUIRE to make it best-effort)"
    fi
    warn "$* (best-effort; add '$token' to STEALTH_REQUIRE to make this fatal)"
}

host_lockdown() {
    : > "$STEALTH_UNDO"
    chmod 600 "$STEALTH_UNDO"

    if [[ "$STEALTH_DISABLE_SWAP" == yes ]]; then
        local active_swaps sw
        active_swaps="$(swapon --noheadings --show=NAME 2>/dev/null)"
        if [[ -n "$active_swaps" ]]; then
            if swapoff -a; then
                # Re-enable ONLY the swaps that were actually active, not every
                # fstab entry (finding 21): a swap configured-but-inactive before
                # Stealth must stay inactive after.
                while read -r sw; do
                    [[ -n "$sw" ]] && undo "swapon $sw"
                done <<< "$active_swaps"
                ok "swap off"
            else
                _protect_failed swap "not enough free RAM to disable swap; close some programs (VM memory could be swapped to disk)"
            fi
        fi
    fi
    if [[ "$STEALTH_BLOCK_SLEEP" == yes ]]; then
        local targets="sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"
        # Mask ONLY targets that aren't already masked, and record for undo only
        # the ones WE masked (finding 21): never remove an administrator's
        # pre-existing mask when Stealth turns off.
        local t to_mask=()
        for t in $targets; do
            case "$(systemctl is-enabled "$t" 2>/dev/null)" in
                masked*) : ;;                 # already masked (incl. masked-runtime): leave it
                *) to_mask+=("$t") ;;
            esac
        done
        if [[ ${#to_mask[@]} -eq 0 ]]; then
            ok "suspend/hibernate already blocked"
        elif systemctl mask --runtime --quiet "${to_mask[@]}"; then
            undo "systemctl unmask --runtime --quiet ${to_mask[*]}"
            ok "suspend/hibernate blocked"
        else
            _protect_failed sleep "could not block suspend/hibernate (VM RAM and keys could reach disk on sleep)"
        fi
    fi
    if [[ "$STEALTH_BLOCK_BLUETOOTH" == yes ]]; then
        if ! command -v rfkill >/dev/null; then
            _protect_failed bluetooth "rfkill is not installed, so Bluetooth could not be disabled"
        elif rfkill list bluetooth 2>/dev/null | grep -q 'Soft blocked: no'; then
            if rfkill block bluetooth; then undo "rfkill unblock bluetooth"; ok "bluetooth off"
            else _protect_failed bluetooth "rfkill could not block Bluetooth"; fi
        else
            ok "bluetooth off"
        fi
    fi
    if [[ "$STEALTH_BLOCK_CAMERA" == yes ]]; then
        install -d /run/modprobe.d
        # Block reload of the common camera stacks, not just uvcvideo (finding 58).
        local cam_mods="uvcvideo gspca_main" m
        : > /run/modprobe.d/kratos-stealth-cam.conf
        for m in $cam_mods; do
            echo "install $m /bin/false" >> /run/modprobe.d/kratos-stealth-cam.conf
        done
        undo "rm -f /run/modprobe.d/kratos-stealth-cam.conf"
        for m in $cam_mods; do
            if lsmod | grep -q "^$m"; then
                if modprobe -r "$m" 2>/dev/null; then undo "modprobe $m"; fi
            fi
        done
        # Verify there is no remaining V4L2 capture device — don't equate
        # "unloaded one module" with "camera off" (finding 58).
        if compgen -G "/dev/video*" >/dev/null; then
            _protect_failed camera "a video capture device is still present (/dev/video*); close apps using it"
        else
            ok "camera off (no capture device present)"
        fi
    fi
    if [[ "${STEALTH_BLOCK_MIC:-yes}" == yes ]]; then
        # Microphone (finding 57). The persona VM has NO audio device at all
        # (the harden-whonix allowlist excludes sound), so the persona cannot
        # capture audio. This mutes the HOST's capture inputs best-effort while
        # Stealth is on; it is not a hard boundary (a root/user process can
        # unmute), so it is best-effort unless listed in STEALTH_REQUIRE.
        if command -v amixer >/dev/null; then
            local cap muted=0
            for cap in Capture Mic "Internal Mic" "Front Mic" Dmic; do
                if amixer -q sset "$cap" nocap 2>/dev/null || amixer -q sset "$cap" mute 2>/dev/null; then
                    muted=1
                fi
            done
            if (( muted )); then
                ok "microphone muted (best-effort; persona VM has no audio device)"
            else
                _protect_failed mic "found no capture control to mute"
            fi
        else
            _protect_failed mic "amixer not available to mute the microphone"
        fi
    fi
    if [[ "$STEALTH_BLOCK_NEW_USB" == yes ]]; then
        if systemctl is-active --quiet usbguard; then
            local prev
            prev="$(usbguard get-parameter ImplicitPolicyTarget 2>/dev/null || echo allow)"
            usbguard set-parameter ImplicitPolicyTarget block >/dev/null
            undo "usbguard set-parameter ImplicitPolicyTarget $prev"
            ok "new USB devices blocked"
        else
            _protect_failed usb "usbguard is not running, so newly plugged USB devices are NOT blocked"
        fi
    fi
    if [[ "$STEALTH_ONACCESS_SCAN" == yes ]] && ! systemctl is-active --quiet clamav-clamonacc; then
        # clamd needs ~1 GB RAM for signatures, so it only runs in Stealth Mode
        if systemctl start clamav-daemon clamav-clamonacc 2>/dev/null; then
            undo "systemctl stop clamav-clamonacc clamav-daemon"
            ok "on-access malware scanning on"
        else
            _protect_failed scan "could not start on-access malware scanning"
        fi
    fi
    if [[ "$STEALTH_NEW_MAC" == yes ]]; then
        if ! command -v nmcli >/dev/null; then
            _protect_failed mac "NetworkManager (nmcli) not available, so MAC was not refreshed"
        else
            # Reconnect each active wired/wireless connection, then VERIFY the
            # result (finding 7): a failed reconnect, or a device whose current
            # MAC still equals its permanent hardware address, means rotation did
            # not take effect — so we no longer just announce success.
            local uuid ctype dev cur perm mac_ok=1
            while IFS=: read -r uuid ctype; do
                [[ "$ctype" == *wireless* || "$ctype" == *ethernet* ]] || continue
                if ! nmcli -w 20 connection up "$uuid" >/dev/null 2>&1; then
                    mac_ok=0; continue
                fi
                dev="$(nmcli -g GENERAL.DEVICES connection show "$uuid" 2>/dev/null | head -1)"
                [[ -n "$dev" ]] || continue
                cur="$(cat "/sys/class/net/$dev/address" 2>/dev/null)"
                perm=""
                if command -v ethtool >/dev/null; then
                    perm="$(ethtool -P "$dev" 2>/dev/null | awk '{print $NF}')"
                fi
                if [[ -n "$perm" && "$perm" != "00:00:00:00:00:00" && "$cur" == "$perm" ]]; then
                    mac_ok=0
                fi
            done < <(nmcli -t -f UUID,TYPE connection show --active)
            if (( mac_ok )); then
                ok "reconnected with a verified fresh random MAC"
            else
                _protect_failed mac "a connection failed to come up, or a device's MAC still equals its hardware address"
            fi
        fi
    fi
    # libvirt turns forwarding on for the Gateway's NAT. Restore the EXACT prior
    # value on teardown, not a hard-coded 0: if the machine legitimately had
    # IP forwarding enabled before Stealth Mode, forcing it off would silently
    # break the user's routing. Read it now, before libvirt changes it.
    local prev_fwd
    prev_fwd="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
    [[ "$prev_fwd" =~ ^[01]$ ]] || prev_fwd=0
    undo "sysctl -qw net.ipv4.ip_forward=$prev_fwd"
}

host_restore() {
    [[ -r "$STEALTH_UNDO" ]] || return 0
    local cmd parts
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        # Split on whitespace into argv; run the array directly, no shell.
        read -ra parts <<< "$cmd"
        [[ ${#parts[@]} -gt 0 ]] || continue
        if [[ "$_UNDO_ALLOWED" != *" ${parts[0]} "* ]]; then
            warn "refusing to run unexpected undo step: $cmd"
            continue
        fi
        "${parts[@]}" || warn "could not undo: $cmd"
    done < <(tac "$STEALTH_UNDO")
    rm -f "$STEALTH_UNDO"
}

# ── VM control ──────────────────────────────────────────────

vm_running() { virsh_ domstate "$1" 2>/dev/null | grep -q running; }

# Stop a VM and *prove* it's gone. Polite shutdown, then hard off, then kill.
vm_stop() {
    local name="$1" t=0
    vm_running "$name" || return 0
    virsh_ shutdown "$name" >/dev/null 2>&1 || true
    while vm_running "$name" && (( t < STEALTH_SHUTDOWN_TIMEOUT )); do
        sleep 1; t=$((t + 1))
    done
    if vm_running "$name"; then
        warn "$name didn't shut down in ${STEALTH_SHUTDOWN_TIMEOUT}s; forcing it off"
        virsh_ destroy "$name" >/dev/null 2>&1 || true
        sleep 1
    fi
    if pgrep -f "guest=$name," >/dev/null; then
        pkill -KILL -f "guest=$name," || true
        sleep 1
    fi
    if vm_running "$name" || pgrep -f "guest=$name," >/dev/null; then
        bad "$name is STILL running"
        return 1
    fi
    ok "$name stopped"
}

wipe_artifacts() {
    local f
    for f in /var/log/libvirt/qemu/"$GW".log* /var/log/libvirt/qemu/"$WS".log* \
             /var/log/swtpm/libvirt/qemu/"$GW"* /var/log/swtpm/libvirt/qemu/"$WS"*; do
        [[ -e "$f" ]] && shred -uz "$f"
    done
    rm -rf /var/lib/libvirt/qemu/channel/target/domain-*-"$GW" \
           /var/lib/libvirt/qemu/channel/target/domain-*-"$WS" 2>/dev/null || true
    sync
    echo 3 > /proc/sys/vm/drop_caches
}

# ── ON / OFF ────────────────────────────────────────────────

# Always-on stylometry/timing guard at Stealth start.
guard_start() {
    local max="${GUARD_START_JITTER:-0}"
    if [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 )); then
        local d=$(( RANDOM % (max + 1) ))
        info "Timing guard: delaying start ${d}s to decorrelate from your real activity"
        sleep "$d"
    fi
    if [[ "${GUARD_STYLO_REMINDER:-yes}" == yes ]]; then
        info "Reminder: run persona text through 'kratos stylo' before posting it."
    fi
}

stealth_on_steps() {
    guard_start
    info "${BOLD}Host lockdown${RESET}"
    host_lockdown

    info "${BOLD}Unlocking stealth vault${RESET}"
    vault_open
    python3 "$HARDEN" check "$VAULT_XML" || die "VM definitions failed the isolation check"
    ok "Workstation can only reach the Gateway"
    [[ -e "$VAULT_MNT/workstation.qcow2" ]] || stealth_reset_overlay

    info "${BOLD}Starting isolated environment${RESET}"
    # QEMU (user libvirt-qemu) creates the display sockets here, and the
    # dedicated kstealth user needs to open them. 0710 root:kstealth: QEMU
    # (root-group member via libvirt) can write, kstealth can enter, and the
    # normal desktop user has no access at all.
    install -d -m 710 -o libvirt-qemu -g "$STEALTH_USER" "$SPICE_DIR"

    nft -f "$STEALTH_NFT" || die "could not load the stealth firewall"
    ok "stealth firewall loaded"
    virsh_ net-create "$VAULT_XML/kx-ext.xml" >/dev/null || die "could not create external network"
    virsh_ net-create "$VAULT_XML/kx-int.xml" >/dev/null || die "could not create internal network"
    virsh_ create "$VAULT_XML/$GW.xml" >/dev/null || die "could not start the Gateway"
    ok "Gateway started (connecting to Tor)"
    virsh_ create "$VAULT_XML/$WS.xml" >/dev/null || die "could not start the Workstation"
    ok "Workstation started"
    give_display "$GW"
    give_display "$WS"

    # Correlation-resistance profile (CORR_STEALTH_PROFILE). Best-effort: a
    # failure here must never block an otherwise-up persona.
    if command -v corr_stealth_apply >/dev/null 2>&1; then
        info "${BOLD}Correlation resistance${RESET}"
        corr_stealth_apply || warn "correlation profile could not be fully applied"
    fi
}

# Hand a VM's display socket to the dedicated stealth user ONLY.
#
# This is the heart of the host/persona separation. The persona's screen and
# keyboard are reachable only by kstealth, who owns a separate login session
# on its own VT (a cage kiosk run by kratos-stealth-seat@.service). Malware as your normal
# desktop user is a different uid with no access to this socket, so it cannot
# watch the persona or inject keystrokes. (A root compromise still wins; that
# is the limit short of a Qubes-style hypervisor. See docs/THREAT_MODEL.md.)
give_display() {
    local sock="$SPICE_DIR/$1.sock" t=0
    while [[ ! -S "$sock" ]] && (( t < 10 )); do sleep 1; t=$((t + 1)); done
    [[ -S "$sock" ]] || { warn "display socket for $1 not found"; return 0; }
    # TOCTOU hardening (finding 18): QEMU (libvirt-qemu) owns SPICE_DIR, so a
    # compromised QEMU could swap this path between a check and a chown/chmod
    # done by path. fix-socket-perms opens the inode with O_PATH|O_NOFOLLOW,
    # verifies it is a socket, and chowns/chmods the PINNED inode via
    # /proc/self/fd — race-free, immune to a later pathname swap. 0660 so the
    # kstealth group (the persona seat) can connect and "other" cannot.
    command python3 "$KRATOS_LIB/fix-socket-perms" "$sock" root "$STEALTH_USER" \
        || die "could not securely hand over display socket $sock (possible TOCTOU attack)"
}

stealth_on() {
    need_root stealth on
    serialize
    load_config
    need_cmd virsh cryptsetup nft python3
    stealth_is_active && die "Stealth Mode is already on"
    if [[ "$STEALTH_REQUIRE_VPN" == yes && "$(saved_mode)" != vpn ]]; then
        die "STEALTH_REQUIRE_VPN=yes but network mode is '$(saved_mode)'; run: sudo kratos mode vpn"
    fi
    if [[ "${1:-}" == --passphrase-stdin ]]; then
        read_stdin_pass
        # Amnesic vault ignores any passphrase (cryptsetup_pass enforces this);
        # say so rather than letting the caller believe it set one.
        [[ "${STEALTH_VAULT_PERSIST:-no}" != yes ]] && \
            warn "amnesic vault: the supplied passphrase is ignored (the in-RAM key is used); set STEALTH_VAULT_PERSIST=yes for a passphrase vault"
    fi
    # Zero-touch: on a fresh boot the vault doesn't exist yet (or its in-RAM key
    # is gone). Provision automatically — download + verify Whonix, build the
    # amnesic vault — so "boot the ISO, then toggle Stealth" is all it takes.
    stealth_is_provisioned || stealth_autoprovision
    [[ "$(saved_mode)" == offline ]] && warn "network mode is offline; the Gateway won't reach Tor"
    systemctl is-active --quiet libvirtd || systemctl start libvirtd

    install -d -m 755 "$KRATOS_RUN"
    date -u +%s > "$STEALTH_FLAG"

    info "${BOLD}Stealth Mode: ON${RESET}"
    set +e
    ( set -e; stealth_on_steps )
    local rc=$?
    set -e
    if (( rc != 0 )); then
        err "starting Stealth Mode failed; rolling back"
        stealth_off_steps || true
        exit 1
    fi
    info ""
    info "Open the stealth desktop: kratos stealth view"
}

# Record that Stealth Mode could not be fully torn down, and STOP: the host
# lockdown and the stealth firewall stay in place (fail-closed). The host is
# NOT restored and the active flag is NOT cleared, so status still reads ON.
_stealth_error() {
    { date -u +%s; printf '%s\n' "$*"; } >> "$STEALTH_ERROR" 2>/dev/null || true
    err "STEALTH MODE LEFT PARTIALLY UP: $*"
    err "Host lockdown and the stealth firewall are STILL ACTIVE (fail-closed)."
    err "Run 'kratos panic' to force everything down, or retry 'kratos stealth off'."
}

# Fail-closed teardown. Each step must succeed before the next loosens anything;
# the host is restored and the active flag cleared ONLY when everything below is
# positively gone.
stealth_off_steps() {
    info "${BOLD}Stopping isolated environment${RESET} (Workstation first)"
    if ! vm_stop "$WS"; then
        # Never take the Gateway away from a Workstation that is still running,
        # or the Workstation would sit without Tor while holding persona data.
        _stealth_error "the Workstation could not be stopped; Gateway and vault left as they are"
        return 1
    fi
    if ! vm_stop "$GW"; then
        _stealth_error "the Gateway could not be stopped"
        return 1
    fi
    # Prove no persona QEMU survives before we touch networking or the vault.
    if pgrep -f "guest=kx-" >/dev/null 2>&1; then
        _stealth_error "a persona QEMU process is still alive"
        return 1
    fi

    virsh_ net-destroy kx-int >/dev/null 2>&1 || true
    virsh_ net-destroy kx-ext >/dev/null 2>&1 || true
    nft delete table inet kratos_stealth 2>/dev/null || true
    rm -rf "$SPICE_DIR"
    # Remove any uplink padding the correlation profile installed.
    if command -v corr_stealth_clear >/dev/null 2>&1; then corr_stealth_clear || true; fi
    ok "stealth networks and firewall removed"

    if [[ "${STEALTH_WORKSTATION:-persistent}" == disposable ]] && mountpoint -q "$VAULT_MNT"; then
        stealth_reset_overlay && ok "Workstation reset to clean image (disposable)"
    fi

    info "${BOLD}Wiping artifacts and locking vault${RESET}"
    wipe_artifacts
    # Honest wording: shred/drop_caches are best-effort on SSD/CoW/flash and are
    # NOT guaranteed erasure. The real protection is that the persona lived only
    # inside the now-locked LUKS vault.
    ok "VM logs removed, caches dropped (best-effort; vault is the real boundary)"
    if ! vault_close; then
        # Vault still unlocked: keep host lockdown on; do NOT declare OFF.
        _stealth_error "the stealth vault could not be locked"
        return 1
    fi
    ok "vault locked"
    # The vault is locked, so the amnesic key is no longer needed; drop it and
    # release its ramfs.
    stealth_clear_ephemeral_key

    info "${BOLD}Restoring normal host${RESET}"
    host_restore
    ok "host restored"
    rm -f "$STEALTH_FLAG" "$STEALTH_ERROR"
    return 0
}

stealth_off() {
    need_root stealth off
    serialize
    load_config
    if ! stealth_is_active && ! vault_is_open; then
        info "Stealth Mode is already off."
        return 0
    fi
    info "${BOLD}Stealth Mode: OFF${RESET}"
    stealth_off_steps || die "Stealth Mode did not shut down cleanly; see above. If in doubt: kratos panic"
}

# For `kratos panic`: no politeness, just get everything down.
stealth_kill() {
    virsh_ destroy "$WS" >/dev/null 2>&1 || true
    virsh_ destroy "$GW" >/dev/null 2>&1 || true
    pkill -KILL -f "guest=kx-" 2>/dev/null || true
    if command -v corr_stealth_clear >/dev/null 2>&1; then corr_stealth_clear || true; fi
    rm -rf "$SPICE_DIR"
    umount -l "$VAULT_MNT" 2>/dev/null || true
    cryptsetup close "$VAULT_MAPPER" 2>/dev/null || true
    stealth_clear_ephemeral_key
}

# Open the persona display. The viewer runs as kstealth in its own session,
# NOT in the caller's desktop session, so the persona's window never shares a
# compositor, clipboard or input path with normal-mode programs. The tray
# triggers this through the org.kratos.view polkit action.
stealth_view() {
    local vm="${1:-workstation}" name="$WS"
    [[ "$vm" == gateway ]] && name="$GW"
    need_root stealth view
    stealth_is_active || die "Stealth Mode is off"
    [[ -S "$SPICE_DIR/$name.sock" ]] || die "no display socket for $vm"
    # kratos-stealth-seat@.service runs a cage (kiosk Wayland) session for kstealth on its own VT;
    # launch the viewer into that session's bus, locked to this one socket.
    if ! loginctl --no-legend list-sessions 2>/dev/null | grep -qw "$STEALTH_USER"; then
        info "Starting the isolated stealth session (switch VTs with Ctrl+Alt+F2)..."
        systemctl start "kratos-stealth-seat@${name}.service" \
            || die "could not start the isolated stealth session"
        return 0
    fi
    runuser -u "$STEALTH_USER" -- \
        remote-viewer --title "KratosOS Stealth: $vm" \
        "spice+unix://$SPICE_DIR/$name.sock" >/dev/null 2>&1 &
    disown
}

stealth_reset() {
    need_root stealth reset
    serialize
    load_config
    stealth_is_active && die "turn Stealth Mode off first"
    confirm "Erase everything in the Workstation and restore a clean image?" || exit 0
    # Re-lock the vault on any exit path, including a failed overlay recreate.
    trap 'vault_close' EXIT
    vault_open
    stealth_reset_overlay
    vault_close
    trap - EXIT
    ok "Workstation reset"
}

stealth_status() {
    info "${BOLD}Stealth Mode:${RESET} $(stealth_is_active && echo ON || echo off)"
    if [[ ! -e "$VAULT_IMG" ]]; then
        info "  not set up (sudo kratos stealth setup <Whonix archive>)"
        return 0
    fi
    if vault_is_open; then ok "vault unlocked"; else info "  vault locked"; fi
    if stealth_is_active; then
        local d
        for d in "$GW" "$WS"; do
            if vm_running "$d"; then ok "$d running"; else bad "$d not running"; fi
        done
        if nft list table inet kratos_stealth >/dev/null 2>&1; then
            ok "stealth firewall loaded"
        else
            bad "stealth firewall NOT loaded"
        fi
        if [[ -d "$VAULT_XML" ]] && python3 "$HARDEN" check "$VAULT_XML" 2>/dev/null; then
            ok "isolation check passed"
        fi
    fi
}

stealth_main() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        on)     stealth_on "$@" ;;
        off)    stealth_off "$@" ;;
        toggle) if stealth_is_active; then stealth_off; else stealth_on "$@"; fi ;;
        status) stealth_status ;;
        view)   stealth_view "$@" ;;
        setup)  stealth_setup "$@" ;;
        reset)  stealth_reset ;;
        *) die "usage: kratos stealth {on|off|toggle|status|view|setup|reset}" ;;
    esac
}
