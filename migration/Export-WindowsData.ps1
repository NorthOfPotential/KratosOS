<#
.SYNOPSIS
    Export your files from Windows 11 so they can be imported into KratosOS.

.DESCRIPTION
    Run this on Windows BEFORE installing KratosOS. It copies your personal
    folders to an external drive, saves browser bookmarks and a list of
    installed software, and writes a SHA-256 manifest of every file.
    `kratos migrate --from <drive>\KratosExport` verifies each file against
    that manifest after copying.

    Nothing on the Windows PC is changed or deleted.

.PARAMETER Destination
    Folder on an EXTERNAL drive, for example E:\. A KratosExport folder is created inside it.

.PARAMETER IncludeSSH
    Also copy %USERPROFILE%\.ssh (private keys!). Only use with an encrypted drive.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Export-WindowsData.ps1 -Destination E:\
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Destination,
    [switch]$IncludeSSH,
    # Advanced override: proceed even when we CANNOT confirm the destination is
    # on a different physical disk from Windows (e.g. exotic/virtual storage
    # whose DiskNumber can't be resolved). Off by default — we fail closed,
    # because the next step erases the Windows disk (finding R8-5).
    [switch]$AllowUnverifiedDisk
)

$ErrorActionPreference = 'Stop'
$profileDir = $env:USERPROFILE
$exportRoot = Join-Path $Destination 'KratosExport'
$filesDir   = Join-Path $exportRoot 'Files'
$invDir     = Join-Path $exportRoot 'inventory'
$logFile    = Join-Path $exportRoot 'export.log'

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }

# ── Safety checks ──────────────────────────────────────────────
$destDrive = (Resolve-Path $Destination).Drive.Name
$sysLetter = $env:SystemDrive.TrimEnd(':')

# A different drive LETTER is not enough: C: and D: can be two partitions on the
# SAME physical disk, and the KratosOS install erases the whole disk — which
# would destroy both Windows AND this "backup" (finding R8-5). Compare the
# PHYSICAL DISK NUMBER of each and refuse a same-disk destination.
function Get-DiskNumberForLetter($letter) {
    try { return (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber }
    catch { return $null }
}
$sysDisk  = Get-DiskNumberForLetter $sysLetter
$destDisk = Get-DiskNumberForLetter $destDrive
if ($destDrive -eq $sysLetter) {
    throw "Destination is on the Windows system drive ($env:SystemDrive). Use a separate EXTERNAL drive: KratosOS will erase the Windows disk."
}
if ($null -ne $sysDisk -and $null -ne $destDisk -and $sysDisk -eq $destDisk) {
    throw ("Destination ($destDrive`:) is on the SAME physical disk (#$destDisk) as Windows ($sysLetter`:). " +
           "The backup MUST be on a DIFFERENT physical device — the KratosOS install erases the whole Windows disk, " +
           "which would also erase this backup. Use an external USB drive.")
}
if ($null -eq $sysDisk -or $null -eq $destDisk) {
    if (-not $AllowUnverifiedDisk) {
        throw ("Could not confirm the destination is on a DIFFERENT physical disk from Windows " +
               "(could not resolve a disk number for $sysLetter`: or $destDrive`:). Refusing to " +
               "continue, because the KratosOS install erases the Windows disk. Use a plain external " +
               "USB drive, or — only if you are certain it is a separate physical device — re-run with " +
               "-AllowUnverifiedDisk.")
    }
    Say "WARNING: could not confirm a separate physical disk; proceeding because -AllowUnverifiedDisk was given." Yellow
    Say "You are asserting the backup drive is a SEPARATE physical device. Double-check before erasing." Yellow
}

$folders = 'Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos', 'Favorites'
$shell = New-Object -ComObject Shell.Application
# Resolve real locations (folders can be redirected, e.g. into OneDrive)
$known = @{
    Desktop   = [Environment]::GetFolderPath('Desktop')
    Documents = [Environment]::GetFolderPath('MyDocuments')
    Downloads = $shell.Namespace('shell:Downloads').Self.Path
    Pictures  = [Environment]::GetFolderPath('MyPictures')
    Music     = [Environment]::GetFolderPath('MyMusic')
    Videos    = [Environment]::GetFolderPath('MyVideos')
    Favorites = [Environment]::GetFolderPath('Favorites')
}

Say "Measuring what will be copied..." Cyan
$total = 0
foreach ($f in $folders) {
    if ($known[$f] -and (Test-Path $known[$f])) {
        $total += (Get-ChildItem $known[$f] -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Offline) } |
                   Measure-Object Length -Sum).Sum
    }
}
$free = (Get-PSDrive $destDrive).Free
Say ("Data: {0:N1} GB   Free on {1}: {2:N1} GB" -f ($total / 1GB), $destDrive, ($free / 1GB))
if ($total -gt $free * 0.95) { throw "Not enough space on the destination drive." }

