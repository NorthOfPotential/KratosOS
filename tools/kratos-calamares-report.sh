#!/usr/bin/env bash
# Read-only Calamares installation failure diagnostics. Run from the LIVE VM.
# No unmounts, disk writes, or LUKS changes. Output may contain usernames,
# partition UUIDs and filesystem labels: review before sharing.
set -uo pipefail
out="${HOME}/kratos-calamares-report.txt"
{
  echo "KratosOS Calamares failure report (read-only)"
  date -Is
  uname -a
  echo
  echo "== Firmware / disk / encrypted mappings =="
  if test -d /sys/firmware/efi; then echo "Firmware: UEFI"; else echo "Firmware: BIOS"; fi
  lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS 2>&1 || true
  echo
  echo "== Installer-related mount tree =="
  findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 |
    grep -E 'calamares|/target|/run/live|/lib/live|/media|/mnt' || true
  echo
  echo "== Calamares and mount process state =="
  ps -eo pid,ppid,stat,args 2>&1 | grep -Ei '[c]alamares|[u]mount|[m]ount |[c]ryptsetup|[g]rub-install|[u]pdate-grub' || true
  echo
  echo "== Calamares logs (last 350 lines each) =="
  for f in /root/.cache/calamares/session.log /root/.cache/calamares/calamares.log /var/log/calamares.log /tmp/calamares.log; do
    if sudo test -f "$f"; then
      echo "--- $f"
      sudo tail -n 350 "$f" 2>&1 || true
    fi
  done
  echo
  echo "== Installer journal (last 250 lines) =="
  sudo journalctl -b --no-pager -n 250 -t calamares 2>&1 || true
  echo
  echo "== Relevant boot journal errors (last 160) =="
  sudo journalctl -b --no-pager -p warning..alert 2>&1 |
    grep -Ei 'calamares|umount|busy|cryptsetup|grub|mount|target' | tail -n 160 || true
} > "$out" 2>&1
chmod 600 "$out"
printf 'Report saved: %s\nReview it for personal data before sharing.\n' "$out"
