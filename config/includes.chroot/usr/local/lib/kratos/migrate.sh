# shellcheck shell=bash
# Windows 11 -> KratosOS migration.
#
# Two sources are supported:
#   1. An export folder made on Windows by Export-WindowsData.ps1 (recommended:
#      it has a SHA-256 manifest, so every file is verified on import).
#   2. A Windows disk/partition directly (NTFS, optionally BitLocker), e.g. the
#      old drive in a USB enclosure. Mounted read-only.

MIGRATE_FOLDERS=(Desktop Documents Downloads Pictures Music Videos Favorites)
# shellcheck disable=SC2016  # literal patterns, not variables
MIGRATE_EXCLUDES=(desktop.ini Thumbs.db '*.lnk' '$RECYCLE.BIN' 'System Volume Information' '~$*' '*.tmp')

migrate_usage() {
    cat <<EOF
usage: kratos migrate --from <export-folder | /dev/sdXN> [--to DIR] [--user NAME] [--scrub]

  --from DIR        Folder created by Export-WindowsData.ps1 (verified with its manifest)
  --from /dev/sdXN  Windows partition (NTFS or BitLocker), mounted read-only
  --to DIR          Destination (default: your home folder)
  --user NAME       Windows user to copy (default: ask)
  --scrub           Strip metadata from copied photos and documents (mat2)

Without --from, lists the Windows partitions that are attached.
EOF
}

migrate_list_partitions() {
    info "${BOLD}Windows partitions found:${RESET}"
    lsblk -rpno NAME,FSTYPE,SIZE,LABEL | awk '$2=="ntfs" || $2=="BitLocker" {print "  "$0}'
}

# Mount a Windows partition read-only; prints the mountpoint.
migrate_mount() {
    local dev="$1" fstype mnt="$KRATOS_RUN/migrate/win"
    fstype="$(lsblk -no FSTYPE "$dev")"
    install -d -m 700 "$mnt" "$KRATOS_RUN/migrate/bitlocker"
    if [[ "$fstype" == BitLocker ]]; then
        need_cmd dislocker
        # Let dislocker read the secret itself (bare -p/-u prompt for it on the
        # terminal), so the Windows password / recovery key is NEVER placed on
        # dislocker's command line or held in a shell variable — it can't leak
        # through /proc/<pid>/cmdline, the process list or a core dump.
        local kind
        info "BitLocker volume on $dev." >&2
        printf 'Unlock with your Windows (p)assword or a 48-digit (r)ecovery key? [p/r] ' >&2
        read -r kind
        case "$kind" in
            r|R|recovery) dislocker -V "$dev" -u -r -- "$KRATOS_RUN/migrate/bitlocker" >&2 ;;
            *)            dislocker -V "$dev" -p -r -- "$KRATOS_RUN/migrate/bitlocker" >&2 ;;
        esac || die "could not unlock BitLocker"
        mount -o ro,loop "$KRATOS_RUN/migrate/bitlocker/dislocker-file" "$mnt"
    else
        # Read-only works even if Windows was hibernated / used Fast Startup
        mount -t ntfs3 -o ro "$dev" "$mnt" 2>/dev/null || mount -t ntfs-3g -o ro "$dev" "$mnt"
    fi || die "could not mount $dev"
    echo "$mnt"
}

migrate_umount() {
    umount "$KRATOS_RUN/migrate/win" 2>/dev/null || true
    umount "$KRATOS_RUN/migrate/bitlocker" 2>/dev/null || true
}

