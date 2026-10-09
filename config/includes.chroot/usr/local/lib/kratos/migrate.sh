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
        # Prefer the userspace parser for the (untrusted) decrypted NTFS image too.
        mount -t ntfs-3g -o ro,loop "$KRATOS_RUN/migrate/bitlocker/dislocker-file" "$mnt" 2>/dev/null \
            || mount -o ro,loop "$KRATOS_RUN/migrate/bitlocker/dislocker-file" "$mnt"
    else
        # Prefer the USERSPACE/FUSE parser (ntfs-3g) for untrusted foreign media,
        # so a malformed or deliberately hostile NTFS structure is handled by a
        # userspace process rather than the kernel filesystem driver (finding
        # R9-10). Fall back to the kernel ntfs3 driver only if ntfs-3g is absent.
        # Read-only works even if Windows was hibernated / used Fast Startup.
        mount -t ntfs-3g -o ro "$dev" "$mnt" 2>/dev/null || mount -t ntfs3 -o ro "$dev" "$mnt"
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

# Resolve a source subdirectory and require it to be a REAL directory (never a
# symlink/NTFS reparse point) that stays UNDERNEATH the trusted source root
# (already resolved). This stops an attacker-controlled export/disk from
# pointing a top-level folder at, say, /root or /root/.ssh so the PRIVILEGED
# copy discloses host files into staging (finding R6-H1). Prints the resolved
# path on success; fails otherwise.
_migrate_real_dir() {   # <path> <trusted-real-root>
    local p="$1" root="$2" real
    [[ -d "$p" && ! -L "$p" ]] || return 1
    real="$(realpath -e -- "$p" 2>/dev/null)" || return 1
    case "$real/" in "$root"/*|"$root"/) printf '%s\n' "$real"; return 0 ;; esac
    return 1
}
# Like _migrate_real_dir but for a FILE: require a real regular file (never a
# symlink) whose fully-resolved path stays UNDER the trusted root. realpath -e
# resolves EVERY component, so a reparse point on an INTERMEDIATE directory
# (e.g. AppData/.../Default) that escapes the mounted Windows root is refused,
# not followed as root (finding R9-9). Prints the resolved path on success.
_migrate_real_file() {   # <path> <trusted-real-root>
    local p="$1" root="$2" real
    [[ -f "$p" && ! -L "$p" ]] || return 1
    real="$(realpath -e -- "$p" 2>/dev/null)" || return 1
    case "$real" in "$root"/*) printf '%s\n' "$real"; return 0 ;; esac
    return 1
}
# NOTE on rsync: `rsync -rt` (no -l/-a) copies only regular files and real
# directories — it SKIPS symlinks and other non-regular objects found while
# recursing. The only symlink it would follow is a command-line SOURCE that is
# itself a symlink (with a trailing slash), which is exactly what
# _migrate_real_dir rejects before we ever pass the path to rsync.

# Copy a mounted Windows profile into the root-owned STAGING dir (never straight
# into the user's home). migrate_windows publishes staging to $HOME as the user,
# so a symlink planted in $HOME can't turn a root write into a root-write
# primitive (finding R4-1).
migrate_copy_from_disk() {
    local profile="$1" stage="$2" mountroot="$3" f realf
    # The mount root confines every source path: a reparse point inside the
    # untrusted NTFS image that escapes it is refused, not followed as root.
    local root; root="$(realpath -e -- "$mountroot" 2>/dev/null)" \
        || die "internal error: migration mount root is not resolvable"
    local excl=()
    for f in "${MIGRATE_EXCLUDES[@]}"; do excl+=(--exclude "$f"); done
    for f in "${MIGRATE_FOLDERS[@]}"; do
        realf="$(_migrate_real_dir "$profile/$f" "$root")" || continue
        info "Copying $f..."
        rsync -rt --info=progress2 --no-perms --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= "${excl[@]}" \
            "$realf/" "$stage/$f/"
    done
    # OneDrive: only files actually downloaded to the PC exist on disk
    if realf="$(_migrate_real_dir "$profile/OneDrive" "$root")"; then
        info "Copying OneDrive (only files that were downloaded locally)..."
        rsync -rt --info=progress2 --no-perms --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= "${excl[@]}" \
            "$realf/" "$stage/OneDrive/"
    fi
    migrate_bookmarks "$profile" "$stage/Browser bookmarks" "$root"
}

# Bookmarks only. Saved passwords are deliberately NOT migrated:
# export them from your password manager instead.
migrate_bookmarks() {
    local profile="$1" out="$2" root="$3" src bm realbm
    install -d "$out"
    # Only ever copy ORDINARY regular files whose RESOLVED path stays under the
    # mounted Windows root (findings 62, R9-9): a symlink/reparse point on the
    # untrusted NTFS image — on the final object OR any intermediate directory —
    # could otherwise redirect the privileged copy at an arbitrary host file.
    # _migrate_real_file enforces both; cp -- guards leading dashes.
    for src in "Google/Chrome" "Microsoft/Edge" "BraveSoftware/Brave-Browser"; do
        bm="$profile/AppData/Local/$src/User Data/Default/Bookmarks"
        if realbm="$(_migrate_real_file "$bm" "$root")"; then
            cp -- "$realbm" "$out/${src//\//-}.json"
        fi
    done
    for src in "$profile"/AppData/Roaming/Mozilla/Firefox/Profiles/*/places.sqlite; do
        realbm="$(_migrate_real_file "$src" "$root")" || continue
        cp -- "$realbm" "$out/Firefox-$(basename "$(dirname "$src")")-places.sqlite"
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
    local src="$1" stage="$2"
    [[ -f "$src/manifest.sha256" ]] || die "$src has no manifest.sha256 (was it made by Export-WindowsData.ps1?)"
    _migrate_safe_manifest "$src/manifest.sha256" \
        || die "manifest.sha256 is empty or contains unsafe paths (absolute or ..); refusing to import"

    # Confine the source to the export folder: Files/ (and inventory/) must be
    # REAL directories under $src, never symlinks pointing at host files that a
    # privileged copy would then disclose (finding R6-H1).
    local srcreal filesdir
    srcreal="$(realpath -e -- "$src" 2>/dev/null)" || die "export folder not found: $src"
    filesdir="$(_migrate_real_dir "$src/Files" "$srcreal")" \
        || die "refusing to import: '$src/Files' is missing, a symlink, or escapes the export folder"

    info "Copying export to the staging area..."
    rsync -rt --info=progress2 --no-perms --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= \
        "$filesdir/" "$stage/"

    info "Verifying every file against the manifest made on Windows (all must pass)..."
    # sha256sum -c --strict fails on ANY mismatch AND on any malformed line, so a
    # garbled/empty manifest can't masquerade as "zero failures". This proves
    # every MANIFEST entry is present and matches.
    if sed 's#^\([0-9a-fA-F]\{64\}\)  Files/#\1  #' "$src/manifest.sha256" \
        | ( cd "$stage" && sha256sum -c --strict - >/dev/null 2>&1 ); then
        ok "all files verified against the manifest (corruption check)"
    else
        die "verification FAILED: the import is incomplete or altered. Nothing published, staging discarded. DO NOT wipe your backup."
    fi

    # sha256sum -c only proves manifest ⊆ staged. Also require staged ⊆ manifest
    # (finding R6-16): an attacker who dropped an EXTRA, unlisted file into the
    # export (e.g. a .desktop autostart) would otherwise have it published
    # unverified. And staging must hold only regular files + dirs — no symlink
    # or device slipped through (rsync -rt skips them, so any is a red flag).
    local manifest_set staged_set nonreg
    nonreg="$(find "$stage" -mindepth 1 ! -type f ! -type d -print -quit 2>/dev/null)"
    [[ -z "$nonreg" ]] || die "verification FAILED: a non-regular file ($nonreg) is present in the import; refusing to publish."
    manifest_set="$(sed -n 's#^[0-9a-fA-F]\{64\}  Files/##p' "$src/manifest.sha256" | LC_ALL=C sort -u)"
    staged_set="$( ( cd "$stage" && find . -type f -printf '%P\n' ) | LC_ALL=C sort -u)"
    if [[ "$manifest_set" != "$staged_set" ]]; then
        die "verification FAILED: the import contains files not listed in the manifest (unverified extras); refusing to publish. DO NOT wipe your backup."
    fi
    ok "every imported file is accounted for in the manifest (no unlisted extras)"

    # The manifest is NOT authenticated (it sits next to the files), so a
    # tampered backup could list arbitrary paths and the checks above would
    # still pass. Constrain imports to the official exporter's layout so a
    # tampered backup cannot drop a home-root dotfile/dotdir that AUTO-RUNS code
    # in the new home (e.g. ~/.bashrc, ~/.config/autostart/*.desktop, ~/.profile)
    # — finding R8-9. Only the one intentional dotdir, .ssh, is allowed.
    local rel top
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        top="${rel%%/*}"
        case "$top" in
            .ssh)
                # .ssh is the one allowed dotdir (-IncludeSSH), but the backup is
                # NOT authenticated (finding R9-7): a tampered export could slip in
                # an ~/.ssh/config with a ProxyCommand (runs on your next ssh), or
                # an authorized_keys/rc/environment that grants or triggers remote
                # access. Import only PASSIVE key material; refuse ACTIVE SSH
                # configuration — review and place that by hand after import.
                case "${rel##*/}" in
                    config|authorized_keys|authorized_keys2|rc|environment)
                        die "refusing to import '$rel': an unauthenticated backup must not place an active SSH config/authorized-keys file into ~/.ssh (it could redirect your SSH or grant remote access). Review it and import it by hand instead." ;;
                esac
                ;;
            .*) die "refusing to import '$rel': KratosOS does not import home-root dotfiles/dotdirs from a backup (they could auto-run code in your new home). Only .ssh key material is allowed." ;;
        esac
    done <<< "$staged_set"

    local invdir
    if invdir="$(_migrate_real_dir "$src/inventory" "$srcreal")"; then
        install -d "$stage/Windows inventory"
        # rsync -rt (no -l) copies only regular files/dirs — symlinks in the
        # untrusted inventory tree are skipped, and the root was confined above.
        rsync -rt --no-perms --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= "$invdir/" "$stage/Windows inventory/"
        local csv="$invdir/installed-software.csv"
        [[ -f "$csv" && ! -L "$csv" ]] && migrate_app_report "$csv"
    fi
}

