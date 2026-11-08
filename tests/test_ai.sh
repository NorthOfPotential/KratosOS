#!/usr/bin/env bash
# shellcheck disable=SC2016 # intentional literal $VARIABLE patterns in grep assertions
# Local AI coder: model selection scales with hardware, the picker is
# overridable, and the CLI/services/launcher are shipped correctly (disabled,
# gated on their binaries, provisioned on first run). Real provisioning (Ollama
# download, model pull, Open WebUI) needs network + hardware and is NOT run here.
# shellcheck disable=SC1091
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../config/includes.chroot"
lib="$root/usr/local/lib/kratos"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

unset KRATOS_AI_MODEL KRATOS_AI_RAM_GB KRATOS_AI_GPU KRATOS_AI_VRAM_GB KRATOS_AI_NPU 2>/dev/null || true
# shellcheck source=../config/includes.chroot/usr/local/lib/kratos/ai.sh
. "$lib/ai.sh"

echo "— model picker scales with the memory budget —"
check_model() {   # <budget> <expected-substr>
    local got; got="$(ai_pick_model "$1" | awk '{print $1}')"
    if [[ "$got" == *"$2"* ]]; then pass "budget ${1}GB -> $got"; else flunk "budget ${1}GB gave $got (want *$2*)"; fi
}
check_model 64 ":32b"
check_model 24 ":14b"
check_model 12 ":7b"
check_model 6  ":3b"
check_model 3  ":1.5b"

echo "— user pin overrides the picker —"
if [[ "$(KRATOS_AI_MODEL='foo/bar:latest' ai_pick_model 64 | awk '{print $1}')" == "foo/bar:latest" ]]; then
    pass "KRATOS_AI_MODEL overrides the catalog"
else flunk "KRATOS_AI_MODEL pin ignored"; fi

echo "— memory budget: discrete GPU VRAM wins only when it is the larger resource —"
b="$(KRATOS_AI_RAM_GB=16 KRATOS_AI_GPU=nvidia KRATOS_AI_VRAM_GB=24 ai_budget_gb)"
if [[ "$b" == 24 ]]; then pass "24GB VRAM beats 16GB RAM"; else flunk "GPU budget wrong ($b)"; fi
b="$(KRATOS_AI_RAM_GB=16 KRATOS_AI_GPU=none KRATOS_AI_VRAM_GB=0 ai_budget_gb)"
if [[ "$b" == 14 ]]; then pass "CPU-only: 16GB RAM -> 14GB budget (reserve)"; else flunk "RAM budget wrong ($b)"; fi
b="$(KRATOS_AI_RAM_GB=32 KRATOS_AI_GPU=amd KRATOS_AI_VRAM_GB=2 ai_budget_gb)"
if [[ "$b" == 30 ]]; then pass "tiny 2GB VRAM ignored; 30GB RAM budget"; else flunk "small-VRAM budget wrong ($b)"; fi

echo "— CLI, services and launcher are present / parse / gated —"
if bash -n "$root/usr/local/bin/kratos-ai"; then pass "kratos-ai parses"; else flunk "kratos-ai syntax error"; fi
for u in ollama.service kratos-openwebui.service; do
    f="$root/etc/systemd/system/$u"
    if [[ -f "$f" ]] && grep -q '^ExecStart=' "$f" && grep -q '^ConditionPathExists=' "$f" \
       && grep -q '^\(Environment=.*127\.0\.0\.1\|Environment=OLLAMA_HOST=127\.0\.0\.1\)' "$f"; then
        pass "$u shipped, loopback-bound, gated on its binary"
    else flunk "$u missing / not gated / not loopback-bound"; fi
done
# VM test: `open-webui serve` writes .webui_secret_key into its cwd; with the
# default cwd (/) under ProtectSystem=strict the service crash-looped (EROFS).
ow="$root/etc/systemd/system/kratos-openwebui.service"
if grep -qx 'WorkingDirectory=/opt/kratos-ai/data' "$ow" \
   && grep -qx 'ReadWritePaths=/opt/kratos-ai/data' "$ow" \
   && grep -qx 'UMask=0077' "$ow"; then
    pass "Open WebUI runs from its writable data dir (secret key not written to read-only /), private umask"