migrate_pick_user() {
    local root="$1" users=() u
    for u in "$root"/Users/*/; do
        u="$(basename "$u")"
        case "$u" in Public|Default|"Default User"|"All Users"|defaultuser0|WDAGUtilityAccount) continue ;; esac
        users+=("$u")
    done
    [[ ${#users[@]} -gt 0 ]] || die "no Windows user folders found in $root/Users"
    if [[ ${#users[@]} -eq 1 ]]; then
        echo "${users[0]}"
        return
    fi
    PS3="Which Windows user? "
    select u in "${users[@]}"; do [[ -n "$u" ]] && { echo "$u"; return; }; done
}

migrate_copy_from_disk() {
    local profile="$1" dest="$2" f
    local excl=()
    for f in "${MIGRATE_EXCLUDES[@]}"; do excl+=(--exclude "$f"); done
    for f in "${MIGRATE_FOLDERS[@]}"; do
        [[ -d "$profile/$f" ]] || continue
        info "Copying $f..."
        rsync -rt --info=progress2 --no-perms --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= "${excl[@]}" \
            "$profile/$f/" "$dest/$f/"
        _MIGRATED_PATHS+=("$dest/$f")
    done
    # OneDrive: only files actually downloaded to the PC exist on disk
    if [[ -d "$profile/OneDrive" ]]; then
        info "Copying OneDrive (only files that were downloaded locally)..."
        rsync -rt --info=progress2 --no-perms --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= "${excl[@]}" \
            "$profile/OneDrive/" "$dest/OneDrive/"
        _MIGRATED_PATHS+=("$dest/OneDrive")
    fi
    migrate_bookmarks "$profile" "$dest/Browser bookmarks"
    if [[ -d "$dest/Browser bookmarks" ]]; then _MIGRATED_PATHS+=("$dest/Browser bookmarks"); fi
}

# Bookmarks only. Saved passwords are deliberately NOT migrated:
# export them from your password manager instead.
migrate_bookmarks() {
    local profile="$1" out="$2" src
    install -d "$out"
    # Only ever copy ORDINARY regular files (finding 62): a symlink/reparse
    # point on the untrusted NTFS image could otherwise redirect the copy at an
    # arbitrary file. `-f && ! -L` rejects symlinks; cp -- guards leading dashes.
    local bm
    for src in "Google/Chrome" "Microsoft/Edge" "BraveSoftware/Brave-Browser"; do
        bm="$profile/AppData/Local/$src/User Data/Default/Bookmarks"
        if [[ -f "$bm" && ! -L "$bm" ]]; then
            cp -- "$bm" "$out/${src//\//-}.json"
        fi
    done
    for src in "$profile"/AppData/Roaming/Mozilla/Firefox/Profiles/*/places.sqlite; do
        [[ -f "$src" && ! -L "$src" ]] || continue
        cp -- "$src" "$out/Firefox-$(basename "$(dirname "$src")")-places.sqlite"
    done
    rmdir "$out" 2>/dev/null && return 0
    info "Bookmarks saved to '$out'. Import them from Firefox: Bookmarks > Manage > Import."
}

