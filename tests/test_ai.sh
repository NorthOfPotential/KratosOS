#!/usr/bin/env bash
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

echo "— AI services ship DISABLED (provisioned by 'kratos-ai setup', not at build) —"
if ! grep -rq 'ollama\.service\|kratos-openwebui\.service' "$here/../config/hooks/live/" 2>/dev/null; then
    pass "AI services are not auto-enabled during the build"
else flunk "AI services enabled at build (must be enabled only after setup)"; fi

exit "$fail"
