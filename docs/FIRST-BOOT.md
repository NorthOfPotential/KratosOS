# First Boot Checklist

Work through this the first time you boot the ISO, ideally in a VM or from a USB
stick in **live mode** before you install over anything. Tick each item.

## 1. Verify the image
- [ ] On Windows, `Get-FileHash kratosos-amd64.hybrid.iso -Algorithm SHA256` matches `SHA256SUMS`.

## 2. Live session: does the hardware work?
- [ ] Boots to the KDE desktop.
- [ ] Wi-Fi or Ethernet connects (click the network tray icon).
- [ ] Screen resolution, external monitor, trackpad, sound all work.
- [ ] `kratos status` runs and shows: firewall loaded, IPv6 disabled, DNS over TLS, a randomized MAC.

## 3. Network modes
- [ ] `sudo kratos mode offline` → `kratos status` shows offline; a browser can't load anything.
- [ ] `sudo kratos mode normal` → browsing works again.
- [ ] If you use a VPN: `sudo kratos vpn-import <file>.conf`, then `sudo kratos mode vpn`.
- [ ] **Test the kill switch:** in vpn mode, `sudo ip link set kratos0 down`, then try to load a page — it must fail. Bring it back with `sudo kratos mode vpn`.

## 4. Stealth Mode (needs VT-x/AMD-V enabled in BIOS; won't run nested unless the host VM allows it)
- [ ] **Zero-touch: just toggle it.** Tray → **Stealth Mode** on (or `sudo kratos stealth on`).
      On the first toggle KratosOS automatically downloads the Whonix KVM image,
      verifies it against the pinned Whonix signing key, and builds an amnesic
      vault (a random key kept only in RAM) — no manual download or passphrase.
      - In the default **amnesic** mode the in-RAM key is destroyed when Stealth
        turns off, so each OFF→ON cycle rebuilds the vault from the locally
        cached, signature-verified image — no re-download, but not instant
        either (it takes the time to rebuild the vault and start the VMs). The
        very first toggle also downloads Whonix. For a vault that persists
        between toggles and boots, set `STEALTH_VAULT_PERSIST=yes` (below).
      - The download runs over your current network mode. For `you → VPN → Tor`,
        switch to `vpn` first so your ISP sees only the VPN during the fetch.
      - The verified image is cached so later boots don't re-download it. The
        cache refreshes when it ages past `STEALTH_WHONIX_MAX_AGE_DAYS` (90) or
        when the mirror has a newer release — a valid signature proves the image
        is genuine, not current. On an installed system the cache sits inside the
        LUKS-encrypted root (encrypted at rest) but is a persistent on-disk
        artifact; set `STEALTH_WHONIX_CACHE=no` to always fetch fresh and keep
        nothing. On the live ISO the cache is on the ephemeral overlay anyway.
      - Want a persistent persona (keeps accounts/files across reboots)? Set
        `STEALTH_VAULT_PERSIST=yes` in `/etc/kratos/kratos.conf` and you'll be
        asked for a passphrase once. Note that `STEALTH_WORKSTATION=persistent`
        only preserves the Workstation across toggles when the VAULT itself
        persists — under the default amnesic vault the whole vault (Workstation
        included) is rebuilt each cycle, so set `STEALTH_VAULT_PERSIST=yes` too
        if you actually want the persona to remember anything. Offline install,
        or prefer to supply the image yourself?
        `sudo kratos stealth setup ~/Downloads/Whonix-*.libvirt.xz`
        still works (set `STEALTH_AUTOPROVISION=no` to require it).
- [ ] The host locks down, the vault unlocks, Gateway then Workstation start,
      and the correlation profile (`CORR_STEALTH_PROFILE`, default `off`) is
      applied. Set it to `balanced` to rate-limit + jitter the uplink; see
      docs/CORRELATION-RESISTANCE.md for the honest limits.
- [ ] Ctrl+Alt+F7 shows the persona desktop in its own session; Ctrl+Alt+F1 returns to normal.
- [ ] In the Workstation, Whonix's systemcheck reports Tor connected; `check.torproject.org` confirms you're on Tor.
- [ ] Tray → **Stealth Mode** off. The Workstation stops first, then everything else; the tray returns to "Normal".

## 5. Isolation spot-check (optional, reassuring)
- [ ] With Stealth Mode on, as your normal user: `ls /var/lib/kratos/vault` → **Permission denied**.
- [ ] `cat /run/kratos/spice/kx-ws.sock` → **Permission denied**.

## 6. Panic
- [ ] Tray → **PANIC** (or `sudo kratos panic`) powers the machine off fast. Know this before you need it.

## 7. Only after all of the above
- [ ] Back up your Windows data and **verify the backup on another computer** (see MIGRATION.md).
- [ ] Install KratosOS with **Erase disk + Encrypt** and a strong passphrase.
- [ ] Re-run this checklist on the installed system.

If something here fails, note exactly which step and open an issue — those are the
parts that can't be tested without real hardware.
