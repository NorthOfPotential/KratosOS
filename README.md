# KratosOS

A privacy-first, amnesic Linux distribution built on Debian. All traffic is forced
through Tor (or a VPN, or VPN→Tor) behind a fail-closed firewall, sessions leave no
trace by default, and the system ships with tools for OpSec, disposable VMs and
migrating your files off Windows 11.

> **Read [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md) before trusting this with
> anything that matters.** No operating system can make you untraceable against
> every adversary. KratosOS removes the *technical* leaks it can and makes the rest
> expensive. Most real-world deanonymization comes from user behaviour, which no OS
> can fix.

## Features

| Area | What KratosOS does |
|---|---|
| **Network anonymity** | Every TCP connection and DNS lookup is transparently routed through Tor. Anything that can't go through Tor (UDP, ICMP, IPv6, LAN) is dropped. |
| **Kill switch** | The nftables firewall is fail-closed: if Tor or the VPN goes down, nothing leaks. It loads before any network interface comes up. |
| **Network modes** | `tor` (default), `vpn` (WireGuard), `vpn-tor` (you → VPN → Tor, so your ISP sees only the VPN), `offline`. |
| **Identifier scrubbing** | Random MAC address on every connection, generic hostname, UTC timezone, no IPv6, TCP timestamps off, stable but unremarkable fingerprint. |
| **Amnesia** | Boots live from USB and runs in RAM. RAM is cleared on free (`init_on_free=1`). Optional LUKS2-encrypted persistence. |
| **Defense** | AppArmor (enforcing), Firejail sandboxes, ClamAV with on-access scanning, rkhunter, USBGuard, a hardened kernel command line and sysctls, and a blacklist for unneeded kernel modules (FireWire/Thunderbolt DMA, rare protocols, cameras optional). |
| **Disposable VMs** | `kratos vm` starts a throwaway QEMU/KVM VM whose disk writes are discarded and whose network goes through the host's Tor. |
| **OpSec toolkit** | Leak tests, Tor circuit renewal, metadata stripping, secure deletion, panic button, MAC/hostname checks. |
| **Windows 11 migration** | `kratos migrate` finds your Windows partition (including BitLocker), copies your user files, skips telemetry and caches, strips metadata, and writes to encrypted storage. |

## Quick start

### Build the ISO (on Debian 13 / Ubuntu 24.04+)

```bash
sudo apt install live-build
sudo ./build.sh
# → kratosos-amd64.hybrid.iso
```

Write it to a USB stick (this erases the stick):

```bash
sudo dd if=kratosos-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### Use it

```bash
kratos status              # current mode, Tor state, firewall, MAC
kratos check               # full leak test
kratos mode vpn-tor        # switch network mode (fail-closed during switch)
kratos newnym              # new Tor circuits / new exit IP
kratos vm debian.iso       # disposable VM, networked via Tor
kratos scrub photo.jpg     # strip metadata
kratos shred secret.txt    # overwrite and delete
kratos migrate             # copy files from a Windows 11 disk
kratos panic               # kill network, wipe clipboard and caches, power off
```

Run `kratos help` for everything.

## Layout

```
build.sh                      live-build wrapper that produces the ISO
config/package-lists/         packages installed into the image
config/hooks/live/            hardening applied at image build time
config/includes.chroot/       files copied into the image
  etc/kratos/modes/           nftables rulesets for each network mode
  etc/tor/torrc               Tor with TransPort/DNSPort and stream isolation
  etc/sysctl.d/               kernel/network hardening
  usr/local/bin/kratos        the KratosOS command-line tool
  usr/local/lib/kratos/       kratos subcommands
docs/                         threat model, architecture, OpSec guide
tests/                        static checks (shellcheck, nft syntax)
```

## Status

This is an early foundation (v0.1). The parts that matter most for anonymity, the
firewall, Tor configuration and leak checks, are deliberately small enough to audit.
See [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Relationship to existing projects

KratosOS borrows design ideas from [Tails](https://tails.net) (amnesia, Tor-only),
[Whonix](https://www.whonix.org) (fail-closed transparent proxying) and
[Qubes OS](https://www.qubes-os.org) (compartmentalization). If your life or liberty
depends on anonymity **today**, use Tails or Qubes+Whonix. They have years of audits
behind them, and this project doesn't yet.
