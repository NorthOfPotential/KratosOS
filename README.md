# KratosOS

A privacy-first desktop operating system that **replaces Windows**. Day to day
it works like a normal computer: KDE Plasma desktop with a taskbar and start
menu, Firefox, LibreOffice, Steam via Flatpak. Under the hood it's hardened for
privacy. One toggle turns on **Stealth Mode**: an isolated environment for a
separate online persona, with its own network path through Tor and its own
encrypted storage.

> **Read [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md).** No operating system
> can make you untraceable against every adversary. KratosOS separates your
> identities technically and removes the leaks it can. Keeping the persona
> separate in behaviour is up to you ([`docs/OPSEC.md`](docs/OPSEC.md)).

## Two roles, one machine

```
                          KratosOS (host)
        ┌───────────────────────┴────────────────────────┐
   NORMAL USE                                      STEALTH MODE (toggle)
   your identity                                   separate persona
   ─────────────                                   ─────────────────
   KDE desktop, your apps & files                  Whonix-Workstation VM
   Firefox (hardened), DNS over TLS                  │  internal network only
   random MAC, firewall, optional VPN                ▼
                                                   Whonix-Gateway VM ──► Tor ──► Internet
                                                     │  (via VPN if enabled)
                                                   stored in a separate encrypted vault
```

## Stealth Mode

Turn it on from the shield icon in the system tray, or with `sudo kratos stealth on`.

**ON** (in this order):
1. **Host lockdown:** swap off, suspend/hibernate blocked, Bluetooth and webcam off, new USB devices blocked, on-access malware scanning on, reconnect with a fresh random MAC
2. **Unlock the stealth vault:** a separate LUKS2 container. By default it is *amnesic* — a random key kept only in RAM and destroyed when Stealth turns off, so each session is rebuilt fresh and nothing persists (no passphrase to type). Set `STEALTH_VAULT_PERSIST=yes` for a persistent vault unlocked with a passphrase you choose.
3. **Isolation check:** refuses to start if the Workstation has any network path other than the Gateway, or has clipboard/file sharing/USB redirection
4. **Stealth firewall:** the Workstation's network is never forwarded or reachable from the host
5. **Start Gateway** (Tor), **then Workstation**, and open its window

**OFF** (in this order; the VM always goes first):
1. **Stop the Workstation**, escalating to forced power-off and then kill. Verified gone. *If it can't be stopped, nothing else proceeds.*
2. Stop the Gateway
3. Remove stealth networks and firewall
4. Wipe the persona: reset the Workstation to a clean overlay (default amnesic vault, or *disposable*), while **keeping the Tor Gateway and its entry-guard state** so toggling Stealth doesn't churn your guards
5. Shred VM logs, drop caches, lock the vault (the in-RAM key is kept for the boot so the next toggle reopens the same Gateway; a reboot or `kratos panic` discards it)
6. Undo the host lockdown

The VMs are transient: their definitions live **inside** the vault. With
Stealth Mode off, the system holds no record of the running persona; the vault
is an encrypted file (and in the default amnesic mode its key is gone from RAM).
Note: on an installed system with Whonix caching enabled (the default), a
verified Whonix image is also kept under `/var/lib/kratos/whonix-cache/` — inside
the LUKS-encrypted root, so encrypted at rest, but it is a persistent on-disk
artifact that reveals Whonix use. Set `STEALTH_WHONIX_CACHE=no` to keep nothing.

## Everyday privacy (always on)

