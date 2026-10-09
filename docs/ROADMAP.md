# Roadmap

## v0.2 (this version)
- [x] KDE Plasma desktop image with Calamares installer (offers full-disk encryption — the user selects it; enforcing/repo-testing encrypted install is follow-up)
- [x] Network modes normal / vpn / offline with fail-closed switching
- [x] WireGuard kill switch that also covers Stealth Mode traffic
- [x] Stealth Mode: vault, host lockdown, Whonix Gateway + Workstation, ordered on/off
- [x] Isolation check for VM definitions (setup + every start)
- [x] Tray app with Stealth toggle and panic button
- [x] Windows export script + verified import
- [x] Tests: firewall behaviour, isolation check, on/off ordering, migration

## Next
- [ ] End-to-end test: build the ISO, boot it in QEMU, run Stealth Mode with real Whonix images
- [ ] Forwarding tests for the stealth firewall (needs veth-capable CI)
- [ ] Wizard for first-time Stealth setup (download + verify Whonix in the GUI)
- [ ] Global panic hotkey
- [ ] Encrypted, separate backup tool for the vault
- [ ] Tor bridges for the Gateway in countries where Tor is blocked
- [ ] Reproducible, signed ISOs; Secure Boot
- [ ] Optional: Qubes-style isolated GUI (display the Workstation via a separate sandboxed viewer)
- [ ] Independent security review

## Correlation / compartmentalization / anti-fingerprint (this version)
- [x] sVirt per-VM confinement + no shared/bridged disks (COMPARTMENTALIZATION.md)
- [x] Opt-in local-link traffic shaping: rate limiting + jitter, with an optional decoy cover stream for continuous (average-rate) cover (CORRELATION-RESISTANCE.md). NB: the shaper is a rate *limiter*, not a constant-rate generator — only the decoy adds cover traffic.
- [x] Stylometry normalizer `kratos stylo` + always-on timing guard in Stealth
- [x] `kratos bootcheck` — /boot, ESP and TPM-PCR tamper detection
- [x] Anti-fingerprint audit: defaults must blend (`kratos fingerprint`, tests)
- [x] KratosOS-on-Qubes profile (qubes/: Salt + qrexec policy + kratos-q driver) — logic tested; live dom0 run pending
- [~] Nym mixnet components (workstation/nym/: client config + fail-closed firewall, unit-tested) — EXPERIMENTAL and NOT integrated: Stealth does not install/route Nym into the persona, and `CORR_MODE=mixnet` is refused until it does. End-to-end routing and a live Nym network run are pending.
- [ ] Separate non-root QEMU uids + seccomp sandbox per VM
- [ ] **Persistent Tor-guard state vs. disposable Gateway OS** (design agreed in
      `docs/TOR-STATE-ARCHITECTURE.md`): make the Gateway OS a disposable overlay
      on an updated base and persist ONLY `/var/lib/tor` on a small encrypted
      volume, so guards survive toggles without a Gateway compromise or stale OS
      surviving with them. Implementation needs a live Whonix guest to validate
      the guest-side mount + fail-closed behavior, so it is deliberately not
      shipped blind.

## Release-assurance gates still open (honest status)
- [ ] **ISO-build-and-boot as a release gate.** The `build-iso` CI job builds
      a real image (and fails on real build errors), but it only runs on
      dispatch/tags and there is no automated boot/install test. Booting the
      built ISO in automation (nested virt), doing an encrypted Calamares
      install, and exercising a real Whonix Stealth session + the Qubes layer on
      Qubes 4.3/Whonix 18 remain the biggest unproven-together gaps.
- [ ] **SUID/capability inventory as a release blocker.** The inventory runs
      (report-only, `continue-on-error`) and is published as an artifact.
      Per review it should become blocking only AFTER a real built-image
      baseline is reviewed and the allowlist tightened — hard-gating the current
      starter allowlist first would just push maintainers to disable the check.