else flunk "Open WebUI cwd is not its writable data dir (crash-loops writing .webui_secret_key)"; fi
if grep -qx 'Environment=DO_NOT_TRACK=true' "$ow" && grep -qx 'Environment=SCARF_NO_ANALYTICS=true' "$ow" \
   && grep -qx 'Environment=ANONYMIZED_TELEMETRY=false' "$ow" \
   && grep -qx 'Environment=ENABLE_VERSION_UPDATE_CHECK=false' "$ow"; then
    pass "Open WebUI telemetry opt-outs and update check off"
else flunk "Open WebUI telemetry opt-outs missing"; fi
d="$root/usr/share/applications/kratos-ai.desktop"
if [[ -f "$d" ]] && grep -q '^Exec=.*kratos-ai' "$d"; then pass "Kratos AI launcher present"; else flunk "launcher missing"; fi

cli="$root/usr/local/bin/kratos-ai"
echo "— patched third-party versions must be enforced (not just documented) —"
if grep -q 'v0.40.15' "$lib/ai.sh" \
   && grep -q 'ollama-linux-amd64.tar.zst' "$lib/ai.sh" \
   && grep -q 'ollama version is' "$cli" \
   && grep -q 'webui_version="0.13.1"' "$cli" \
   && grep -qF 'grep -qxF "open-webui==$webui_version \\" "$lock"' "$cli"; then
    pass "security-patched Ollama and Open WebUI releases are selected and verified"
else flunk "AI runtime still risks installing a vulnerable version"; fi

# VM test: runuser inherits the caller's cwd (their home, unreadable to the
# kratos-ai account) and `uv python find` died probing ./.venv there.
if sed -n '/^cmd_setup()/,/^}/p' "$cli" | grep -qE '^[[:space:]]+cd / '; then
    pass "setup runs from a neutral cwd (unprivileged steps never touch the caller's home)"
else flunk "setup runs the unprivileged uv/pip steps from the caller's cwd"; fi

if grep -q 'it needs 3.12' "$cli" \
   && grep -q 'for candidate in python3.12 python3; do' "$cli" \
   && grep -qF '[[ "$version" == 3.12 ]]' "$cli" \
   && grep -q 'provision_python312' "$cli"; then
    pass "Open WebUI runs on 3.12 (what the locks are resolved for), never 3.13; a private 3.12 is provisioned"
else flunk "Open WebUI may run on unsupported Python or downgrade insecurely"; fi

echo "— the app-private Python is supply-chain pinned and sealed —"
if grep -qE '^UV_VERSION="[0-9.]+"' "$cli" && grep -qE '^UV_WHEEL_SHA256="[0-9a-f]{64}"' "$cli" \
   && grep -q -- '--require-hashes' "$cli" && grep -q -- '--only-binary=:all:' "$cli"; then
    pass "uv comes from a single hash-pinned wheel (pip --require-hashes)"
else flunk "uv bootstrap is not hash-pinned"; fi
if grep -q 'runuser -u kratos-ai -- "${uvenv\[@\]}"' "$cli" \
   && grep -q 'chown -R root:root "$pydir"' "$cli"; then
    pass "interpreter is fetched unprivileged, then made root-owned"
else flunk "interpreter provisioning runs as root or stays service-writable"; fi

echo "— sealed code stays READABLE by the service (else the WebUI cannot start) —"
if grep -q 'chmod -R go-w,go+rX "$AI_VENV"' "$cli" && grep -q 'chmod -R go-w,go+rX "$pydir"' "$cli" \
   && ! grep -qE 'chmod -R go-w "\$(AI_VENV|pydir)"' "$cli"; then
    pass "venv + interpreter are root-owned, non-writable, but traversable by kratos-ai"
else flunk "sealed venv may be unreadable by the kratos-ai service (750 root:root)"; fi

echo "— supply-chain: the Ollama runtime download is verified before it is unpacked as root —"
cli="$root/usr/local/bin/kratos-ai"
if grep -q 'sha256sum ' "$cli" && grep -q 'FAILED checksum' "$cli" \
   && grep -q 'cannot verify the Ollama download' "$cli"; then
    pass "Ollama tarball SHA256 is verified, failing closed when no checksum"