| | |
|---|---|
| Firewall | Nothing can connect in. LAN announcements (mDNS, LLMNR, SSDP, NetBIOS) blocked. SMB never goes to the internet. |
| DNS | Normal mode: the system resolver uses DNS over TLS to Quad9 and plain port-53 DNS is blocked (an app doing its own DoH over 443 is not forced through it). VPN mode: DNS goes to the VPN's resolver, plaintext *inside* the WireGuard tunnel (protected by the tunnel, not DoT). |
| Network identity | Random MAC per connection, hostname not sent via DHCP, IPv6 off, no connectivity-check pings |
| VPN | `kratos vpn-import` a WireGuard config (e.g. Proton VPN). Kill switch tested: nothing leaves outside the tunnel. |
| Browser | Firefox with telemetry off, strict tracking protection, HTTPS-only, uBlock Origin, no WebRTC IP leak |
| System | systemd journal is volatile (RAM); some services (e.g. auditd) still keep their own logs on the encrypted root — not a blanket "no logs on disk". No recent-files history, AppArmor, Firejail sandboxes, USBGuard, hardened kernel options |
| Tools | `kratos scrub` (metadata), `kratos shred`, `kratos scan` (ClamAV + rkhunter), panic button |

## Migrating from Windows 11

1. **On Windows**, run [`migration/Export-WindowsData.ps1`](migration/Export-WindowsData.ps1) with an external drive:
   ```powershell
   powershell -ExecutionPolicy Bypass -File Export-WindowsData.ps1 -Destination E:\
   ```
   It copies your files, bookmarks and software list, and writes a SHA-256 manifest and a checklist. Make a second copy.
2. **Install KratosOS** from the USB stick. In the Calamares installer, choose the **encrypted** install option (select "Encrypt system" / enter a passphrase) — KratosOS ships the upstream Calamares encryption option but does not yet force it, so this is a manual choice you must make.
3. **Import:** `kratos migrate --from /media/$USER/<drive>/KratosExport`. It verifies every file against the manifest and suggests Linux replacements for your Windows software.

Full guide: [`docs/MIGRATION.md`](docs/MIGRATION.md).

## Build

**No Linux machine?** Push this repo to GitHub and run the **CI** workflow from
the Actions tab; download the built ISO from its Artifacts. Or build locally in
WSL2. Full steps, plus how to try it in VirtualBox or from a USB stick without
installing: [`docs/BUILD-ON-WINDOWS.md`](docs/BUILD-ON-WINDOWS.md). After booting,
work through [`docs/FIRST-BOOT.md`](docs/FIRST-BOOT.md).

On Debian 13 / Ubuntu 24.04+:

```bash
sudo apt install live-build
sudo ./build.sh            # → kratosos-amd64.hybrid.iso
```

## Test

```bash
sudo tests/run.sh
```

Runs shellcheck, nftables syntax checks, the Whonix isolation-check tests, the
Stealth Mode ordering tests (simulated libvirt), migration tests,
**functional firewall tests** in a throwaway network namespace (watching the
interface to confirm which packets actually leave in each mode), and a
**simulated attack** (`tests/attack_isolation.sh`) in which an unprivileged
"malware" user tries and fails to reach the persona's screen, disks, secrets
and config.

## Layout

```
build.sh                         builds the installer ISO (live-build + Calamares)
migration/Export-WindowsData.ps1 run on Windows before switching
config/package-lists/            what's installed
config/hooks/live/               build-time hardening
config/includes.chroot/
  etc/kratos/kratos.conf         settings (Stealth Mode options)
  etc/kratos/modes/*.nft         firewall: normal, vpn, offline
  etc/kratos/stealth.nft         firewall additions while Stealth Mode is on
  usr/local/bin/kratos           command-line tool
  usr/local/bin/kratos-tray      tray icon with the Stealth Mode toggle
  usr/local/lib/kratos/          implementation (stealth.sh, net.sh, ...)
docs/                            threat model, OpSec, architecture, migration,
                                 compartmentalization, correlation-resistance, Qubes
qubes/                           KratosOS-on-Qubes: Salt formula, qrexec policy, dom0 driver
workstation/nym/                 Nym mixnet client + fail-closed firewall (installs in the persona VM)
tests/                           test suite
```

## Status

v0.2, early. The firewall, the isolation check, the shutdown ordering and the
migration import are tested. The full ISO build and Stealth Mode on real
hardware have **not** been tested end to end yet. See [`docs/ROADMAP.md`](docs/ROADMAP.md).
