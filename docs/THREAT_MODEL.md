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

## Facing a state-level adversary

If your threat model includes an agency like the FBI specifically targeting
you, read [`HIGH-RESOURCE-ADVERSARY.md`](HIGH-RESOURCE-ADVERSARY.md). Short
version: no OS can guarantee anonymity against that, KratosOS included; use the
most-audited tools (Tails, Qubes+Whonix) and perfect behavioural discipline, and
treat the software as cost-raising, not invincibility.

## Isolation between your normal session and the persona

Malware running as your **normal desktop user** is the realistic everyday
threat (a bad download, a malicious document). KratosOS contains it:

- The persona's display runs as a dedicated `kstealth` user in its **own login
  session on its own VT** (a `cage` kiosk). Your normal session and the persona
  never share a compositor, clipboard or input path.
- The display socket is `root:kstealth` `0660`, so only `kstealth` and root can
  watch the screen or inject keystrokes. Your normal user is "other": no access.
- The vault (the persona's whole filesystem) is `0700 root` even while unlocked;
  the VM disks are `0600 root`.
- `hidepid=2` hides the QEMU processes and the `kstealth` session from your
  normal user entirely, so even the socket paths don't leak via `ps`.
- Config, VM definitions and the `kratos` tool are root-owned, so normal-user
  malware can't weaken the next Stealth session.

`tests/attack_isolation.sh` plays this attacker: as an unprivileged user it
tries to read the vault and VM disks, open the display socket, read the
passphrase/undo files, and tamper with the VM definitions, config and tool.
Every attempt must fail, and the suite is self-checked (it includes a positive
control proving `kstealth` *can* use the display, and we verified it flips to
FAIL when a permission is deliberately weakened).

## What it still does NOT protect against

**A root compromise of the host still wins.** The persona runs on this host, so
malware that gains **root** can see the Workstation's window and keystrokes. The
isolation above stops your *normal user* from reaching the persona; it does not
stop root. Qubes OS reduces even the root case with a Xen hypervisor and an
isolated GUI layer. KratosOS trades that for being a normal everyday computer.
Keep the host updated, and don't install sketchy
software on it.

| Threat | Why it remains |
|---|---|
| Host compromise | See above. Mitigations: hardening, AppArmor, Firejail, updates, minimal host software. |
| Hypervisor (KVM/QEMU) escape | Rare but possible. Mitigation: no integration devices, updates. |
| Global passive adversary / traffic correlation | Still unsolved for low-latency Tor. KratosOS adds opt-in local-link shaping/jitter/decoy (local observers only) and an experimental Nym **mixnet** mode for real unobservability — see CORRELATION-RESISTANCE.md. Blends by default so it adds no fingerprint. |
| Browser 0-days inside the Workstation | Can take over the Workstation. Mitigation: Tor Browser "Safest" level, disposable mode. |
| Hardware/firmware (Intel ME, AMD PSP, BIOS) | Below the OS. Use trusted hardware. |
| Physical access while running | RAM holds keys. Mitigation: panic button, lock screen, power off. Sleep is blocked in Stealth Mode. |
| Coercion | You can be forced to give up passphrases. |
| **Your behaviour** | See below. This is the most common way people are identified. |

## Vulnerability matrix

| Vulnerability | What can happen | Mitigation in KratosOS | Your part |
|---|---|---|---|
| Normal-user malware observes the persona | Watch screen, inject keys, read vault | Dedicated kstealth user + own session, `hidepid`, root-owned vault/config (tested by `attack_isolation.sh`) | Don't run untrusted code as root |
| Root compromise of the host | Full access, incl. the VMs | sVirt per-VM confinement shrinks VM-breakout blast radius (COMPARTMENTALIZATION.md); not eliminated — needs Qubes+Whonix | Keep updated, install little |
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

## Known limitations called out by review (honest notes)

- **One polkit action covers the whole `kratos` tool, and it uses
  `auth_admin_keep`.** `org.kratos.manage` authorizes `/usr/local/bin/kratos`
  regardless of subcommand with `<allow_active>auth_admin_keep</allow_active>`,
  so one admin authentication is cached and a later low-risk action (e.g. a
  network-mode change) shares that retained authorization with higher-risk paths
  in the same binary (stealth, migrate, shred, scan). This is a real weakness:
  malware in the active desktop session could ride the cached authorization to
  invoke a higher-risk subcommand. Splitting the high-risk operations into
  separate, narrowly-scoped privileged helpers with their own polkit actions
  (and not retaining authorization for destructive arbitrary-path operations) is
  planned and tracked; until then, treat an authenticated session as able to run
  any `kratos` subcommand.
- **`kratos shred` / Stealth log wiping is best-effort.** `shred` cannot
  guarantee physical overwrite on SSDs, flash (FTL), or copy-on-write/snapshotted
  storage, and `echo 3 > drop_caches` drops caches — it is not memory
  sanitisation. The real confidentiality boundary is the LUKS2 vault (locked =
  data at rest encrypted) and `init_on_free=1`; sensitive VM logs belong on
  tmpfs so there is nothing persistent to overwrite.
- **bootcheck is change-detection, not trusted boot.** It records a baseline and
  flags changes, but the baseline is writable by the same root compromise it is
  meant to detect. Real assurance needs Secure/measured boot, signed boot chain,
  TPM-sealed measurements and anti-evil-maid — out of scope for the current
  baseline.
- **sVirt confinement is asserted in XML, not yet verified live.** The Whonix
  hardener requires a dynamic relabeling `<seclabel>` (per-VM AppArmor/SELinux)
  and refuses VMs without it, but that proves the XML *requests* confinement.
  Verifying the effective label on the running QEMU process
  (`ps -eZ`/`aa-status`) is a live-system integration check.