else flunk "Ollama download is not checksum-verified (root-RCE risk)"; fi
if grep -q 'refusing to extract' "$cli" && grep -q 'check-ollama-archive.py' "$cli"; then
    pass "archive members are screened for path traversal before extraction"
else flunk "no path-traversal screen before tar extraction"; fi
if grep -qF -- '-C /usr/local' "$cli" && grep -q 'tar --zstd -xf' "$cli"; then
    pass "extracts into /usr/local (matches OLLAMA_BIN), not bare /usr"
else flunk "extraction target mismatch with OLLAMA_BIN"; fi
if grep -q 'runuser -u kratos-ai -- "$AI_VENV/bin/pip" install' "$cli"; then
    pass "Open WebUI pip install runs as the unprivileged kratos-ai user, not root"
else flunk "pip install still runs as root (hostile-dependency root-RCE)"; fi

echo "— tamper monitoring: the Ollama runtime is integrity-gated on every start —"
if grep -q 'save_ai_control_file "$OLLAMA_SHA_BASELINE"' "$cli" && grep -q 'mv -Tf' "$cli"; then
    pass "install records a SHA256 integrity baseline for the binary"
else flunk "no integrity baseline recorded at install"; fi
if grep -q 'INTEGRITY FAILURE' "$cli" && grep -qE 'verify-ollama\)' "$cli"; then
    pass "verify_ollama fails closed on a binary mismatch"
else flunk "no fail-closed integrity verification"; fi
if grep -qE '^ExecStartPre=\+/usr/local/bin/kratos-ai verify-ollama' "$root/etc/systemd/system/ollama.service"; then
    pass "ollama.service re-verifies the binary (ExecStartPre) before every start"
else flunk "ollama.service has no ExecStartPre integrity gate"; fi

echo "— daemon cannot alter root-written integrity state —"
if grep -q 'install -d -m 755 -o root -g root "$AI_STATE"' "$cli" \
   && grep -q 'install -d -m 750 -o ollama -g ollama "$AI_STATE/models"' "$cli" \
   && grep -q '^ReadWritePaths=/var/lib/kratos/ai/models' "$root/etc/systemd/system/ollama.service" \
   && ! grep -Fxq 'ReadWritePaths=/var/lib/kratos/ai' "$root/etc/systemd/system/ollama.service"; then
    pass "root-owned control directory, daemon-writable models only"
else
    flunk "daemon can write root-owned control state"
fi

echo "— WebUI must not persist compromised code across restarts —"
if grep -q 'chown -R root:root "$AI_VENV"' "$cli" \
   && grep -q 'chmod -R go-w,go+rX "$AI_VENV"' "$cli" \
   && grep -q '^ReadWritePaths=/opt/kratos-ai/data' "$root/etc/systemd/system/kratos-openwebui.service" \
   && ! grep -Fxq 'ReadWritePaths=/opt/kratos-ai' "$root/etc/systemd/system/kratos-openwebui.service"; then
    pass "WebUI code is root-owned, only user data is writable"
else
    flunk "WebUI service can change its own startup code"
fi

echo "— AI services are sandboxed (NoNewPrivileges + ProtectSystem=strict) —"
for u in ollama.service kratos-openwebui.service; do
    f="$root/etc/systemd/system/$u"
    if grep -q '^NoNewPrivileges=yes' "$f" && grep -q '^ProtectSystem=strict' "$f" \
       && grep -q '^RestrictAddressFamilies=' "$f"; then
        pass "$u hardened (no-new-privs, strict system, restricted address families)"
    else flunk "$u missing baseline sandboxing"; fi
done

echo "— AI services ship DISABLED (provisioned by 'kratos-ai setup', not at build) —"
if ! grep -rq 'ollama\.service\|kratos-openwebui\.service' "$here/../config/hooks/live/" 2>/dev/null; then
    pass "AI services are not auto-enabled during the build"
else flunk "AI services enabled at build (must be enabled only after setup)"; fi

