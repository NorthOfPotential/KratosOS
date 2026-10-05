# Roadmap

## v0.2 (this version)
- [x] KDE Plasma desktop image with Calamares installer (full-disk encryption)
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
- [x] Opt-in local-link traffic shaping: constant rate + jitter + decoy (CORRELATION-RESISTANCE.md)
- [x] Stylometry normalizer `kratos stylo` + always-on timing guard in Stealth
- [x] `kratos bootcheck` — /boot, ESP and TPM-PCR tamper detection
- [x] Anti-fingerprint audit: defaults must blend (`kratos fingerprint`, tests)
- [ ] KratosOS-on-Qubes profile (drive Qubes-Whonix instead of local KVM) — the real host-exploit fix
- [ ] Wire the Nym mixnet mode end-to-end (currently experimental/off)
- [ ] Separate non-root QEMU uids + seccomp sandbox per VM
