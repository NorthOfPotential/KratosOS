# Prompt for a local Claude Code session on your Windows PC

Paste everything below the line into a new **local** Claude Code session (the
Claude desktop app's Code tab, or `claude` in a terminal) opened on your
Windows PC. That session can run VirtualBox and see your files; this cloud
session can't.

---

You are taking over the KratosOS project in a LOCAL session on my Windows PC
(VirtualBox is installed). A cloud Claude session did the work so far; this is
the handoff. Read it fully, then work through the tasks in order. Ask me before
anything destructive.

## Hard rules (from me, the owner)

- **Don't clear or damage my PC.** Non-destructive only. Only ever delete things
  you created (e.g. the test VM and its disk). Ask before installing software,
  changing system settings, or deleting anything else.
- Never run `kratos panic`, `kratos shred` or anything that wipes, unless I say
  so for that specific run.
- Never disable TLS verification, never bypass security tooling, never weaken a
  security control to make a test pass.
- GitHub: act as **NorthOfPotential** (my account). If `gh auth status` shows a
  different account (e.g. OleKjeldalJensen), stop and tell me.
- Git: work on branch `claude/privacy-centric-os-vgpsve`, never force-push,
  never push to `main` directly. Changes go through a PR, CI must be green, then
  merge. Don't put model names in commits/PRs.

## The project

**KratosOS** — repo `NorthOfPotential/KratosOS`. A privacy/anti-forensics
desktop OS built from Debian 13 (trixie) with live-build: KDE Plasma live
session + Calamares installer with full-disk encryption (LUKS), nftables
kill-switch firewall, WireGuard VPN mode, DNS over TLS to Quad9, Whonix
"Stealth Mode" VMs, a Qubes-style compartment tier, AppArmor/firejail/usbguard,
and **Kratos AI** (local coder: Ollama v0.40.15 + Open WebUI 0.13.0 + an
abliterated Qwen2.5-Coder, auto-sized to the hardware).

Key paths: `build.sh` (live-build config), `config/package-lists/`,
`config/hooks/live/` (0080 security updates, 0090 sectools, 0100 main hook,
0200 live boot-menu branding), `config/includes.chroot/` (files shipped in the
image, incl. `/usr/local/bin/kratos*`, `/usr/local/lib/kratos/*.sh`,
`/usr/local/libexec/kratos/kratos-calamares-{unmount,finalize}`,
`/etc/calamares/branding/kratos/`), `tests/run.sh` (full suite; needs Linux —
use WSL2 if I have it, otherwise rely on GitHub CI), `tools/kratos-validate.ps1`
(Windows + VirtualBox helper: `deps`, `getiso`, `vm`, `all`, `clean`), `docs/`.

CI (`.github/workflows/ci.yml`): `test` job on every push/PR; `build-iso` only
on manual dispatch (`gh workflow run ci.yml --ref <branch>`), which builds the
ISO in a Debian trixie container, then runs a **SUID/capability release gate**
(fails on any privileged binary not in `tests/suid-allowlist.txt`), makes an
SBOM, a signed provenance attestation, and uploads artifact `kratosos-iso`
(14-day retention). Actions are pinned by commit SHA.

## Where things stand (2026-11-08)

- `main` = `ae1067f` (PR #43 merged). Everything below is in it, built and
  passed the release gate:
  - Installer: fixed "device mounted at /calamares... could not be unmounted"
    (Calamares' hard 10 s unmount cap → our `kratos-unmount` job);
    `cryptsetup-initramfs` + `systemd-cryptsetup` shipped (encrypted installs
    were unbootable / swap never unlocked); `kratos-finalize` job (RESUME=none +
    no `resume=` → no boot stall, no hibernation, no TRIM/`discard`,
    Calamares purged from the installed system); one kernel only; KratosOS
    branding (installer, GRUB background, live menu); live session no longer
    auto-locks.
  - Network: NetworkManager `dns=none` + `systemd-resolved=false` (DHCP DNS was
    leaking alongside Quad9 DoT), `/etc/resolv.conf` forced to the stub.
  - Hardening: SUID gate actually enforced (was masked by `| tee`), no MTA at
    all (apt pin blocks exim4/postfix/sendmail/ssmtp/… + mailx clients),
    setuid stripped from pppd/ntfs-3g/spice USB helper, Ollama archive
    allowlist checker, Open WebUI on an app-private CPython 3.12 via
    hash-pinned uv, sealed root-owned/read-only.
  - A bug the last VM test caught and that is fixed in main: `resume=`
    stripping broke Calamares' single-quoted GRUB line → hardening kernel
    params were lost.
- The live boot-menu fix (logo moved to the top third, GRUB title blanked;
  the menu text used to overlap the KRATOS logo) was VM-verified on BIOS and
  UEFI and merged after this doc was written. Use the **latest successful
  `workflow_dispatch` ISO build on `main`** (`gh run list -R
  NorthOfPotential/KratosOS --workflow ci.yml --event workflow_dispatch
  --branch main --status success -L 1`); artifacts expire after 14 days, so
  dispatch a new build if it's gone.
- Already verified in an emulated QEMU VM (BIOS + UEFI, Erase disk + Encrypt,
  booted to desktop): install completes, LUKS unlocks, no resume stall,
  encrypted swap active, 0 discard, fstrim masked, no Calamares, one kernel,
  0 failed units, DNS only over TLS to Quad9, `CanHibernate`=no, firewall
  loaded, AppArmor enforcing.
- **Never tested yet:** real VirtualBox on Windows, real hardware, and
  `sudo kratos-ai setup` end to end. The emulated VM got as far as hardware
  detection (12 GB RAM, no GPU/NPU -> ~9 GB budget -> picks
  `huihui_ai/qwen2.5-coder-abliterate:7b`), then stopped at "kratos: no
  network" because the cloud sandbox gave the VM no internet. Ollama download +
  checksum, uv/CPython 3.12, Open WebUI install, services and the UI are all
  untested. Note: `kratos probe` is not a command; the probe is
  `tools/kratos-validate.sh` / `.ps1`.

## Tasks

### 1. Set up
- Check `git`, `gh` (`gh auth status` → NorthOfPotential), VirtualBox
  (`VBoxManage --version`), and whether WSL2 exists. Report what's missing and
  ask before installing anything.
- Clone or update the repo; work on branch `claude/privacy-centric-os-vgpsve`
  (restart it from `main` if its last PR is already merged).

### 2. VirtualBox test of the branch ISO (the real user path)
- Download the latest `main` ISO build's `kratosos-iso` (`gh run download
  <run-id> -R NorthOfPotential/KratosOS -n kratosos-iso -D <dir>`), verify it
  against the SHA256SUMS inside the artifact and the build log. If it expired,
  `gh workflow run ci.yml -R NorthOfPotential/KratosOS --ref main` and wait.
- Create a VM with `VBoxManage` (name it e.g. `KratosOS-Test`; Debian 64-bit,
  4–8 GB RAM, 2–4 CPUs, 25 GB+ dynamic VDI, VMSVGA, NAT network, **EFI off**
  first). Or use `tools/kratos-validate.ps1 vm` if it fits. Use
  `VBoxManage controlvm <vm> screenshotpng <file>` to see the screen and
  `VBoxManage controlvm <vm> keyboardputstring / keyboardputscancode` to type;
  ask me to click if mouse input is impractical.
- Checks, BIOS then a second VM with EFI on:
  1. Live boot menu: KratosOS splash, **no text over the logo**, legible.
  2. Live desktop; "Install KratosOS" opens Calamares with KratosOS logo,
     welcome image and slideshow; screen doesn't auto-lock while idle.
  3. Install: Erase disk + **Encrypt system** (test passphrase), user/pass of
     your choice → finishes with "All done", **no unmount error**.
  4. Reboot from disk: KratosOS GRUB background, passphrase prompt, **no
     "Gave up waiting for suspend/resume device"**, reaches login + desktop.
  5. On the installed system: `cat /proc/cmdline` (hardening params like
     `init_on_alloc=1 slab_nomerge pti=on ... apparmor=1`, and **no
     `resume=`**); `cat /etc/initramfs-tools/conf.d/resume` (RESUME=none);
     `grep -c discard /etc/fstab /etc/crypttab` (0);
     `systemctl is-enabled fstrim.timer` (masked); `cat /proc/swaps`
     (encrypted swap active); `dpkg -l calamares` (not installed);
     `ls /boot/vmlinuz-*` (one); `systemctl --failed` (0);
     `resolvectl status` (no per-link DNS, DoT to Quad9);
     `kratos status` and `sudo kratos status`; `sudo kratos bootcheck`;
     `sudo aa-status | head`; `find / -xdev -perm /6000 -type f` (no exim4,
     ssmtp, pppd, ntfs-3g); `busctl call org.freedesktop.login1
     /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate`.
  6. Kratos AI: with NAT networking, `sudo kratos-ai setup` (the network mode
     must allow it: `sudo kratos mode normal` if needed), then
     `kratos-ai status` and `kratos-ai ui` → Open WebUI on
     http://127.0.0.1:8080 answers a small coding prompt. Note RAM limits:
     give the VM 8 GB if possible; the auto-picker will choose a small model.
  7. Quick feature smoke tests that don't touch my host: `kratos help`,
     `kratos mode offline` → no network, `kratos mode normal` → network back;
     firejail/usbguard status. Skip Stealth Mode/Whonix VMs inside VirtualBox
     unless nested virtualization works.
- Save screenshots for every failure. When done, delete only the VMs and disks
  you created (ask first).

### 3. Security pass (think like an attacker)
Review the code with fresh eyes, focusing on what runs as root or crosses a
trust boundary:
- `config/includes.chroot/usr/local/bin/kratos*` and `usr/local/lib/kratos/*.sh`
  (argument parsing, temp files, symlink races, `eval`/word-splitting,
  config parsing — config is parsed as data, never sourced), polkit rules and
  helpers, the nftables kill-switch and mode switching (leaks during
  transitions, IPv6, DNS), WireGuard import validation, Stealth/Whonix and
  compartment isolation, USB/firewire/Thunderbolt exposure.
- Installer helpers (`kratos-calamares-unmount`, `kratos-calamares-finalize`):
  they run as root against the target; check quoting, failure modes, and that
  a failure never leaves an unbootable or less-hardened system.
- Kratos AI: Ollama/Open WebUI/uv pins and hashes, the archive checker, the
  services' sandboxing (loopback only, read-only code, ReadWritePaths), what
  web search exposes.
- Supply chain/CI: pinned action SHAs, base image digest, the security-update
  hook, SUID allowlist (minimal?), SBOM/attestation.
- Check for newer upstream releases and advisories (Ollama, Open WebUI, uv,
  Debian point release/kernel, the pinned GitHub Actions) and update pins with
  verified checksums.
- Read `docs/THREAT_MODEL.md`, `docs/HIGH-RESOURCE-ADVERSARY.md`,
  `docs/SUPPLY-CHAIN.md` and check the code still matches what they claim.
For each finding: severity, a concrete attack path, and the fix. Fix what's
real (with a test in `tests/`), skip hypotheticals, and tell me about anything
that needs a decision from me.

### 4. Ship
- Push fixes to the branch, open a PR to `main`, wait for CI green, merge.
- Dispatch the ISO build from `main`, confirm in the log: "all privileged
  binaries are on the allowlist", one kernel, "live boot menu branded", and
  the attestation. Give me the download link + SHA256.
- If anything from task 2 failed, fix it and re-test in VirtualBox before
  merging.

### 5. Report
Finish with a short table: each check (pass/fail + evidence), each security
finding (fixed / needs my decision), and what is still untested (e.g. real
hardware). Be honest — say "not tested" rather than assume.
