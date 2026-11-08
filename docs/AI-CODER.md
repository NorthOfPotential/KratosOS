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
- Ollama's API has no password, so the firewall decides who may reach it
  (`/etc/kratos/ai-loopback.nft`, in every network mode): root, people's own
  accounts (uid 1000–59999) and the `ollama`/`kratos-ai` service accounts.
  Any other account on the machine (e.g. a compromised system service) is
  refused, so it can't run, download or delete models. Open WebUI has its own
  login.
- **Web search** (optional, toggled per-chat in the UI) makes outbound requests
  to a search engine (DuckDuckGo by default) — that traffic goes out like any
  other, subject to your current `kratos mode` (normal/VPN/offline).
- The services ship **disabled**; they are enabled only after `kratos-ai setup`.
- Open WebUI's **usage telemetry is switched off** in its service
  (`SCARF_NO_ANALYTICS`, `DO_NOT_TRACK`, `ANONYMIZED_TELEMETRY=false`), the same
  opt-outs upstream bakes into its container image but a pip install lacks.
- Open WebUI's **"new version available" check is off**
  (`ENABLE_VERSION_UPDATE_CHECK=false`); upgrades come from `kratos-ai setup`.
  On first use of document chat it downloads its small embedding model from
  Hugging Face (one time, subject to your `kratos mode`).

## Download integrity

`kratos-ai setup` installs code as root, so the downloads are verified:

- The **Ollama runtime** is pinned to **v0.40.15** (current on 2026-11-06)
  with its official `.tar.zst` release-asset SHA256 embedded in the build.
  The checksum is verified before extraction (fail-closed), and the tar stream
  is screened for path traversal, symlink escapes and special files.
  A verified older installed Ollama is **upgraded** on the next
  `sudo kratos-ai setup` instead of being silently reused. To override the
  digest when intentionally using an alternative pinned release:
  ```
  sudo KRATOS_AI_OLLAMA_SHA256=<hex> kratos-ai setup
  ```
  Full origin authentication (a signature over the tarball) isn't offered
  upstream, so this verifies integrity against the pinned release; the SHA256
  pin is the strongest available.
- **Open WebUI** is pinned to **0.13.1** rather than a versionless PyPI
  install: 0.12.3, 0.12.4, 0.12.5, 0.13.0 and 0.13.1 each shipped security fixes that
  upstream says to apply as soon as possible, so older pins are known
  vulnerable. Setup checks the installed version and rebuilds out-of-date
  environments.
- **Open WebUI's dependencies** (~240 packages, PyTorch included) are
  installed from a **hash-pinned lock** shipped in the image
  (`/usr/local/share/kratos/ai/openwebui-cpu.lock`, or `-nvidia.lock` with an
  NVIDIA GPU): every package at one exact version, and pip refuses any file
  whose SHA256 isn't in the lock, so a library replaced on PyPI after the lock
  was made can't be installed. Wheels only (no package builds from source).
  The locks are generated with `tools/lock-openwebui.sh` (CI job
  `lock-openwebui`) whenever the Open WebUI version changes.
- **Python for Open WebUI.** Open WebUI supports only Python 3.11/3.12, while
  Debian 13 ships 3.13, and the locks are resolved for 3.12. Setup uses a
  system 3.12 if one exists; otherwise
  (the normal case) it provisions an **app-private CPython 3.12** under
  `/opt/kratos-ai/python` with **uv**. uv itself is installed from a single
  **hash-pinned** PyPI wheel (`pip --require-hashes`), and uv verifies the
  interpreter download against the checksums built into that pinned release.
  This runs as the unprivileged `kratos-ai` account; the interpreter and the
  venv are then made **root-owned and read-only** to the service (still
  readable, so it can start). Only `/opt/kratos-ai/data` is writable.
  **Dependency pinning is not a substitute for future security updates** —
  re-run `sudo kratos-ai setup` after a KratosOS update to pick up new pins.
- **Models** are pulled by Ollama, which verifies each blob against its
  manifest digest.
