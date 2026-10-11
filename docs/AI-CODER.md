# Kratos AI — the local AI coder

A fully-local AI assistant built into KratosOS: code generation, chat, and
optional web search, running entirely on your own machine. Nothing you type or
generate leaves the device. It is auto-sized to your hardware and uses an
**abliterated (uncensored) coder model** by default — appropriate for a
security/privacy workstation where refusals on legitimate research get in the
way.

## What it is

- **Backend:** [Ollama](https://ollama.com) — runs the model locally.
- **Front-end:** [Open WebUI](https://openwebui.com) on `http://127.0.0.1:8080`
  (loopback only; never exposed on the network) — chat, code blocks, model
  switching, document/RAG upload, and web search.
- **Model:** the largest **abliterated Qwen2.5-Coder** that fits your hardware,
  chosen automatically (1.5B → 32B). Override with `KRATOS_AI_MODEL`.
- **Control:** the `kratos-ai` command.

## First run

The runtime and model are **not** baked into the ISO — they are multi-GB and
hardware-specific. On first launch they download once, then the assistant works
**offline forever after**.

```
sudo kratos-ai setup     # detect hardware, install runtime, pull best-fit model
kratos-ai ui             # open the assistant in your browser
```

Or just click **Kratos AI** in the application menu — on first run it opens a
terminal and runs `setup` for you.

You need a network connection for `setup` (and for web search). In **offline
mode** the download is blocked by the kill-switch, by design — switch with
`sudo kratos mode normal` first. Once provisioned, local code generation works
in any mode, including offline.

## Commands

```
kratos-ai detect         # show detected hardware + which model would be chosen
kratos-ai status         # hardware, chosen model, and service state
kratos-ai ui             # open the UI
kratos-ai start | stop   # start/stop the local AI services
kratos-ai model list     # installed models
kratos-ai model pull <ollama-tag>   # add another model
kratos-ai model use  <ollama-tag>   # set the default
```

## Hardware acceleration — the honest picture

| Resource | Status |
|----------|--------|
| **CPU + RAM** | Always used. CPU-only machines run smaller models in RAM. |
| **NVIDIA GPU** | Used via CUDA when the proprietary driver is present. |
| **AMD GPU** | Used via ROCm/Vulkan when supported. |
| **Intel GPU** | Used via Vulkan/SYCL where supported. |
| **NPU** (Intel AI Boost, AMD XDNA, Qualcomm Hexagon) | **Detected but not used.** As of this writing no Ollama/llama.cpp build offloads LLM inference to consumer NPUs on Linux. `kratos-ai` reports the NPU honestly and leaves the integration point for when upstream support lands. |

The model picker sets a **memory budget** from the larger of your discrete-GPU
VRAM (≥4 GB) or system RAM (minus a reserve), then selects the largest model
that fits:

| Budget | Model (abliterated coder) | approx size |
|-------:|---------------------------|------------:|
| ≥ 40 GB | `huihui_ai/qwen2.5-coder-abliterate:32b` | ~20 GB |
| ≥ 18 GB | `…:14b` | ~9 GB |
| ≥ 9 GB  | `…:7b`  | ~4.7 GB |
| ≥ 5 GB  | `…:3b`  | ~2 GB |
| else    | `…:1.5b`| ~1 GB |

### About the giant models

Models like **GLM-4.6** (~355B MoE) need many tens of GB of VRAM — far beyond a
laptop — so they are **not** auto-selected. On a workstation with the VRAM for
one, pin it explicitly before setup:

```
sudo KRATOS_AI_MODEL=<ollama-tag> kratos-ai setup
```

## Privacy notes

- Inference is 100% local. The model never phones home.
- The UI and Ollama bind to **loopback only**.
- **Web search** (optional, toggled per-chat in the UI) makes outbound requests
  to a search engine (DuckDuckGo by default) — that traffic goes out like any
  other, subject to your current `kratos mode` (normal/VPN/offline).
- The services ship **disabled**; they are enabled only after `kratos-ai setup`.
