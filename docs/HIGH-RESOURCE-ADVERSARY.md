# Facing a High-Resource Adversary

> This is an honest assessment, not reassurance. If a state-level agency (FBI,
> and more so the NSA-tier signals agencies) is specifically targeting **you**,
> **no operating system — not KratosOS, not Tails, not Qubes+Whonix — can
> guarantee you stay anonymous.** What good tooling does is raise the cost,
> shrink the mistakes available to you, and force the adversary toward
> expensive, targeted, legally visible methods instead of cheap bulk ones.
> The deciding factor is almost always **your behaviour and operational
> discipline over time**, not the software.

## How such an adversary actually works

They rarely "break Tor." They go around it. In real cases (the ones that became
public), people were caught by:

- **Operational mistakes** — reusing a username, email, Bitcoin address, PGP key, or photo across their real and anonymous identities. (This is how most dark-web cases were made.)
- **Correlation over time** — matching when the persona is active against when a suspect's home internet is active, or against known timezone/sleep patterns.
- **Targeted malware** — a browser or document exploit delivered to the persona, which then tries to phone home *outside* the anonymity layer.
- **Legal compulsion** — subpoenas to the services the persona used, the VPN provider, the ISP; device seizure; compelled passwords.
- **The physical world** — surveillance, informants, controlled buys, matching a shipment to an address.

Notice that only one of those (malware) is primarily a software-hardening
problem. The rest are behaviour, infrastructure, and law.

## Where KratosOS helps against them

| Their technique | What KratosOS does | Residual risk |
|---|---|---|
| IP / location via the network | Everything in Stealth Mode is forced through Tor; fail-closed firewall; no IPv6; optional VPN-before-Tor hides Tor use from the ISP | Global traffic correlation (below) |
| App that ignores the proxy, or a leak | Transparent proxying in the Gateway + default-drop; the Workstation has no route except the Gateway, enforced and tested | A root exploit in the Gateway |
| Normal-user malware pivoting to the persona | Separate `kstealth` user/session, `hidepid`, root-only vault — see THREAT_MODEL | A **root** exploit on the host |
| Forensics after seizure (powered off) | LUKS2/argon2id full-disk encryption; separate encrypted vault; RAM-only logs; `init_on_free` zeroes freed RAM | A weak passphrase; coercion; a running machine |
| Device fingerprinting on networks | Randomized MAC, generic hostname, no mDNS/LLMNR/connectivity pings | Hardware serial numbers visible to a present observer |
| DMA / peripheral attacks | IOMMU on, FireWire blacklisted, USBGuard blocks new devices in Stealth Mode | Pre-boot/firmware implants |

## Where it does NOT help — and what actually mitigates each

### 1. Global traffic correlation
An adversary who can watch traffic *entering* Tor (your guard/ISP) **and**
*leaving* it (near the destination) can statistically correlate the timing and
volume, with no need to break any crypto. Tor's own design documents say this.
- **Mitigation:** there is no software fix on your machine. Reduce exposure:
  long-lived guard relays (Tor default), don't run high-volume transfers, vary
  timing, and accept that against a true global passive adversary low-latency
  anonymity is not guaranteed. If this is your threat model, reconsider whether
  the activity should happen online at all.

### 2. A root / hypervisor exploit on the host
KratosOS is one kernel. A sufficiently good exploit chain delivered to the host
(or escaping the Gateway VM into the host) sees everything.
- **Mitigation that actually changes this:** **Qubes OS + Whonix.** Qubes uses a
  Xen hypervisor and puts the Tor gateway and each activity in separate VMs, so
  one compromise doesn't take the whole machine. For a nation-state threat model,
  Qubes+Whonix on a [certified-compatible](https://www.qubes-os.org/hcl/) laptop
  is the stronger choice, and KratosOS says so plainly. KratosOS's trade is
  usability (one normal desktop) for a smaller isolation boundary.
- **On KratosOS:** keep the attack surface tiny — use the disposable Workstation,
  Tor Browser at "Safest", open nothing untrusted on the host, install nothing
  extra on the host, and apply updates the day they ship.

### 3. Firmware / hardware implants, and the machine while it's on
Intel ME / AMD PSP, a malicious BIOS, a hardware keylogger, or a cold-boot/DMA
attack on a *running, unlocked* machine are all below the OS.
- **Mitigation:** buy hardware anonymously and keep physical control of it; use
  [Heads](https://osresearch.net)/Coreboot and **Anti Evil Maid** on supported
  boards to detect boot tampering; power **off** (not sleep) when leaving the
  machine — KratosOS blocks sleep in Stealth Mode and zeroes freed RAM, but a
  powered-on unlocked machine is always vulnerable to someone with physical
  access.

### 4. Legal compulsion and the services you touch
Subpoenas don't care about your OS. The VPN provider, the sites the persona used,
an exchange, a shipper — any of them can be compelled, and many log more than
they admit.
- **Mitigation:** minimise who holds data about the persona at all. Prefer Tor
  over a VPN (no single provider sees you); if you use a VPN, pay anonymously
  (cash/Monero) and assume it keeps logs. Assume every service the persona
  touches will eventually be asked about it.

### 5. Compelled passwords / coercion
In several jurisdictions you can be legally ordered to unlock a device, or
pressured to.
- **Mitigation:** this is legal/physical, not technical. A **hidden/deniable**
  volume has real limitations and can make things worse if its existence is
  suspected; think carefully before relying on it. The safest secret is one that
  was never created or stored.

### 6. Stylometry and behaviour
How you write, when you're active, what you reveal, how you make decisions — these
identify people across identities even with perfect network anonymity.
- **Mitigation:** strict identity separation, varied timing, and the habits in
  [OPSEC.md](OPSEC.md). This is the single highest-leverage thing you control.

## Hardening roadmap for this threat model

Cheap wins already in KratosOS: forced Tor, fail-closed firewall, encrypted
amnesic design, user/session isolation, RAM zeroing, IOMMU, USBGuard.

Worth adding (tracked in [ROADMAP.md](ROADMAP.md)), roughly in order of value:

1. **Reproducible, signed builds** so you can verify the ISO wasn't tampered with in transit — important precisely against a resourceful adversary.
2. **Tor bridges (obfs4 / Snowflake) by default-available** so using Tor is itself concealable (config stubs already ship in the Gateway).
3. **A Qubes/Whonix split option** — run the Gateway and Workstation as fully separate VMs with no shared host GUI, closing the "one host kernel" gap.
4. **Secure Boot + a measured-boot / Anti-Evil-Maid path** on supported hardware.
5. **An independent security audit.** Nothing here has been audited. Until it is, for a life-or-liberty threat model use Tails or Qubes+Whonix, which have years of review behind them.

## The honest bottom line

Against an ordinary adversary, and against bulk surveillance, KratosOS done right
is strong. Against a well-resourced agency that is *specifically targeting you*,
assume they can win if you give them one mistake or one targeted exploit, and act
accordingly: minimise what you do, minimise who knows, keep perfect identity
hygiene, keep physical control of trusted hardware, and prefer the most-audited
tools (Tails, Qubes+Whonix) over this young project. KratosOS raises the cost; it
does not make you invincible, and anyone who tells you an OS can is wrong.
