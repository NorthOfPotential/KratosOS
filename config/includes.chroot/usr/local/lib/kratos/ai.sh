# shellcheck shell=bash
# KratosOS local AI coder — hardware detection, model selection, and
# provisioning of a fully-local Ollama + Open WebUI stack.
#
# Privacy stance: inference is 100% local. The ONLY network access is the
# one-time download of the runtime and the model (and, if you enable it,
# web search). Once provisioned the assistant works offline forever.
#
# This file is sourced by /usr/local/bin/kratos-ai, which has already sourced
# common.sh (ok/bad/warn/info/die/need_cmd) and set a hardened PATH.

# Where the local AI stack lives.
: "${AI_HOME:=/opt/kratos-ai}"
: "${AI_VENV:=$AI_HOME/venv}"
: "${AI_STATE:=/var/lib/kratos/ai}"
: "${OLLAMA_BIN:=/usr/local/bin/ollama}"
: "${OLLAMA_HOST:=127.0.0.1:11434}"
: "${WEBUI_HOST:=127.0.0.1}"
: "${WEBUI_PORT:=8080}"

# Pinned download sources (override for air-gapped mirrors / testing).
: "${KRATOS_AI_OLLAMA_URL:=https://ollama.com/download/ollama-linux-amd64.tgz}"

# ── Hardware detection ────────────────────────────────────────────────────────
# Each reader honors a KRATOS_AI_* override so the selection logic is unit
# testable without real hardware.

ai_total_ram_gb() {
    if [[ -n "${KRATOS_AI_RAM_GB:-}" ]]; then printf '%s\n' "$KRATOS_AI_RAM_GB"; return; fi
    local kb; kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
    [[ -n "$kb" ]] || { echo 0; return; }
    printf '%d\n' $(( kb / 1024 / 1024 ))
}

# Echoes: "<vendor> <vram_gb>"  (vendor one of nvidia|amd|intel|none)
ai_gpu_info() {
    if [[ -n "${KRATOS_AI_GPU:-}" ]]; then printf '%s %s\n' "$KRATOS_AI_GPU" "${KRATOS_AI_VRAM_GB:-0}"; return; fi
    local vendor=none vram=0 n
    if command -v nvidia-smi >/dev/null 2>&1 \
        && n="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1)" \
        && [[ "$n" =~ ^[0-9]+$ ]]; then
        vendor=nvidia; vram=$(( n / 1024 ))
    elif compgen -G '/sys/class/drm/card*/device/mem_info_vram_total' >/dev/null 2>&1; then
        local f bytes best=0
        for f in /sys/class/drm/card*/device/mem_info_vram_total; do
            bytes="$(cat "$f" 2>/dev/null)"; [[ "$bytes" =~ ^[0-9]+$ ]] || continue
            (( bytes > best )) && best="$bytes"
        done
        (( best > 0 )) && { vendor=amd; vram=$(( best / 1024 / 1024 / 1024 )); }
    elif command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qiE 'VGA.*(NVIDIA)'; then
        vendor=nvidia   # present but VRAM unknown without the driver tools
    elif command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qiE 'VGA.*(Advanced Micro Devices|AMD/ATI)'; then
        vendor=amd
    elif command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qiE 'VGA.*Intel'; then
        vendor=intel
    fi
    printf '%s %s\n' "$vendor" "$vram"
}

# Is there an NPU? We can DETECT one but cannot yet USE it: as of this writing
# no Ollama/llama.cpp build offloads LLM inference to consumer NPUs on Linux
# (Intel AI Boost / AMD XDNA / Qualcomm Hexagon). We report it honestly and
# leave this as the integration point for when upstream support lands.
ai_npu_present() {
    [[ -n "${KRATOS_AI_NPU:-}" ]] && { [[ "$KRATOS_AI_NPU" == 1 ]]; return; }
    compgen -G '/sys/class/accel/accel*' >/dev/null 2>&1 && return 0
    if command -v lspci >/dev/null 2>&1; then
        lspci 2>/dev/null | grep -qiE 'Neural|NPU|AI Boost|Versal|XDNA|VPU' && return 0
    fi
    return 1
}

