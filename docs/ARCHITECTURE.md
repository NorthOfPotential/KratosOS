# Architecture

```
 ┌────────────────────────── KratosOS host (live, in RAM) ──────────────────────────┐
 │                                                                                  │
 │  Apps ──┐   Tor Browser ──┐   Disposable VM (QEMU, user-mode net) ──┐            │
 │         │                 │                                         │            │
 │         ▼                 ▼                                         ▼            │
 │   ┌──────────────── nftables (table inet kratos) ──────────────────────┐         │
 │   │ output nat:  TCP → 127.0.0.1:9040 (Tor TransPort)                   │        │
 │   │              DNS → 127.0.0.1:5353 (Tor DNSPort)                     │        │
 │   │ output filter: policy DROP; accept only uid debian-tor (+ wg in VPN)│        │
 │   │ input: policy DROP (no listening services)                          │        │
 │   └─────────────────────────────────────────────────────────────────────┘        │
 │                       │                                                          │
 │                   tor daemon ───────► (wg0 in vpn-tor mode) ──► NIC (random MAC) │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

## Boot order

1. Kernel boots with hardened parameters (see `config/bootloaders` / `build.sh`).
2. `kratos-firewall.service` loads the ruleset for the saved mode **before**
   `network-pre.target`, so no interface is ever up without the firewall.
3. NetworkManager connects with a random MAC.
4. Tor starts. Only the `debian-tor` user may reach the internet.

## Mode switching

`kratos mode <m>` first loads the `offline` ruleset (drops everything), then
reconfigures Tor/WireGuard, then loads the new ruleset. Nothing leaks during
the transition.

## Why transparent proxying *and* a drop policy?

Transparent proxying means apps that ignore proxy settings still go through Tor.
The drop policy means anything Tor can't carry (UDP, ICMP, raw sockets) is blocked
instead of going out in the clear. Either one alone leaks.

## Disposable VMs

QEMU runs with `-snapshot` (disk writes go to a temporary overlay that is discarded)
and `-netdev user` (SLIRP). SLIRP turns guest traffic into ordinary host sockets
owned by the QEMU process, so the host firewall sends it through Tor. The guest
can't reach the host or the LAN, and it can't leak around Tor.