New-Item -ItemType Directory -Force -Path $filesDir, $invDir | Out-Null
"KratosOS export started $(Get-Date -Format o) by $env:USERNAME" | Set-Content $logFile

# Track real copy FAILURES across every robocopy run. A robocopy exit code >= 8
# means files could not be copied — the export is INCOMPLETE and must NOT be
# treated as a usable backup before an erase-disk install (finding R8-6).
$copyFailed = $false
$failedWhat = @()

# ── Copy personal folders ─────────────────────────────────────
# robocopy: /E subfolders, /XJ skip junction loops, /R /W fast retry,
# skip junk files and OneDrive cloud-only placeholders (attribute O = offline)
foreach ($f in $folders) {
    $src = $known[$f]
    if (-not $src -or -not (Test-Path $src)) { continue }
    Say "Copying $f..." Cyan
    robocopy $src (Join-Path $filesDir $f) /E /XJ /R:1 /W:1 /XA:O /NP /NFL /NDL `
        /XF desktop.ini Thumbs.db *.lnk '~$*' /LOG+:$logFile | Out-Null
    if ($LASTEXITCODE -ge 8) {
        $copyFailed = $true; $failedWhat += $f
        Say "  ERROR: files in $f could not be copied (robocopy exit $LASTEXITCODE), see export.log" Red
    }
}

# Cloud-only OneDrive files aren't on this PC; list them so nothing is forgotten
$cloudOnly = foreach ($f in $folders) {
    if ($known[$f] -and (Test-Path $known[$f])) {
        Get-ChildItem $known[$f] -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::Offline } |
            Select-Object -ExpandProperty FullName
    }
}
if ($cloudOnly) {
    $cloudOnly | Set-Content (Join-Path $invDir 'onedrive-cloud-only-NOT-copied.txt')
    Say "  $($cloudOnly.Count) OneDrive files are online-only and were NOT copied (see inventory)." Yellow
}

if ($IncludeSSH -and (Test-Path "$profileDir\.ssh")) {
    Say "Copying .ssh (private keys)..." Cyan
    robocopy "$profileDir\.ssh" (Join-Path $filesDir '.ssh') /E /R:1 /W:1 /NP /NFL /NDL /LOG+:$logFile | Out-Null
    if ($LASTEXITCODE -ge 8) {
        $copyFailed = $true; $failedWhat += '.ssh'
        Say "  ERROR: .ssh could not be fully copied (robocopy exit $LASTEXITCODE), see export.log" Red
    }
}

# ── Browser bookmarks (NOT saved passwords) ───────────────────
Say "Saving browser bookmarks..." Cyan
$bm = Join-Path $filesDir 'Browser bookmarks'
New-Item -ItemType Directory -Force -Path $bm | Out-Null
$chromium = @{
    'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Bookmarks"
    'Edge'   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Bookmarks"
    'Brave'  = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Bookmarks"
}
foreach ($name in $chromium.Keys) {
    if (Test-Path $chromium[$name]) { Copy-Item $chromium[$name] (Join-Path $bm "$name-bookmarks.json") }
}
Get-ChildItem "$env:APPDATA\Mozilla\Firefox\Profiles\*\places.sqlite" -ErrorAction SilentlyContinue |
    ForEach-Object { Copy-Item $_.FullName (Join-Path $bm "Firefox-$($_.Directory.Name)-places.sqlite") }
if (-not (Get-ChildItem $bm)) { Remove-Item $bm }

# ── Inventory ─────────────────────────────────────────────────
Say "Listing installed software..." Cyan
$uninstallKeys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
    Select-Object DisplayName, DisplayVersion, Publisher |
    Sort-Object DisplayName -Unique |
    Export-Csv (Join-Path $invDir 'installed-software.csv') -NoTypeInformation -Encoding UTF8

$checklist = @"
KratosOS migration checklist (things this script can't copy for you)
=====================================================================
[ ] Password manager: export (e.g. KeePass .kdbx, Bitwarden JSON) to the encrypted drive
[ ] 2FA / authenticator recovery codes saved somewhere safe
[ ] Browser saved passwords moved into your password manager (not copied on purpose)
[ ] Email: IMAP accounts just need re-adding; export local PST archives if you have them
[ ] Licence keys for paid software
[ ] Game saves stored outside Documents (check each game)
[ ] OneDrive online-only files: download or keep using OneDrive on the web
[ ] Proton VPN: download a WireGuard config (Account > Downloads > WireGuard),
    with a server IP address as the Endpoint, for `kratos vpn-import`
[ ] BitLocker recovery key saved OFF this computer (see below)
[ ] Open several exported files on another computer to check the backup works
[ ] This backup drive is a DIFFERENT PHYSICAL DEVICE from the Windows disk
    (not just a different drive letter/partition) — the install erases the
    whole Windows disk
[ ] Make a SECOND copy of this export on another separate device
"@
$checklist | Set-Content (Join-Path $exportRoot 'CHECKLIST.txt') -Encoding UTF8

# ── Manifest (verified by `kratos migrate`) ───────────────────
Say "Computing SHA-256 of every file (this can take a while)..." Cyan
$utf8 = New-Object System.Text.UTF8Encoding($false)
$base = (Resolve-Path $exportRoot).Path.TrimEnd('\') + '\'
$lines = Get-ChildItem $filesDir -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($base.Length).Replace('\', '/')
    '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLower(), $rel
}

$marker = Join-Path $exportRoot 'INCOMPLETE-DO-NOT-ERASE-WINDOWS.txt'
if ($copyFailed) {
    # Finding R8-6: some files could not be copied, so this export is NOT a
    # complete backup. Do NOT write a usable manifest.sha256 (so `kratos migrate`
    # refuses to import a partial backup as if it were whole), write a loud
    # persistent marker, and exit non-zero. Fix the errors (see export.log) and
    # re-run before erasing Windows.
    [IO.File]::WriteAllText((Join-Path $exportRoot 'manifest.sha256.INCOMPLETE'), (($lines -join "`n") + "`n"), $utf8)
    @"
INCOMPLETE EXPORT — DO NOT ERASE WINDOWS
========================================
Some files could not be copied: $($failedWhat -join ', ')
See export.log for details. This export is NOT a complete backup.

There is deliberately NO manifest.sha256 here, so KratosOS will refuse to
import it as a finished backup. Fix the copy errors and run the exporter
again until it finishes with NO errors before you erase this computer.
"@ | Set-Content $marker -Encoding UTF8
    Say "`nEXPORT INCOMPLETE — some files failed to copy ($($failedWhat -join ', '))." Red
    Say "DID NOT write manifest.sha256. DO NOT ERASE WINDOWS. See $marker and export.log, then re-run." Red
    exit 1
}
# All copies succeeded: remove any stale marker from a previous failed run and
# publish the real manifest.
if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }
if (Test-Path (Join-Path $exportRoot 'manifest.sha256.INCOMPLETE')) {
    Remove-Item (Join-Path $exportRoot 'manifest.sha256.INCOMPLETE') -Force -ErrorAction SilentlyContinue
}
[IO.File]::WriteAllText((Join-Path $exportRoot 'manifest.sha256'), (($lines -join "`n") + "`n"), $utf8)

# ── BitLocker reminder ────────────────────────────────────────
try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($bl.ProtectionStatus -eq 'On') {
        Say "`nBitLocker is ON for $env:SystemDrive." Yellow
        Say "Make sure the recovery key is saved OFF this PC (https://account.microsoft.com/devices/recoverykey" Yellow
        Say "or: manage-bde -protectors -get $env:SystemDrive, run as administrator). You need it if anything goes wrong." Yellow
    }
} catch { }

Say "`nDone. Export: $exportRoot" Green
Say "Files: $($lines.Count). Next: read CHECKLIST.txt, then make a second copy of the export." Green
Say "After installing KratosOS:  kratos migrate --from /media/<you>/<drive>/KratosExport" Green
