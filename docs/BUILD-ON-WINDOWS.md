# Building KratosOS without a Linux machine

You don't need Linux. There are two ways, easiest first.

## Option A: Let GitHub build the ISO (no setup)

The repository has a GitHub Actions workflow that builds the installer ISO for
you in the cloud.

1. Push this repository to your own GitHub account (or open it on github.com).
2. Go to the **Actions** tab → **CI** workflow → **Run workflow**.
3. When it finishes (~20–40 min), open the run and download the
   **kratosos-iso** artifact from the **Artifacts** section. It contains
   `kratosos-amd64.hybrid.iso` and `SHA256SUMS`.

Every push also runs the **test** job (shellcheck, firewall tests, the
isolation attack suite, etc.), so you can see if a change broke anything
without building anything yourself.

## Option B: Build locally in WSL2 (Windows Subsystem for Linux)

If you'd rather build on your own PC:

1. Open PowerShell as Administrator and install WSL with Debian:
   ```powershell
   wsl --install -d Debian
   ```
   Reboot if prompted, then start "Debian" from the Start menu and set a username.
2. In the Debian shell:
   ```bash
   sudo apt update && sudo apt install -y live-build git
   git clone <your copy of this repo> KratosOS
   cd KratosOS
   sudo ./build.sh
   ```
   `live-build` needs real mounts; if it fails on WSL1, run `wsl --set-version Debian 2`.
3. The ISO lands in the `KratosOS` folder. Copy it to Windows:
   ```bash
   cp kratosos-*.iso /mnt/c/Users/<you>/Desktop/
   ```

## Try it before installing (recommended)

You have a Windows machine with files on it, so **don't install over it until
you've tested the ISO and made backups** (see [MIGRATION.md](MIGRATION.md)).

- **In a VM first:** install [VirtualBox](https://www.virtualbox.org) on Windows,
  make a new VM (Type: Linux, Version: Debian 64-bit, 8 GB+ RAM, enable
  **EFI** in Settings → System), attach the ISO, and boot. Stealth Mode's
  own VMs won't run *inside* another VM unless nested virtualization is on, but
  you can check the desktop, migration and firewall this way.
- **On real hardware:** write the ISO to a USB stick with
  [Rufus](https://rufus.ie) (select the ISO, "DD image" mode if asked), then
  boot from it. The live session runs without touching your disk, so you can
  test Wi-Fi, graphics and Stealth Mode before committing.

## Writing the USB stick

With [Rufus](https://rufus.ie): choose your USB device, select
`kratosos-amd64.hybrid.iso`, keep the default scheme, and click Start. If it
asks ISO vs DD mode, choose **DD**. This erases the stick.

Verify the download first (PowerShell):
```powershell
Get-FileHash kratosos-amd64.hybrid.iso -Algorithm SHA256
```
Compare the output to `SHA256SUMS`.
