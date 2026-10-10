<#  kratos-validate.ps1 - validate KratosOS on Windows + VirtualBox (non-destructive)

  WHAT IT DOES
    * downloads the KratosOS ISO that GitHub Actions built (via GitHub CLI),
    * creates a self-contained VirtualBox VM with its OWN virtual disk,
    * boots the ISO so you can watch KratosOS come up and run the in-VM checks.

  IT WILL NOT TOUCH YOUR PC's DISKS.
    Everything is written only under the work folder (default
    %USERPROFILE%\KratosOS-Validate) and inside a VirtualBox VM that has its own
    virtual disk. The script never formats, partitions or writes to your
    physical drives. KratosOS's own installer (Calamares), if you choose to run
    it INSIDE the VM, can only see the VM's virtual disk - never your Windows
    disk. (Still: only ever run that installer in the VM, never from a real
    KratosOS USB plugged into this PC.)

  USAGE  (open PowerShell, cd to where you saved this file)
    powershell -ExecutionPolicy Bypass -File .\kratos-validate.ps1 deps     # install VirtualBox + GitHub CLI if missing
    powershell -ExecutionPolicy Bypass -File .\kratos-validate.ps1 getiso   # download + verify the ISO (asks you to sign in to GitHub once)
    powershell -ExecutionPolicy Bypass -File .\kratos-validate.ps1 vm        # create the VM and boot the ISO
    powershell -ExecutionPolicy Bypass -File .\kratos-validate.ps1 all       # deps -> getiso (waits for the build) -> vm
    powershell -ExecutionPolicy Bypass -File .\kratos-validate.ps1 clean     # delete ONLY this VM + its virtual disk

  Then follow the on-screen "NEXT: inside the VM" steps to run the probe.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('all', 'deps', 'getiso', 'vm', 'clean', 'help')]
    [string]$Command = 'all',

    [string]$Work   = (Join-Path $env:USERPROFILE 'KratosOS-Validate'),
    [string]$VMName = 'KratosOS-Validate',
    [int]$MemMB     = 6144,     # raise to 8192+ if your PC has >=16 GB RAM (inner VMs want RAM)
    [int]$CPUs      = 2,
    [int]$DiskGB    = 30,       # the VM's own virtual disk (for an in-VM install, if you do one)
    [switch]$Wait               # getiso: keep polling until the CI build publishes the ISO
)

# NOTE: 'Continue', not 'Stop'. Native tools (gh, VBoxManage) write progress and
# notices to stderr; under 'Stop' PowerShell turns that stderr into a fatal
# error and aborts. We check $LASTEXITCODE explicitly instead.
$ErrorActionPreference = 'Continue'
$Owner = 'NorthOfPotential'; $Repo = 'KratosOS'
$RawBase = "https://raw.githubusercontent.com/$Owner/$Repo/main"
$ActionsUrl = "https://github.com/$Owner/$Repo/actions"

