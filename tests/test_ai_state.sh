#!/usr/bin/env bash
# Root-only regression for the AI installer state-directory symlink attack.
# Exercises the REAL prepare_ai_state/save_ai_control_file functions with
# disposable paths, never a real AI installation.
# shellcheck disable=SC1090,SC1091,SC2016
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
cli="$here/../config/includes.chroot/usr/local/bin/kratos-ai"
[[ $EUID -eq 0 ]] || { echo "SKIP: requires root"; exit 0; }
id mallory >/dev/null 2>&1 || { echo "SKIP: requires mallory account"; exit 0; }
getent group ollama >/dev/null || groupadd -r ollama
getent passwd ollama >/dev/null || useradd -r -g ollama -s /usr/sbin/nologin ollama
. "$lib/common.sh"
# Read only two function definitions, without executing the CLI dispatcher.
source <(sed -n '/^prepare_ai_state() {/,/^}/p' "$cli")
source <(sed -n '/^save_ai_control_file() {/,/^}/p' "$cli")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 755 "$tmp"
AI_STATE="$tmp/ai"
install -d -m 755 -o mallory "$AI_STATE"
printf '%s\n' "ROOT_CANARY" > "$tmp/canary"
chmod 600 "$tmp/canary"
# A compromised service account prepares a symlink at the future baseline.
runuser -u mallory -- ln -s "$tmp/canary" "$AI_STATE/ollama.sha256"

prepare_ai_state
save_ai_control_file "$AI_STATE/ollama.sha256" "verifiedhash" 600
[[ "$(cat "$tmp/canary")" == ROOT_CANARY ]] \
    || { echo "FAIL: root overwrite escaped AI state directory"; exit 1; }
[[ ! -L "$AI_STATE/ollama.sha256" && "$(stat -c '%u' "$AI_STATE/ollama.sha256")" == 0 ]] \
    || { echo "FAIL: baseline was not replaced atomically by a root-owned file"; exit 1; }
[[ "$(stat -c '%u' "$AI_STATE")" == 0 ]] \
    || { echo "FAIL: AI control parent is not root-owned"; exit 1; }
if runuser -u ollama -- sh -c 'echo forged > "$1"' _ "$AI_STATE/ollama.sha256" 2>/dev/null; then
    echo "FAIL: Ollama service can modify the root integrity baseline"
    exit 1
fi
if ! runuser -u ollama -- touch "$AI_STATE/models/testfile"; then
    echo "FAIL: Ollama cannot write into its designated model store"
    exit 1
fi
echo "PASS: root control state resists daemon symlinks, model store remains usable"