# Effective memory budget (GB) the biggest model may use: prefer discrete-GPU
# VRAM when it is the limiting resource, otherwise system RAM minus a reserve
# for the OS/desktop. A GPU with its own VRAM runs the model there; CPU-only
# machines run in RAM, so leave headroom.
ai_budget_gb() {
    local ram vram gpu; ram="$(ai_total_ram_gb)"
    read -r gpu vram < <(ai_gpu_info)
    local ram_usable=$(( ram > 3 ? ram - 2 : 1 ))
    # A usable discrete GPU (>=4 GB VRAM) sets the budget; else fall back to RAM.
    if [[ "$gpu" == nvidia || "$gpu" == amd ]] && (( vram >= 4 )); then
        (( vram > ram_usable )) && { printf '%d\n' "$vram"; return; }
    fi
    printf '%d\n' "$ram_usable"
}

# ── Model catalog ─────────────────────────────────────────────────────────────
# Abliterated (uncensored) coder models, published on the Ollama registry by
# huihui_ai, sized to the hardware. Pick the largest whose q4 weights fit the
# budget with headroom for context. Override with KRATOS_AI_MODEL=<ollama tag>.
#
# Approx on-disk / resident size at the default quant is noted per tier.
#   32b  ~20 GB | 14b  ~9 GB | 7b  ~4.7 GB | 3b  ~2 GB | 1.5b  ~1 GB
# The 32b tier is as large as a single workstation GPU realistically runs; the
# giant general models (e.g. GLM-4.6, 355B MoE) need many tens of GB of VRAM
# and are intentionally NOT auto-selected — set KRATOS_AI_MODEL to force one.
ai_pick_model() {   # <budget_gb> -> echoes "<ollama-tag> <label>"
    local b="${1:-0}"
    if [[ -n "${KRATOS_AI_MODEL:-}" ]]; then printf '%s %s\n' "$KRATOS_AI_MODEL" "(user-pinned)"; return; fi
    local base=huihui_ai/qwen2.5-coder-abliterate
    if   (( b >= 40 )); then printf '%s:32b 32B abliterated coder\n'  "$base"
    elif (( b >= 18 )); then printf '%s:14b 14B abliterated coder\n'  "$base"
    elif (( b >= 9  )); then printf '%s:7b 7B abliterated coder\n'    "$base"
    elif (( b >= 5  )); then printf '%s:3b 3B abliterated coder\n'    "$base"
    else                     printf '%s:1.5b 1.5B abliterated coder\n' "$base"
    fi
}

# Human-readable detection summary (used by `kratos-ai detect` and `status`).
ai_report_hardware() {
    local ram gpu vram budget model label
    ram="$(ai_total_ram_gb)"
    read -r gpu vram < <(ai_gpu_info)
    budget="$(ai_budget_gb)"
    read -r model label < <(ai_pick_model "$budget")
    info "Hardware:"
    ok "RAM: ${ram} GB"
    case "$gpu" in
        nvidia) ok "GPU: NVIDIA${vram:+, ${vram} GB VRAM} (CUDA acceleration)";;
        amd)    ok "GPU: AMD${vram:+, ${vram} GB VRAM} (ROCm/Vulkan acceleration)";;
        intel)  ok "GPU: Intel (Vulkan/SYCL acceleration)";;
        *)      warn "GPU: none detected — inference will run on CPU + RAM";;
    esac
    if ai_npu_present; then
        warn "NPU: present, but NOT usable for inference yet (no Ollama/llama.cpp NPU offload on Linux); CPU/GPU will be used"
    else
        info "  NPU: none detected"
    fi
    ok "Memory budget for the model: ~${budget} GB"
    ok "Auto-selected model: ${model}  (${label})"
}
