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
d="$root/usr/share/applications/kratos-ai.desktop"
if [[ -f "$d" ]] && grep -q '^Exec=.*kratos-ai' "$d"; then pass "Kratos AI launcher present"; else flunk "launcher missing"; fi

echo "— supply-chain: the Ollama runtime download is verified before it is unpacked as root —"
cli="$root/usr/local/bin/kratos-ai"
if grep -q 'sha256sum ' "$cli" && grep -q 'FAILED checksum' "$cli" \
   && grep -q 'cannot verify the Ollama download' "$cli"; then
    pass "Ollama tarball SHA256 is verified, failing closed when no checksum"
else flunk "Ollama download is not checksum-verified (root-RCE risk)"; fi
if grep -q 'refusing to extract' "$cli" && grep -q 'check-ollama-archive.py' "$cli"; then
    pass "archive members are screened for path traversal before extraction"
else flunk "no path-traversal screen before tar extraction"; fi
if grep -qF -- '-C /usr/local' "$cli" && ! grep -qE -- 'tar -xzf [^ ]+ -C /usr[[:space:]]' "$cli"; then
    pass "extracts into /usr/local (matches OLLAMA_BIN), not bare /usr"
else flunk "extraction target mismatch with OLLAMA_BIN"; fi
if grep -qE 'runuser -u kratos-ai -- .*pip.? install open-webui' "$cli"; then
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
   && grep -q 'chmod -R go-w "$AI_VENV"' "$cli" \
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

exit "$fail"
