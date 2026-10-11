# KratosOS supply-chain ledger

Every third-party component KratosOS ships or fetches, and the controls around
it: how its **version is pinned**, how its **integrity is verified**, how it is
**confined** at runtime, and how it is **monitored** for tampering. This is the
"under lock and key" register — the honest version of "a modded, monitored,
locked-down build of everything."

> **On "XOR encrypted vault":** XOR is *not* encryption — a known-plaintext
> attack recovers the key instantly, so a XOR vault provides no confidentiality.
> KratosOS uses real at-rest encryption instead: **LUKS2 (AES-XTS)** full-disk
> encryption set up by the installer, plus the amnesic **LUKS2 vault** for
> Stealth secrets with an in-RAM (unswappable) key. The AI model, the Ollama
> runtime, and everything else at rest already live inside that encrypted
> volume. We do not ship snake-oil crypto.

## The four controls

| Control | What it means |
|---------|---------------|
| **Pinned** | A specific version is requested, not "latest". |
| **Verified** | The download is checked against a signature or a known hash and **fails closed** if it doesn't match. |
| **Confined** | The process runs sandboxed (systemd hardening, AppArmor, Firejail, or a VM boundary) with least privilege. |
| **Monitored** | Tampering after install is detectable (integrity baseline, boot measurement). |

## Components fetched at runtime (not in the ISO)

| Component | Pinned | Verified | Confined | Monitored |
|-----------|--------|----------|----------|-----------|
| **Whonix** (Gateway + Workstation images) | version resolved + recorded | **OpenPGP** signature against the pinned Whonix signing key; refuses unverified | runs as nested **KVM VMs** behind the Tor Gateway; sVirt/AppArmor dynamic labels; execute-only ACL to the vault | cache re-verified before reuse; freshness-checked |
| **Ollama runtime** (`kratos-ai`) | `KRATOS_AI_OLLAMA_VERSION` (GitHub release) | **SHA256** (baked pin `KRATOS_AI_OLLAMA_SHA256`, else the release's `sha256sum.txt`); archive members screened for traversal; extracted non-owner into `/usr/local`; **fails closed** | `ollama.service`: loopback-only, `NoNewPrivileges`, `ProtectSystem=strict`, restricted address families, confined `ReadWritePaths` | **integrity gate**: the binary's verified SHA256 is recorded at install and re-checked on **every service start** (`ExecStartPre`); daemon refuses to run on a mismatch. `kratos-ai verify` checks on demand |
| **AI model** (abliterated coder) | catalog tag / `KRATOS_AI_MODEL` | Ollama verifies each blob against its **manifest digest** | loopback-only inference; no outbound from the model | re-pull is digest-checked |
| **Open WebUI** (PyPI) | pip resolver | TLS to PyPI; installed **as the unprivileged `kratos-ai` user** (pip build code never runs as root) | `kratos-openwebui.service`: loopback-only, `PrivateDevices`, full systemd hardening | service-level; a hash-pinned requirements set is a tracked follow-up (the dep tree is large) |

## Components shipped in the ISO (Debian packages)

These come from the Debian **trixie** archive, which apt verifies with the
archive's **GPG keyring** on install and update. KratosOS then hardens their
configuration (nftables kill-switch, AppArmor enforcing, USBGuard, Firejail
symlinks, systemd-resolved DoT, polkit per-surface actions) and measures the
boot chain with `kratos bootcheck` (TPM PCRs / ESP hashes vs. a recorded
baseline).

## Honest limits

- **No upstream signature exists for the Ollama tarball** — SHA256 pinning is
  the strongest available; full origin-authentication would need upstream to
  sign releases.
- The integrity gate detects tampering of the installed runtime; an attacker who
  already has **root** can rewrite both the binary and its baseline, and is out
  of scope (they own the machine). The gate's value is against non-root
  tampering, at-rest corruption, and detection — layered on top of the
  root-only file permissions and full-disk encryption.
- Confinement is same-kernel (except Whonix/Stealth, which is a VM boundary). A
  kernel 0-day is mitigated by the architecture and by staying patched, not
  eliminated.
