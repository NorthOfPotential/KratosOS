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
- [ ] Download the Whonix **KVM** image, its `.asc`, and `derivative.asc` from whonix.org/wiki/KVM.
- [ ] `sudo kratos stealth setup ~/Downloads/Whonix-*.libvirt.xz` — signature verifies, vault is created (new passphrase).
- [ ] Tray → **Stealth Mode** on. The host locks down, the vault unlocks, Gateway then Workstation start.
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