function Say   ($m) { Write-Host "  $m" }
function Head  ($m) { Write-Host "`n$m" -ForegroundColor Cyan }
function Warn  ($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Die   ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Have  ($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

function Resolve-VBox {
    $c = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
                     "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Phase-Deps {
    Head "[deps] make sure VirtualBox and GitHub CLI are present"
    if (-not (Have winget)) { Warn "winget not found. Install VirtualBox (virtualbox.org) and GitHub CLI (cli.github.com) by hand, then re-run." }

    if (Resolve-VBox) { Say "VirtualBox: found ($(Resolve-VBox))" }
    elseif (Have winget) {
        Say "installing VirtualBox via winget (you may get a UAC prompt)..."
        winget install --id Oracle.VirtualBox -e --accept-source-agreements --accept-package-agreements
    } else { Warn "install VirtualBox manually: https://www.virtualbox.org/wiki/Downloads" }

    if (Have gh) { Say "GitHub CLI: found" }
    elseif (Have winget) {
        Say "installing GitHub CLI via winget..."
        winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements
        Warn "If 'gh' isn't recognized in this window afterwards, close and reopen PowerShell."
    } else { Warn "install GitHub CLI manually: https://cli.github.com/" }

    Say "Done. If anything was just installed, open a NEW PowerShell window before continuing."
}

function Ensure-Work { New-Item -ItemType Directory -Force -Path $Work | Out-Null }

function Get-LatestIsoRunId {
    # The build-iso job ONLY runs on workflow_dispatch (or tags), so only those
    # runs carry the kratosos-iso artifact. A plain push/PR run succeeds its test
    # job but has no ISO - don't pick those. Newest successful dispatch run wins.
    $id = gh run list --repo "$Owner/$Repo" --workflow ci.yml --event workflow_dispatch --status success `
            --json databaseId,createdAt -q 'sort_by(.createdAt)|reverse|.[0].databaseId' 2>&1 |
          Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
    return $id
}

function Phase-GetIso {
    Head "[getiso] download the KratosOS ISO built by GitHub Actions"
    Ensure-Work
    if (-not (Have gh)) { Die "GitHub CLI 'gh' not found. Run '.\kratos-validate.ps1 deps' first (then reopen PowerShell)." }
    # Sign in once (device/web flow) so we can read the build artifact.
    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Say "You need to sign in to GitHub once (a browser window will open)..."
        gh auth login --hostname github.com --web --git-protocol https
    }

    $rid = $null
    for ($try = 0; ; $try++) {
        $rid = Get-LatestIsoRunId
        if ($rid) {
            Say "trying run $rid ..."
            gh run download $rid --repo "$Owner/$Repo" -n kratosos-iso -D $Work 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break } else { Warn "run $rid has no ISO artifact yet (still uploading, or that run didn't build one)." }
        } else {
            Say "no completed workflow_dispatch build yet..."
        }
        if (-not $Wait) {
            Die @"
No downloadable ISO yet.
The cloud build may still be running, or it may have failed.
  * Check: $ActionsUrl
  * If it's still running, re-run with -Wait to poll:
        .\kratos-validate.ps1 getiso -Wait
  * If the ISO build failed, tell me and I'll fix it - a Windows PC can't build the ISO itself.
"@
        }
        Say "no ISO artifact yet; waiting 60s (Ctrl+C to stop)...  [$ActionsUrl]"
        Start-Sleep -Seconds 60
    }

    $iso = Get-ChildItem -Path $Work -Filter 'kratosos-*.iso' -File | Select-Object -First 1
    if (-not $iso) { Die "download finished but no kratosos-*.iso is in $Work" }
    Say "ISO: $($iso.FullName)  ($([math]::Round($iso.Length/1GB,2)) GB)"

    $sums = Join-Path $Work 'SHA256SUMS'
    if (Test-Path $sums) {
        $want = (Get-Content $sums | Where-Object { $_ -match [regex]::Escape($iso.Name) } |
                 ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1)
        if ($want) {
            $got = (Get-FileHash $iso.FullName -Algorithm SHA256).Hash.ToLower()
            if ($got -eq $want.ToLower()) { Say "checksum OK (SHA256SUMS)" }
            else { Warn "CHECKSUM MISMATCH - do not trust this ISO (want $want got $got)" }
        }
    }
    # Optional: verify the build-provenance attestation (proves CI built it).
    gh attestation verify $iso.FullName -R "$Owner/$Repo" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Say "build provenance attestation VERIFIED" }
    Set-Content -Path (Join-Path $Work '.iso-path') -Value $iso.FullName
    Say "Saved ISO path for the 'vm' step."
}

function Phase-VM {
    Head "[vm] create a self-contained VirtualBox VM and boot the ISO"
    Ensure-Work
    $vbox = Resolve-VBox
    if (-not $vbox) { Die "VBoxManage not found. Run '.\kratos-validate.ps1 deps' first (reopen PowerShell after install)." }

    $isoPathFile = Join-Path $Work '.iso-path'
    $iso = if (Test-Path $isoPathFile) { Get-Content $isoPathFile } else { $null }
    if (-not $iso -or -not (Test-Path $iso)) {
        $cand = Get-ChildItem -Path $Work -Filter 'kratosos-*.iso' -File | Select-Object -First 1
        if ($cand) { $iso = $cand.FullName }
    }
    if (-not $iso) { Die "No ISO found in $Work. Run '.\kratos-validate.ps1 getiso' first." }

    $vmdir = Join-Path $Work 'VirtualBox'
    New-Item -ItemType Directory -Force -Path $vmdir | Out-Null

    # Reuse the VM if it already exists; otherwise create it in our work folder.
    $exists = (& $vbox list vms) -match "`"$VMName`""
    if ($exists) {
        Say "VM '$VMName' already exists - reusing it. (Use 'clean' to remove it first for a fresh one.)"
    } else {
        Say "creating VM '$VMName' in $vmdir ..."
        & $vbox createvm --name $VMName --ostype Debian_64 --basefolder $vmdir --register | Out-Null
        # Core settings. nested-hw-virt lets KratosOS run its OWN (Whonix) VMs
        # inside this VM - needed for the Stealth/sVirt test; harmless otherwise.
        & $vbox modifyvm $VMName --memory $MemMB --cpus $CPUs --pae on --ioapic on `
            --vram 128 --graphicscontroller vmsvga --rtcuseutc on `
            --nic1 nat --firmware bios --boot1 dvd --boot2 disk --boot3 none --boot4 none | Out-Null
        & $vbox modifyvm $VMName --nested-hw-virt on 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Say "nested virtualization: ON" }
        else { Warn "could not enable nested virtualization on this CPU - the offline/firewall checks still work; the Stealth/sVirt test needs it." }
        & $vbox modifyvm $VMName --audio none 2>&1 | Out-Null   # best-effort; option name varies by VBox version

        $vdi = Join-Path (Join-Path $vmdir $VMName) "$VMName.vdi"
        Say "creating a $DiskGB GB virtual disk (the VM's own disk - not your PC's) ..."
        & $vbox createmedium disk --filename $vdi --size ($DiskGB * 1024) --format VDI | Out-Null
        & $vbox storagectl $VMName --name SATA --add sata --controller IntelAhci --portcount 2 --bootable on | Out-Null
        & $vbox storageattach $VMName --storagectl SATA --port 0 --device 0 --type hdd --medium $vdi | Out-Null
    }
    # (Re)attach the ISO on the optical drive every run.
    & $vbox storageattach $VMName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $iso | Out-Null

    Say "starting the VM - a window will open; let it boot to the KratosOS desktop."
    & $vbox startvm $VMName --type gui | Out-Null

    Head "NEXT: inside the VM (KratosOS desktop) - open a terminal and run the probe"
    Write-Host @"
  Quick checks (no install needed, safe on the live desktop):
      curl -fsSL $RawBase/tools/kratos-validate.sh | bash -s -- probe

  Full checks incl. the vault-ACL + sVirt cross-disk test (needs more room):
    1) In the VM, double-click "Install KratosOS" and install it ONTO THE VM's
       virtual disk (it only sees that disk - your Windows is not visible to it).
       Choose encryption when offered. Reboot, remove the ISO if asked.
    2) Then in a terminal:
      curl -fsSL $RawBase/tools/kratos-validate.sh | bash -s -- probe --stealth

  The probe writes kratos-probe-report.txt in the VM. Copy its text out
  (shared clipboard, or read it on screen) and send it to me.

  Tip: give the VM 8192 MB (-MemMB 8192) if your PC has >=16 GB RAM - the inner
  Whonix VMs in the Stealth test want memory.
"@
}

function Phase-Clean {
    Head "[clean] remove ONLY this VM and its virtual disk (nothing else)"
    $vbox = Resolve-VBox
    if (-not $vbox) { Die "VBoxManage not found." }
    $exists = (& $vbox list vms) -match "`"$VMName`""
    if (-not $exists) { Say "VM '$VMName' does not exist - nothing to do."; return }
    try { & $vbox controlvm $VMName poweroff 2>$null | Out-Null } catch {}
    Start-Sleep -Seconds 2
    & $vbox unregistervm $VMName --delete | Out-Null
    Say "removed VM '$VMName' and its virtual disk. The ISO and logs in $Work are kept."
    Say "To remove everything, delete the folder yourself: $Work"
}

switch ($Command) {
    'deps'   { Phase-Deps }
    'getiso' { Phase-GetIso }
    'vm'     { Phase-VM }
    'clean'  { Phase-Clean }
    'help'   { Get-Help $MyInvocation.MyCommand.Path -Detailed }
    'all'    { Phase-Deps; if (-not $Wait) { $script:Wait = $true }; Phase-GetIso; Phase-VM }
}
