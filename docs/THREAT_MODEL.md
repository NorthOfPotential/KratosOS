# KratosOS Threat Model

## The honest headline

**No system can guarantee that "no matter how many resources the opponent has,
they cannot track it back to you."** A powerful enough adversary has options that
no operating system can defend against. KratosOS aims to:

1. remove every *technical* leak that the OS can control,
2. make correlation attacks expensive enough that only the most powerful adversaries can try them,
3. make the remaining risk (your behaviour) visible and easier to manage.

## What KratosOS defends against

| Adversary / threat | Defence |
|---|---|
| Websites and trackers learning your IP | All traffic goes through Tor. The exit IP is shared by many users. |
| Your ISP, Wi-Fi operator or local network seeing what you do | Tor encrypts traffic to the guard. In `vpn-tor` mode the ISP sees only the VPN. |
| DNS leaks | DNS is redirected to Tor's DNSPort. Every other DNS query is dropped. |
| WebRTC / UDP / IPv6 leaks | IPv6 is disabled. UDP other than Tor DNS is dropped. The firewall default is DROP. |
| Apps that ignore proxy settings | Transparent proxying at the firewall level, so apps can't bypass it. |
| Tor or VPN crashing | Fail-closed firewall: no connection, no leak. |
| Hardware identifiers on the network (MAC) | MAC is randomized per connection. Hostname is generic. |
| Forensic analysis of the machine afterwards | Live/amnesic by default. RAM is cleared on free. Persistence is LUKS2-encrypted. |
| Metadata in files you publish (EXIF GPS, author names) | `kratos scrub` (mat2). |
| Common malware | AppArmor, Firejail, ClamAV on-access scanning, no listening services. |
| Physical DMA attacks via FireWire/Thunderbolt | Modules blacklisted. |
| Cross-site correlation of your activity | Tor stream isolation (each app/destination gets its own circuit). `kratos newnym` gives you a fresh identity. |

## What KratosOS does **not** defend against

| Threat | Why |
|---|---|
| **Global passive adversary** (someone who can watch both where traffic enters and where it leaves the Tor network) | Traffic-timing correlation is a known limitation of low-latency anonymity networks, including Tor. No OS can fix this. |
| **You identifying yourself** | Logging into personal accounts, reusing usernames, writing style (stylometry), mentioning personal details, or using the same session for both identities. **This is the #1 cause of real-world deanonymization.** |
| **Compromised hardware or firmware** | Intel ME/AMD PSP, malicious BIOS, hardware keyloggers. Use trusted hardware. |
| **Browser exploits / 0-days** | Sandboxing reduces the impact, but a sufficiently good exploit chain can escape. Qubes-style VM isolation helps more than anything else here. |
| **Malicious VPN provider** | In `vpn` mode, the VPN sees everything Tor would have hidden. Prefer `tor` or `vpn-tor`. |
| **Physical surveillance** | Cameras, informants, someone looking over your shoulder. |
| **Payment trails** | Buying a VPN with your card links it to you. |
| **Coercion** | You can be forced to reveal passwords. |
| **Being targeted while the machine is running** | Cold-boot attacks on a powered-on machine. Use `kratos panic`. |

## Antivirus expectations

KratosOS ships ClamAV, rkhunter, AppArmor, Firejail and USBGuard. Together they
provide strong *containment*. ClamAV's detection rate is **not** on par with
commercial products such as Bitdefender for Windows malware, though Linux malware
is a much smaller threat surface. The main defence is architecture (amnesia,
sandboxing, no exposed services, disposable VMs for risky files), not signatures.

## Network mode trade-offs

| Mode | ISP sees | Destination sees | Trust placed in |
|---|---|---|---|
| `tor` | That you use Tor | A Tor exit IP | Tor network (distributed) |
| `vpn-tor` | That you use a VPN | A Tor exit IP | VPN (sees you use Tor) + Tor network |
| `vpn` | That you use a VPN | The VPN IP | **VPN provider completely** |
| `offline` | Nothing | Nothing | — |

Tor bridges (obfs4 / Snowflake) can hide the fact that you use Tor from your ISP
without trusting a VPN provider. Set them in `/etc/tor/torrc`.