echo "— disk-space preflight and CPU-only PyTorch (VM test: ENOSPC on a 21 GB root) —"
if [[ "$(ai_model_disk_gb huihui_ai/qwen2.5-coder-abliterate:3b)" == 2 \
   && "$(ai_model_disk_gb huihui_ai/qwen2.5-coder-abliterate:32b)" == 20 \
   && "$(ai_model_disk_gb some/user-pinned:tag)" == 0 ]]; then
    pass "catalog models have an on-disk size; unknown tags are not size-checked"
else flunk "ai_model_disk_gb sizes wrong"; fi
if (( $(ai_webui_disk_gb none) < $(ai_webui_disk_gb nvidia) )); then
    pass "Open WebUI needs less space without NVIDIA (CPU-only PyTorch)"
else flunk "webui size does not account for the CPU-only PyTorch build"; fi
fake="$(mktemp -d)"
printf '#!/bin/sh\necho "Filesystem 1G-blocks Used Available Capacity Mounted"\necho "/dev/x 21G 20G 3G 95%% /"\n' > "$fake/df"
chmod +x "$fake/df"
# shellcheck disable=SC2317  # called indirectly by ai_require_free
die() { echo "DIE: $*"; return 1; }
if out="$(PATH="$fake:$PATH" ai_require_free / 4 "Open WebUI")"; then
    flunk "3 GB free passed a 4 GB (+1) requirement"
elif [[ "$out" == *"needs about 5 GB"*"only 3 GB"* ]]; then
    pass "too little space fails early with a clear message"
else flunk "unexpected preflight message: $out"; fi
if PATH="$fake:$PATH" ai_require_free / 2 "the model" >/dev/null; then
    pass "enough space passes"
else flunk "2 GB (+1) requirement refused with 3 GB free"; fi
rm -rf "$fake"; unset -f die
if grep -q 'ai_require_free /usr/local 3' "$cli" \
   && grep -q 'ai_require_free "$AI_STATE/models"' "$cli" \
   && grep -q 'ai_require_free "$AI_HOME"' "$cli"; then
    pass "setup checks free space before the runtime, model and Open WebUI downloads"
else flunk "a large setup step is not space-checked"; fi
if grep -q 'extra_index=(--extra-index-url "$KRATOS_AI_TORCH_CPU_INDEX")' "$cli" \
   && grep -q 'KRATOS_AI_TORCH_CPU_INDEX:=https://download.pytorch.org/whl/cpu' "$lib/ai.sh" \
   && grep -q 'lock="$KRATOS_AI_LOCK_DIR/openwebui-cpu.lock"' "$cli" \
   && grep -q '"$gpu_vendor" == nvidia' "$cli"; then
    pass "without an NVIDIA GPU the CPU-only PyTorch lock is installed (HTTPS, official index)"
else flunk "CUDA PyTorch is installed even without an NVIDIA GPU"; fi

echo "— temp-dir cleanup traps don't outlive their function (VM test: setup exited 1) —"
# The real trap line from install_ollama, run under set -u inside a nested call
# exactly as cmd_setup -> install_ollama does.
trapline="$(grep -m1 'trap ".*trap - RETURN" RETURN' "$cli" | sed 's/^[[:space:]]*//')"
if [[ -n "$trapline" ]] && out="$(bash -c '
    set -euo pipefail
    inner() { local tmp; tmp="$(mktemp -d)"; '"$trapline"'; echo "$tmp"; }
    outer() { d="$(inner)"; [[ ! -e "$d" ]] || { echo "LEFT $d"; exit 3; }; inner >/dev/null; echo OUTER-DONE; }
    outer; echo REACHED-END' 2>&1)" && grep -q 'REACHED-END' <<<"$out"; then
    pass "install_ollama's cleanup runs once, removes the dir, and the caller returns cleanly under set -u"
else
    flunk "temp-dir trap breaks the caller: ${out:-no trap line found}"
fi
bad_traps="$(grep -rn 'trap .*RETURN' "$cli" "$lib" | grep -v 'trap - RETURN" RETURN' || true)"
if [[ -z "$bad_traps" ]]; then
    pass "every RETURN trap in kratos-ai and lib/kratos clears itself after running"
