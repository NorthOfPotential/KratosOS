# Migrating from Windows 11 to KratosOS

KratosOS **replaces** Windows. Installing it erases the disk. Follow the steps
in order and don't skip the verification.

## 1. Check your hardware and software (before anything else)

- Boot the KratosOS USB in **live mode** (nothing is installed) and test Wi-Fi, Ethernet, display, external monitors, sound, touchpad, webcam, suspend/resume and USB.
- Stealth Mode needs CPU virtualization (Intel VT-x / AMD-V) turned on in the BIOS, and **16 GB RAM** is recommended (Gateway 1 GB + Workstation 4 GB + your desktop).
- Go through your installed software. The export creates a list and `kratos migrate` suggests replacements. Anything Windows-only without a replacement either runs through Bottles/Wine, needs a Windows VM (virt-manager), or needs a decision now.
- **Games with kernel anti-cheat** (Valorant, some Battlefield/Call of Duty titles, etc.) don't run on Linux. Check [areweanticheatyet.com](https://areweanticheatyet.com) before you switch.

## 2. Export on Windows

1. Plug in an external drive (preferably BitLocker-encrypted).
2. Copy `Export-WindowsData.ps1` from the KratosOS USB (`/usr/share/kratos/` in the live system, or `migration/` in this repo) to the PC.
3. Run in PowerShell:
   ```powershell
   powershell -ExecutionPolicy Bypass -File Export-WindowsData.ps1 -Destination E:\
   ```
   Add `-IncludeSSH` if you have SSH keys.
4. Work through `KratosExport\CHECKLIST.txt`: password manager export, 2FA recovery codes, licence keys, OneDrive online-only files, Proton VPN WireGuard config.
5. **Make a second copy** of the export on another drive.
6. **Verify:** open a few documents, photos and videos *from the external drive* on another computer.
7. Save the BitLocker recovery key somewhere off the PC.

## 3. Install KratosOS

1. Boot the USB → "Install KratosOS".
2. Choose **Erase disk** and **Encrypt system**, with a strong passphrase.
3. Reboot into KratosOS.

## 4. Import

```bash
kratos migrate --from /media/$USER/<drive>/KratosExport
```

- Every file is checked against the SHA-256 manifest made on Windows. If anything differs, it says so. **Keep your backups** until you've checked.
- Bookmarks are put in `~/Browser bookmarks/`. Import them in Firefox: Bookmarks → Manage → Import.
- Add `--scrub` to strip metadata (GPS etc.) from photos and documents as they're imported.

No export? `kratos migrate --from /dev/sdX3` reads the old Windows drive directly, read-only, including BitLocker with your password or recovery key.

## 5. VPN and Stealth Mode

```bash
sudo kratos vpn-import ~/wg-proton.conf    # Endpoint must be an IP address
sudo kratos mode vpn
```

Download the Whonix **KVM** image, its `.asc` signature, and the signing key
(`derivative.asc`) from [whonix.org/wiki/KVM](https://www.whonix.org/wiki/KVM), then:

```bash
sudo kratos stealth setup ~/Downloads/Whonix-*.libvirt.xz
```

This verifies the signature, creates the vault (choose a **new** passphrase),
and imports the VMs with the isolation check applied.

## Moving an existing Whonix persona

Don't import the old VirtualBox VM wholesale; it carries old state and
artifacts. Start from a fresh Whonix image, and move **only** what the persona
needs (for example its KeePassXC database) through a scrubbed, encrypted USB
stick, directly into the Workstation.
