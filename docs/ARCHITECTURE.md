# Architecture

## Components

| Component | File | Role |
|---|---|---|
| `kratos` | `usr/local/bin/kratos` | CLI entry point |
| `kratos-tray` | `usr/local/bin/kratos-tray` | Tray icon: Stealth toggle, network mode, status, panic |
| Network modes | `etc/kratos/modes/{normal,vpn,offline}.nft` | Host firewall, one table `inet kratos`, replaced atomically |
| Stealth firewall | `etc/kratos/stealth.nft` | Table `inet kratos_stealth`, present only in Stealth Mode |
| Stealth controller | `usr/local/lib/kratos/stealth.sh` | Vault, host lockdown, VM lifecycle, ordering |
| Isolation check | `usr/local/lib/kratos/harden-whonix.py` | Rewrites and validates the Whonix libvirt XML |
| Services | `kratos-firewall` (before network), `kratos-mode` (VPN after network), `kratos-stealth-shutdown` (clean off at shutdown) |

## Stealth Mode networking

```
 Workstation (kx-ws) ──kx-int──► Gateway (kx-gw) ──kx-ext──► host NAT ──► [wg tunnel] ──► Internet
        isolated bridge,                          NAT bridge
        host has no IP on it                      (libvirt)
```

Firewall rules, evaluated in priority order:

1. `kratos_stealth` forward (priority filter-10)
   - anything in or out of `kx-int` → **drop** (final)
   - `kx-ext` → outside → mark `0x4b52`
2. `kratos` forward (priority filter, the active mode)
   - `normal`: accept marked packets
   - `vpn`: accept marked packets **only** if the output interface is the WireGuard tunnel
   - `offline`: accept nothing
3. `kratos_stealth` input: `kx-ext`/`kx-int` → host services **drop**

So the VPN kill switch also covers the Gateway, and switching network modes
while Stealth Mode is on needs no extra steps.

## Stealth vault

`/var/lib/kratos/stealth.vault`: a LUKS2 (argon2id) file holding:

```
gateway.qcow2            Whonix-Gateway disk
workstation-base.qcow2   clean Workstation image
workstation.qcow2        overlay with the persona's changes (thrown away in disposable mode)
libvirt/kx-*.xml         hardened, validated VM and network definitions
```

The vault mount (`/var/lib/kratos/vault`) is `0700 root:root`, but the VMs run
as `libvirt-qemu`, so QEMU is granted an **execute-only POSIX ACL**
(`u:libvirt-qemu:x`) on that directory: it can traverse to the disk file libvirt
relabels to it, but cannot list the directory or read any file. Everyone else
is fully excluded, and each disk's access is still governed by libvirt's per-VM
dynamic ownership + sVirt label (so the Gateway cannot open the Workstation's
disk). This needs validating on a real libvirt host — the test suite proves the
ACL shape, not the live QEMU open.

VMs and networks are created with `virsh create` / `net-create` (transient), so
`/etc/libvirt` never holds them. VM displays are SPICE over a UNIX socket in
`/run/kratos/spice/`, which is `root:kstealth` (mode 0710) — the dedicated
`kstealth` persona-seat user, NOT the ordinary desktop user, who has no access
at all. Each socket is handed to `kstealth` race-free (inode-pinned, no symlink
follow). That gives the persona seat screen and input only: it has no libvirt
rights and can't reconfigure the VMs.

## Ordering guarantees (tested in `tests/test_stealth_order.sh`)

- Off: Workstation is verified gone → Gateway → firewall → wipe → vault → host.
- If the Workstation can't be stopped: Gateway, vault and host lockdown are left as they are, and the command fails loudly.
- If any step of *on* fails, everything already done is rolled back with the same off sequence.
- At reboot or poweroff, `kratos-stealth-shutdown.service` runs the off sequence before libvirt stops.

## Boot

1. `kratos-firewall.service` (before `network-pre.target`) loads `offline`, then the saved mode (`normal`). VPN mode stays offline until…
2. `kratos-mode.service` (after `network-online.target`) brings up WireGuard and loads `vpn`.
