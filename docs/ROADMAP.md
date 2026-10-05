# Roadmap

## v0.1 (this release)
- [x] live-build ISO definition (Debian trixie)
- [x] Fail-closed nftables modes: tor / vpn / vpn-tor / offline
- [x] Tor transparent proxy + DNS, stream isolation
- [x] Kernel, sysctl and module hardening
- [x] MAC randomization, generic hostname, UTC
- [x] `kratos` CLI: status, check, mode, newnym, vm, scrub, shred, migrate, panic, scan
- [x] Windows 11 file migration (NTFS + BitLocker)

## v0.2
- [ ] Graphical control panel (GTK) and panic hotkey
- [ ] Encrypted persistence wizard
- [ ] Tor bridge configuration UI (obfs4, Snowflake)
- [ ] Reproducible builds and signed ISOs
- [ ] Automated leak tests in CI (boot ISO in QEMU, assert no clear-text packets)

## v0.3
- [ ] Qubes/Whonix-style split: separate Tor gateway VM and workstation VMs
- [ ] Per-app network identities
- [ ] Verified boot / Secure Boot shim
- [ ] Independent security audit
