# Compartmentalization and the Qubes question

## The honest framing

You asked for a "Qubes patch that fixes the root/hypervisor exploit by
sectioning." Here is the straight answer: **you cannot bolt Qubes-grade
isolation onto a running Debian/KVM host with a patch.** Qubes' protection
comes from its *architecture* — a bare-metal **Xen** hypervisor started before
anything else, with the GUI, networking, USB and each activity in separate VMs,
and a tiny trusted base. KratosOS runs a normal Linux kernel as the host, so
that host is, and remains, a single point of failure a root exploit can own.

What KratosOS *can* do — and now does — is **shrink the blast radius** within
the KVM model, and give you a clean path to the real thing. Claiming more than
that would be the dangerous kind of dishonesty.

## What the "sectioning" patch actually does (shipped)

Enforced by `harden-whonix.py` on setup and on **every** Stealth start
(`tests/test_harden_whonix.py` covers it):

- **sVirt per-VM confinement.** Each VM gets a dynamic, per-domain security
  label (`<seclabel type="dynamic" relabel="yes"/>`). libvirt (AppArmor/SELinux)
  then confines each QEMU process to *its own* disk and resources. A compromised
  Gateway QEMU process cannot read the Workstation's disk or wander the host
  filesystem the way an unconfined process could.
- **No shared backing disk** between Gateway and Workstation, and no
  `<shareable/>` disks — so there's no file-level bridge between compartments.
- **No cross-compartment devices** (already enforced): no clipboard channel, no
  file-transfer, no USB redirection, no shared folders, no `shmem`.
- **The network split itself is a compartment boundary:** the Workstation can
  only reach the Gateway (checked), so a Workstation compromise still can't get
  a direct route out.
- **`hidepid` + a dedicated display user** (see THREAT_MODEL) keep your *normal*
  session from seeing or touching the persona at all.

The result: a breakout from one VM has to defeat KVM/QEMU **and** the sVirt
label **and** then the host — instead of walking straight across. That is a real
increase in cost. It is **not** equal to Xen isolation, and a kernel-level host
exploit still wins.

## The real fix: merge toward Qubes + Whonix (roadmap)

The strongest version of KratosOS is not "KratosOS instead of Qubes," it's
**KratosOS's usability on top of Qubes' isolation**. The planned path:

1. **KratosOS-on-Qubes profile.** Ship the `kratos` tool, the Stealth
   orchestration, the OpSec tools and the migration helper as a package that
   runs on a Qubes host, driving **Qubes-Whonix** (`sys-whonix` gateway +
   disposable workstation qubes) instead of our own libvirt VMs. You get the
   Windows-like normal experience in an AppVM and the one-toggle persona, but
   the isolation boundary is Xen, not one Linux kernel.
2. **Stronger KVM sectioning in the meantime:** move the Gateway and Workstation
   to separate non-root QEMU uids, add seccomp/`-sandbox` confinement, and run
   `swtpm`/microVM profiles to cut the device surface further.
3. **Verified boot** under both (measured boot + Secure Boot shim) so the host
   you trust is the host that booted.

Until (1) lands, the honest guidance stands: **for a threat model where a
targeted host exploit is realistic, run Qubes + Whonix today.** KratosOS is the
more usable, lower-assurance cousin, and it says so.
