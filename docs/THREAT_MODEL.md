# Threat Model

## The goal, stated precisely

KratosOS does **not** promise that nobody can ever trace you. No system can.
The goal is:

> Keep the computer useful as an ordinary computer, and keep a separate persona
> technically and operationally isolated from it, so that a mistake or
> compromise in one doesn't automatically expose the other.

That takes two separate controls. KratosOS can enforce the first. The second
depends on you.

| Control | Question it answers | Provided by |
|---|---|---|
| **Network anonymity** | Can the destination see my real IP? | Whonix Gateway + Tor (+ optional VPN) |
| **Identity separation** | Can the activity be linked to the real me? | Separate vault, separate VMs, **your behaviour** |

Tor with your personal accounts = network protection without identity separation.
Tor with a separate persona and separate accounts = both. Stealth Mode is built for the second.

## What changes compared to Windows + VirtualBox + Whonix

| Before | KratosOS |
|---|---|
| Windows (telemetry, large attack surface) is the host under the persona | A minimal, hardened Linux host with no telemetry |
| VirtualBox with Guest Additions, shared clipboard possible | KVM; clipboard, file transfer, USB redirection and shared folders removed and **checked on every start** |
| Workstation network depends on VirtualBox settings staying correct | Kratos refuses to start a Workstation with any path except the Gateway |
| VM files, logs and configs on the normal disk | VMs live inside a separate encrypted vault; definitions are transient; logs shredded at shutdown |
| Proton VPN app kill switch you have to trust | nftables kill switch, covered by `tests/run.sh`; Gateway traffic can only leave through the tunnel |
| Turning things off in the wrong order is possible | Off = Workstation first, verified; nothing else proceeds if it won't stop |

## What it still does NOT protect against

**The host is still underneath the persona.** KratosOS is a much smaller, cleaner
host than Windows, but if the host is compromised, the attacker can see the
Workstation's window and keystrokes. Qubes OS reduces this further with a
Xen hypervisor and an isolated GUI layer. KratosOS trades some of that for being
a normal everyday computer. Keep the host updated, and don't install sketchy
software on it.

| Threat | Why it remains |
|---|---|
| Host compromise | See above. Mitigations: hardening, AppArmor, Firejail, updates, minimal host software. |
| Hypervisor (KVM/QEMU) escape | Rare but possible. Mitigation: no integration devices, updates. |
| Global passive adversary / traffic correlation | A known limit of low-latency anonymity networks like Tor. No local setup fixes it. |
| Browser 0-days inside the Workstation | Can take over the Workstation. Mitigation: Tor Browser "Safest" level, disposable mode. |
| Hardware/firmware (Intel ME, AMD PSP, BIOS) | Below the OS. Use trusted hardware. |
| Physical access while running | RAM holds keys. Mitigation: panic button, lock screen, power off. Sleep is blocked in Stealth Mode. |
| Coercion | You can be forced to give up passphrases. |
| **Your behaviour** | See below. This is the most common way people are identified. |

## Vulnerability matrix

| Vulnerability | What can happen | Mitigation in KratosOS | Your part |
|---|---|---|---|
| Host compromise | Host observes the VMs | Hardened minimal host, no telemetry | Keep updated, install little |
| VM escape | Guest attacks host | KVM, no integration devices | Updates |
| Host artifacts | Evidence VMs existed | Encrypted vault, transient VMs, logs shredded, RAM-only journal, swap off | Full disk encryption at install |
| VPN failure | Gateway reaches Tor outside VPN | Kill switch at firewall level; optional `STEALTH_REQUIRE_VPN` | Test the kill switch once |
| Network misconfiguration | Workstation gets a direct route | Isolation check on setup and every start; firewall never forwards the internal network | Don't edit VM definitions by hand |
| Clipboard / file leakage | Data crosses the identity boundary | No SPICE agent, clipboard and file transfer disabled and verified | Don't retype persona data into the host |
| Identity correlation | Persona linked to you | — | Persona rules ([OPSEC.md](OPSEC.md)) |
| Translation / AI tools | Persona text stored in your personal accounts | — | Translate inside the Workstation, logged out |
| Phone verification | Account tied to your SIM | — | Never use your number for the persona |
| Timing patterns | Persona active when you are | — | Vary your sessions |
| Metadata in files | EXIF/GPS/author leaks | `kratos scrub` | Scrub everything that leaves |
| Backups | Persona and personal data found together | Vault is a separate encrypted file | Store persona backups separately |
| Physical access | Live machine compromised | Panic button, sleep blocked in Stealth Mode | Lock/power off |
| Human error | Wrong environment used | Clear tray state, separate windows | Discipline |

## Network mode trade-offs (Stealth Mode traffic)

| Host mode | ISP sees | VPN sees | Destination sees |
|---|---|---|---|
| `normal` | You use Tor | — | Tor exit IP |
| `vpn` | You use a VPN | You use Tor | Tor exit IP |

VPN-before-Tor hides Tor use from your ISP but makes the VPN a party that knows
you use Tor. Pay for it in a way that doesn't identify you if that matters.

## Antivirus expectations

KratosOS ships ClamAV (on-access in Stealth Mode), rkhunter, AppArmor, Firejail
and USBGuard. ClamAV's detection is **not** comparable to Bitdefender's on
Windows, but Linux malware is a much smaller threat. The real protection is the
architecture: a separate VM for risky activity, no exposed services, sandboxing,
and a disposable Workstation option.
