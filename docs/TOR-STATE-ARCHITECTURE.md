# Persistent anonymity infrastructure vs. disposable persona (design)

Status: **design agreed, implementation deferred to a live-Whonix session.**
This is the target for review findings R6-H4/H5 and R8-#12. It is written down
*before* implementation on purpose: the change manipulates a signed Whonix
Gateway's filesystem and Tor's guard state, and getting it subtly wrong would
*weaken* anonymity while appearing to work. It must be built and validated
against a real Whonix guest, not merged blind.

## The problem

Today (KVM tier) the stealth vault holds three images:

```
gateway.qcow2            the Whonix Gateway disk (OS + Tor state together)
workstation-base.qcow2   clean Workstation base
workstation.qcow2        disposable Workstation overlay (wiped each toggle)
```

Since R7 the in-RAM vault key is kept for the boot, so OFF→ON reopens the same
vault and the Gateway disk is preserved — which keeps **Tor's entry-guard
state** across toggles (good: churning guards every session helps an
adversary-run relay get sampled, which Tor's guard design deliberately avoids).

But preserving the *whole mutable `gateway.qcow2`* also preserves anything that
happened to it, **including a Gateway compromise or malicious modification**
(R8-#12). And rebuilding from the cached base at reboot throws away any guest
security updates (H5). So the current design couples three things that should be
separate:

| State | Should it persist? |
|---|---|
| Tor entry-guard selection (`/var/lib/tor`) | **Yes** — persisting it is a Tor security property |
| Gateway OS (packages, config, any runtime mutation) | **No** — must be resettable so a compromise can't linger; updated from a trusted base |
| Persona Workstation (browsing/session) | **No** — amnesic, already handled |

## Target architecture

Mirror the Qubes TemplateVM/DispVM model within the KVM tier:

```
gateway-base.qcow2     read-only, trusted, UPDATED base (from signed Whonix)
gateway.qcow2          DISPOSABLE overlay on gateway-base  → reset every toggle
tor-state.qcow2        small PERSISTENT encrypted volume, ONLY /var/lib/tor
                       (guard state) → survives toggles; NOT the OS
```

- **Gateway OS is disposable:** `gateway.qcow2` becomes an overlay on
  `gateway-base.qcow2`, reset to clean on every OFF (exactly like the
  Workstation overlay today). A compromise of the running Gateway therefore
  does **not** survive a toggle.
- **Only guard state persists:** a dedicated small qcow2 (`tor-state.qcow2`,
  inside the vault, so encrypted at rest) is attached to the Gateway as a second
  disk and mounted by the guest at `/var/lib/tor`. It carries Tor's
  sampled/confirmed guard data and nothing else, so guards survive toggles (and,
  on a persistent-vault install, reboots) without carrying the mutable OS.
- **Base update lifecycle:** refreshing `gateway-base.qcow2` (and
  `workstation-base.qcow2`) from a newer signed Whonix release — the existing
  R4 cache-freshness logic already selects/verifies newer images — rebuilds the
  bases so updates are not lost to amnesia. The guard volume is preserved across
  a base refresh (it is independent of the OS image).

Result, per the table above: guards persist, Gateway/Workstation OS are
disposable and updatable, persona data is amnesic.

## Why this is NOT implemented in this pass

Every piece except the guard volume's *guest mount* is ordinary host-side work
(an overlay reset parallel to the Workstation's, a second qcow2, and a device
entry the `harden-whonix` allowlist would need to permit). The hard, unverifiable
piece is making the Whonix **guest** mount `tor-state.qcow2` at `/var/lib/tor`
with the right ownership/permissions and Tor's `DataDirectory` semantics. That
requires editing the signed Gateway image's filesystem at provision time (e.g.
an fstab/systemd-mount entry via libguestfs) and confirming, on a real booted
Whonix Gateway, that:

1. Tor actually reads/writes guard state on the mounted volume;
2. the volume's permissions don't break Tor's `DataDirectory` checks;
3. a reset of the Gateway OS overlay leaves the guard volume intact;
4. nothing else leaks onto the persistent volume;
5. the whole thing degrades safely (if the mount fails, fail closed — do NOT
   silently run with guards on the disposable overlay, which would look fine but
   churn guards).

None of (1)–(5) can be proven in CI here. Shipping it blind risks the
false-assurance failure mode the review explicitly cautions against.

## Implementation plan (for a live-Whonix session)

1. Add `gateway-base.qcow2` + a `stealth_reset_gw_overlay` (mirror of
   `stealth_reset_overlay`); wire Gateway start to the overlay.
2. Create `tor-state.qcow2` (ext4, inside the vault), attach as a second disk in
   the Gateway XML; extend the `harden-whonix` device allowlist to permit
   exactly that one extra `disk` with a pinned target/bus.
3. At provision, offline-edit the Gateway base so the guest mounts the second
   disk at `/var/lib/tor` (libguestfs), owned `debian-tor:debian-tor`, mode
   per Tor's `DataDirectory` requirement.
4. Reset the Gateway overlay on every OFF (like the Workstation); keep
   `tor-state.qcow2` and `gateway-base.qcow2`.
5. Fail CLOSED if the guard volume can't be attached/mounted (refuse to start
   rather than run with non-persistent guards).
6. Validate (1)–(5) on a booted Whonix Gateway, including `kratos fingerprint`
   and a guard-persistence check across an OFF→ON cycle and a simulated
   Gateway-overlay compromise that must NOT survive.

Until then the current behavior stands: guards persist across toggles within a
boot by preserving the whole Gateway disk, with the honest caveat that a Gateway
compromise would also persist across toggles (though not across a reboot/panic,
which discards the vault key).