else
    flunk "RETURN traps that persist past their function: $bad_traps"
fi

echo "— Open WebUI and every library under it come from a hash-pinned lock —"
locks="$root/usr/local/share/kratos/ai"
webui="$(sed -n 's/^[[:space:]]*local webui_version="\([^"]*\)".*/\1/p' "$cli")"
if grep -q 'KRATOS_AI_LOCK_DIR:=/usr/local/share/kratos/ai' "$lib/ai.sh" \
   && grep -q 'KRATOS_AI_SKIP_SPACE_CHECK KRATOS_AI_LOCK_DIR' "$cli"; then
    pass "lock directory is fixed for the installed binary (not caller-selectable)"
else flunk "lock directory can be redirected by the caller"; fi
# The install must be hash-checked, wheel-only and resolve nothing, and pip
# must not fetch anything unpinned (the old "pip install --upgrade pip" did).
inst="$(sed -n '/^setup_webui()/,/^}/p' "$cli")"
if grep -q -- '--require-hashes --no-deps' <<<"$inst" \
   && grep -qF -- '--only-binary=:all: "${extra_index[@]}" -r "$lock"' <<<"$inst" \
   && ! grep -q -- '--upgrade pip' <<<"$inst" \
   && [[ "$(grep -c 'bin/pip" install' <<<"$inst")" == 1 ]]; then
    pass "setup_webui's only pip install is hash-checked, wheels-only, no dependency resolution"
else flunk "setup_webui installs something that is not hash-pinned"; fi
for v in cpu nvidia; do
    f="$locks/openwebui-$v.lock"
    if [[ ! -f "$f" ]]; then flunk "$v lock missing"; continue; fi
    # Every requirement is name==version followed by at least one sha256 hash;
    # nothing unpinned, no URLs/VCS/editables, no index or option lines.
    if res="$(python3 "$here/check_lock.py" "$f")"; then
        pass "$v lock: all $res packages pinned to one version with sha256 hashes"
    else flunk "$v lock has unpinned or unhashed entries: $res"; fi
    if grep -qxF "open-webui==$webui \\" "$f"; then pass "$v lock pins open-webui==$webui (matches kratos-ai)"
    else flunk "$v lock is not for open-webui $webui (regenerate: tools/lock-openwebui.sh)"; fi
done
if grep -Eq '^torch==[^ ]+\+cpu \\$' "$locks/openwebui-cpu.lock" \
   && ! grep -Eq '^nvidia-' "$locks/openwebui-cpu.lock"; then
    pass "CPU lock: CPU-only PyTorch, no NVIDIA CUDA libraries"
else flunk "CPU lock would pull CUDA PyTorch"; fi
if grep -Eq '^torch==[0-9.]+ \\$' "$locks/openwebui-nvidia.lock"; then
    pass "NVIDIA lock: regular (CUDA) PyTorch"
else flunk "NVIDIA lock has no CUDA PyTorch"; fi
# The lock checker itself must reject what it is meant to catch.
bad="$(mktemp)"
printf 'requests==2.0 \\\n    --hash=sha256:%064d\nflask>=1.0\n' 0 > "$bad"
if ! python3 "$here/check_lock.py" "$bad" >/dev/null 2>&1; then pass "lock checker rejects an unpinned entry"
else flunk "lock checker accepted an unpinned entry"; fi
printf 'requests==2.0\nurllib3==2.0 \\\n    --hash=sha256:%064d\n' 0 > "$bad"
if ! python3 "$here/check_lock.py" "$bad" >/dev/null 2>&1; then pass "lock checker rejects an entry without a hash"
else flunk "lock checker accepted an unhashed entry"; fi
rm -f "$bad"
gen="$here/../tools/lock-openwebui.sh"
if [[ -x "$gen" ]] && grep -q -- '--generate-hashes --only-binary :all:' "$gen" \
   && grep -q 'explicit = true' "$gen"; then
    pass "lock generator: hashes, wheels only, CPU torch only from PyTorch's index"
else flunk "lock generator missing or weaker than the install"; fi

exit "$fail"