# Every manifest entry must be "<64-hex>␣␣Files/<relative-path>" with no
# absolute path and no ".." component. Empty/garbage manifests are rejected.
_migrate_safe_manifest() {
    local mf="$1" line path any=0
    [[ -s "$mf" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^[0-9a-fA-F]{64}[[:space:]] ]] || return 1
        [[ "$line" == *"Files/"* ]] || return 1
        path="${line#*Files/}"
        [[ "$path" == /* ]] && return 1          # no absolute paths
        case "/$path/" in */../*) return 1 ;; esac  # no parent traversal
        any=1
    done < "$mf"
    (( any == 1 ))
}

# Copy an Export-WindowsData.ps1 folder into a STAGING area, verify EVERY file
# against the manifest, and only publish to the destination if all pass. On any
# failure the staging tree is discarded and the destination is left untouched —
# the import is fail-closed, so "migration finished" never prints on a mismatch.
migrate_copy_from_export() {
    local src="$1" dest="$2"
    [[ -f "$src/manifest.sha256" ]] || die "$src has no manifest.sha256 (was it made by Export-WindowsData.ps1?)"
    _migrate_safe_manifest "$src/manifest.sha256" \
        || die "manifest.sha256 is empty or contains unsafe paths (absolute or ..); refusing to import"

    local stage
    stage="$(mktemp -d "$dest/.kratos-import.XXXXXX")" || die "cannot create a staging area in $dest"
    trap 'rm -rf "$stage"' EXIT
    info "Copying export to a staging area..."
    rsync -rt --info=progress2 --no-perms --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= --exclude manifest.sha256 \
        --exclude inventory --exclude export.log "$src/Files/" "$stage/"

    info "Verifying every file against the manifest made on Windows (all must pass)..."
    # sha256sum -c --strict fails on ANY mismatch AND on any malformed line, so a
    # garbled/empty manifest can't masquerade as "zero failures".
    if sed 's#^\([0-9a-fA-F]\{64\}\)  Files/#\1  #' "$src/manifest.sha256" \
        | ( cd "$stage" && sha256sum -c --strict - >/dev/null 2>&1 ); then
        ok "all files verified against the manifest (corruption check)"
    else
        die "verification FAILED: the import is incomplete or altered. Destination left unchanged, staging discarded. DO NOT wipe your backup."
    fi

    info "Publishing verified files..."
    cp -a "$stage/." "$dest/"
    # Record only the top-level entries we published, so ownership is fixed on
    # exactly the imported trees — never the whole destination (finding 8).
    local e
    for e in "$stage"/* "$stage"/.[!.]*; do
        [[ -e "$e" ]] || continue
        _MIGRATED_PATHS+=("$dest/$(basename "$e")")
    done
    rm -rf "$stage"
    trap - EXIT

    if [[ -d "$src/inventory" ]]; then
        install -d "$dest/Windows inventory"
        cp -r "$src/inventory/." "$dest/Windows inventory/"
        _MIGRATED_PATHS+=("$dest/Windows inventory")
        migrate_app_report "$src/inventory/installed-software.csv"
    fi
}

# Suggest Linux replacements for installed Windows software.
migrate_app_report() {
    local csv="$1" map="$KRATOS_LIB/app-alternatives.tsv"
    [[ -r "$csv" && -r "$map" ]] || return 0
    info ""
    info "${BOLD}Your Windows software on KratosOS:${RESET}"
    local pattern alt
    while IFS=$'\t' read -r pattern alt; do
        [[ -z "$pattern" || "$pattern" == \#* ]] && continue
        if grep -qiE "$pattern" "$csv"; then
            printf '  %-28s -> %s\n' "$(grep -ioE -m1 "$pattern" "$csv" | head -n1)" "$alt"
        fi
    done < "$map"
    info "Anything not listed: try Bottles (Windows apps), or keep a Windows VM via virt-manager."
}

migrate_scrub() {
    local dest="$1" owner="${2:-}"
    need_cmd mat2
    info "Stripping metadata from photos and documents..."
    # mat2 parses complex attacker-controlled formats (PDF/Office/JPEG). Run it
    # as the destination USER, never as root, so a parser bug can't be root.
    # shellcheck disable=SC2016
    local cmd='find "$1" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o -iname "*.tif*" -o -iname "*.pdf" -o -iname "*.docx" -o -iname "*.xlsx" -o -iname "*.pptx" -o -iname "*.odt" -o -iname "*.mp3" -o -iname "*.flac" \) -print0 | xargs -0 -r -n 50 mat2 --inplace --lightweight 2>/dev/null || true'
    if [[ $EUID -eq 0 && -n "$owner" && "$owner" != root ]] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$owner" -- bash -c "$cmd" _ "$dest"
    else
        bash -c "$cmd" _ "$dest"
    fi
    ok "metadata stripped"
}

migrate_windows() {
    local from="" dest="" user="" scrub=no
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from="$2"; shift 2 ;;
            --to) dest="$2"; shift 2 ;;
            --user) user="$2"; shift 2 ;;
            --scrub) scrub=yes; shift ;;
            -h|--help) migrate_usage; return ;;
            *) migrate_usage; die "unknown option $1" ;;
        esac
    done
    if [[ -z "$from" ]]; then
        migrate_usage; echo; migrate_list_partitions
        return
    fi

    # --user must name a SINGLE Windows profile directory, never a path.
    if [[ -n "$user" ]]; then
        case "$user" in
            */*|*\\*|.|..|*..*) die "invalid --user '$user' (must be a single profile name)" ;;
        esac
    fi

    local invoker owner owner_home
    invoker="$(desktop_user)"                 # set only when invoked via sudo/pkexec by a user
    owner="${invoker:-$(id -un)}"
    owner_home="$(getent passwd "$owner" | cut -d: -f6)"
    [[ -n "$owner_home" ]] || owner_home="${HOME:-/root}"
    dest="${dest:-$owner_home}"
    dest="$(realpath -m -- "$dest")"
    # When a desktop user elevated this (auth_admin_keep caches that auth),
    # confine the destination to THEIR home so it can't be pointed at /etc etc.
    if [[ $EUID -eq 0 && -n "$invoker" && "$invoker" != root ]]; then
        case "$dest" in
            "$owner_home"|"$owner_home"/*) : ;;   # the home itself, or inside it
            *) die "refusing elevated migration to '$dest': the destination must be inside $owner_home" ;;
        esac
    fi
    install -d -- "$dest"
    _MIGRATED_PATHS=()          # top-level destination trees the import created

    if [[ -b "$from" ]]; then
        need_root migrate --from "$from"
        need_cmd rsync
        local root profile
        trap migrate_umount EXIT
        root="$(migrate_mount "$from")"
        [[ -n "$user" ]] || user="$(migrate_pick_user "$root")"
        profile="$root/Users/$user"
        [[ -d "$profile" ]] || die "no such Windows user: $user"
        migrate_copy_from_disk "$profile" "$dest"
        migrate_umount
        trap - EXIT
    elif [[ -d "$from" ]]; then
        need_cmd rsync sha256sum
        migrate_copy_from_export "$from" "$dest"
    else
        die "--from must be an export folder or a partition like /dev/sdb3"
    fi

    # Own ONLY the imported trees as the target user (finding 8), never the whole
    # destination/home — pre-existing or admin-managed files under $dest must not
    # have their ownership rewritten. Then scrub as that user, so hostile
    # documents are never parsed by mat2 as root.
    if [[ $EUID -eq 0 && "$owner" != root ]] && (( ${#_MIGRATED_PATHS[@]} )); then
        local p
        for p in "${_MIGRATED_PATHS[@]}"; do
            [[ -e "$p" ]] || continue
            chown -R -- "$owner": "$p"
        done
    fi
    [[ "$scrub" == yes ]] && migrate_scrub "$dest" "$owner"
    ok "migration finished: $dest"
    info "Keep your backup drive until you have opened your important files here."
}