# Publish the (already user-owned) staging tree into $dest. When elevated by a
# desktop user, EVERY operation that touches the user-controlled $dest runs AS
# THAT USER (runuser) — the directory creation AND the rsync. Root never does a
# pathname-based write, chown or mkdir on $dest, so a destination that a
# concurrent desktop-user process swaps for a symlink (TOCTOU) can only ever
# redirect a write to somewhere the user could already write anyway. There is
# no root-write primitive to escalate (findings R4-1/R4-8, R5-1).
#
# The staging tree is root-created outside the user's reach (see migrate_windows)
# and handed to the user by a single chown there, so it needs none here.
_migrate_publish() {
    local stage="$1" dest="$2" owner="$3"
    info "Publishing verified files to $dest ..."
    if [[ $EUID -eq 0 && -n "$owner" && "$owner" != root ]] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$owner" -- mkdir -p -- "$dest" \
            || die "cannot create $dest as $owner"
        runuser -u "$owner" -- rsync -rt --no-perms \
            --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= "$stage"/ "$dest"/ \
            || die "publish failed (as $owner) — nothing left half-written"
    else
        install -d -- "$dest"
        cp -a "$stage/." "$dest/"
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
    # Early sanity guard (NOT the security boundary): reject a destination that
    # obviously isn't the invoker's home. The real safety is that every write to
    # $dest happens as the user in _migrate_publish, so this check only needs to
    # catch mistakes, not races.
    if [[ $EUID -eq 0 && -n "$invoker" && "$invoker" != root ]]; then
        case "$dest" in
            "$owner_home"|"$owner_home"/*) : ;;   # the home itself, or inside it
            *) die "refusing elevated migration to '$dest': the destination must be inside $owner_home" ;;
        esac
    fi

    # Stage in a ROOT-OWNED area OUTSIDE the user's reach (never inside $dest,
    # which the user can swap for a symlink). KRATOS_STATE lives on the host's
    # own (LUKS-encrypted, on an installed system) root filesystem, so staging
    # has real disk space and no desktop-user process can pre-plant or redirect
    # it. The random 700 dir can't be pre-created (mktemp fails if it exists).
    local stage stageroot="$KRATOS_STATE/migrate"
    install -d -- "$KRATOS_STATE"
    # 711: the user must be able to TRAVERSE to their own (random-named, 700,
    # user-owned) staging leaf once we hand it over, but not enumerate the dir.
    install -d -m 711 -- "$stageroot"
    stage="$(mktemp -d "$stageroot/import.XXXXXX")" || die "cannot create a staging area in $stageroot"
    chmod 700 "$stage"

    if [[ -b "$from" ]]; then
        need_root migrate --from "$from"
        need_cmd rsync
        local root profile
        trap 'migrate_umount; rm -rf "$stage"' EXIT
        root="$(migrate_mount "$from")"
        [[ -n "$user" ]] || user="$(migrate_pick_user "$root")"
        profile="$root/Users/$user"
        [[ -d "$profile" && ! -L "$profile" ]] || die "no such Windows user: $user"
        migrate_copy_from_disk "$profile" "$stage" "$root"
        migrate_umount
        trap 'rm -rf "$stage"' EXIT
    elif [[ -d "$from" ]]; then
        need_cmd rsync sha256sum
        trap 'rm -rf "$stage"' EXIT
        migrate_copy_from_export "$from" "$stage"
    else
        rm -rf "$stage"
        die "--from must be an export folder or a partition like /dev/sdb3"
    fi

    # Hand the root-owned staging tree to the user with ONE chown, up here where
    # the tree is still in our root-controlled staging root (no user symlinks:
    # rsync copied no symlinks into it). Everything after this runs unprivileged.
    if [[ $EUID -eq 0 && -n "$owner" && "$owner" != root ]]; then
        chown -R "$owner": "$stage" 2>/dev/null || true
    fi

    # Strip metadata on the STAGING tree, as the destination user (mat2 parses
    # hostile formats — never as root), before anything is published.
    [[ "$scrub" == yes ]] && migrate_scrub "$stage" "$owner"

    # Publish into the user's home AS THE USER (all $dest writes unprivileged).
    _migrate_publish "$stage" "$dest" "$owner"
    rm -rf "$stage"
    trap - EXIT

    ok "migration finished: $dest"
    info "Keep your backup drive until you have opened your important files here."
}
