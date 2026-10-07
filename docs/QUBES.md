# KratosOS on Qubes (the strongest isolation tier)

This is the honest answer to "fix the root/hypervisor exploit like Qubes": you
run **Qubes OS** as the base — its Xen hypervisor and dom0 are the isolation
boundary — and layer the KratosOS workflow on top. A compromise of your everyday
qube, or even a VM breakout, does not hand over the persona, because they are
separate Xen domains, not processes under one shared Linux kernel.

KratosOS's own KVM Stealth Mode remains the single-machine, more-usable tier.
This Qubes tier is for when a *targeted host exploit* is in your threat model.

## What's in `qubes/`

| File | Role |
|---|---|
| `qubes/salt/kratos.sls`, `kratos.top` | Salt formula (run in dom0) that builds the qubes: `personal`, `vault` (no net), `kratos-ws` (disposable template → `sys-whonix`), tagged `kratos-persona` |
| `qubes/policy/30-kratos.policy` | qrexec policy: deny clipboard, file-copy, OpenInVM/URL and RPC **out of** any persona qube — dom0 enforces "nothing leaves the persona" |
| `qubes/dom0/kratos-q` | dom0 driver: `on` starts `sys-whonix` then a fresh **disposable** persona workstation; `off` kills+removes it (amnesic); `audit` checks the sectioning |

## Install (on a working Qubes OS 4.x with Whonix templates)

```bash
# 1. Put the formula where dom0's Salt looks, and the policy in place:
sudo mkdir -p /srv/user_salt/kratos/files
sudo cp qubes/salt/kratos.sls        /srv/user_salt/kratos/init.sls
sudo cp qubes/salt/kratos.top        /srv/user_salt/kratos.top
sudo cp qubes/policy/30-kratos.policy /srv/user_salt/kratos/files/
sudo cp qubes/dom0/kratos-q          /usr/local/bin/ && sudo chmod +x /usr/local/bin/kratos-q

# 2. Apply it:
sudo qubesctl top.enable kratos saltenv=user
sudo qubesctl --all state.apply saltenv=user
# (or: kratos-q provision)

# 3. Verify the sectioning:
kratos-q audit         # policy denies + kratos-ws routes only through sys-whonix
```

## Use

```bash
kratos-q on            # sys-whonix up, then a disposable persona workstation
kratos-q view          # (re)launch the persona browser in that disposable
kratos-q off           # kill + remove the disposable — nothing persists
```

Persona secrets that must survive (a KeePassXC database, say) live in the
networkless `vault` qube; copy them into the disposable per-session via a
qrexec path you explicitly allow, never via the denied clipboard/file defaults.

## What this closes, and what it doesn't

- **Closes:** the "one host kernel owns everything" problem. Everyday use, the
  persona, and the Tor gateway are separate Xen domains; dom0 blocks data
  crossing out of the persona; the workstation is disposable/amnesic.
- **Still open:** a Xen or dom0 exploit (much smaller surface than a full Linux
  desktop, but not zero), firmware/hardware implants (use `kratos bootcheck`,
  Heads/AEM), and everything behavioural. No OS removes those.

## Status

The Salt formula, qrexec policy and dom0 driver are real and the driver's
command construction and the policy's deny-logic are unit-tested
(`tests/test_qubes.py`). They have **not** been run on a live Qubes dom0 in
this project yet — do a dry run (`kratos-q on` off-Qubes prints the exact
commands) and apply the Salt formula on a test machine before relying on it.

## Keep dom0 minimal; prefer official Qubes provisioning (honest note)

The security value of Qubes is a tiny dom0. `kratos-q` is intentionally small
and builds argv arrays rather than shell strings, but the long-term direction is
to keep KratosOS-on-Qubes as *declarative* as possible: the official Qubes Salt
formulas create `vault`/`personal`/`sys-whonix`/Whonix DVMs, and KratosOS should
add only the extra persona **tag** and the restrictive **qrexec policy** on top,
plus a minimal orchestrator — not re-implement provisioning that Qubes already
ships (every duplicated line is a place Qubes behaviour can drift underneath us).
The qrexec policy is validated by Qubes' own parser when present (`kratos-q
audit`); run it on a live dom0 before relying on the extra isolation.
