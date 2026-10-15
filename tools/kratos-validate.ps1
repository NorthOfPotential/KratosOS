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
    [switch]$Wait,              # getiso: dispatch a matching build if needed, then poll
    [string]$Branch = 'claude/privacy-centric-os-vgpsve' # branch whose source tree the ISO must match
)

# NOTE: 'Continue', not 'Stop'. Native tools (gh, VBoxManage) write progress and
# notices to stderr; under 'Stop' PowerShell turns that stderr into a fatal
# error and aborts. We check $LASTEXITCODE explicitly instead.
$ErrorActionPreference = 'Continue'
$Owner = 'NorthOfPotential'; $Repo = 'KratosOS'
$RawBase = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"
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

function Get-CommitTreeSha ([string]$Revision) {
    # Git trees (file content) are the identity we care about. A merge commit
    # may have a different SHA yet exactly the same files as the topic branch.
    $out = gh api "repos/$Owner/$Repo/git/commits/$Revision" --jq '.tree.sha' 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Where-Object { $_ -match '^[0-9a-f]{40}$' } | Select-Object -First 1)
}

function Get-ExpectedTreeSha {
    $head = gh api "repos/$Owner/$Repo/branches/$Branch" --jq '.commit.sha' 2>&1
    if ($LASTEXITCODE -ne 0) { Die "Cannot resolve branch '$Branch': $head" }
    $head = $head | Where-Object { $_ -match '^[0-9a-f]{40}$' } | Select-Object -First 1
    if (-not $head) { Die "GitHub returned no valid HEAD SHA for '$Branch'." }
    $tree = Get-CommitTreeSha $head
    if (-not $tree) { Die "Cannot resolve the Git tree for HEAD $head." }
    Say "branch $Branch at $head (tree $tree)"
    return $tree
}

function Get-LatestIsoRunId ([string]$ExpectedTree) {
    # A successful run from another branch, or an older source revision, is NOT
    # a valid installer test. Accept a main-branch merge only if its Git tree
    # exactly matches the requested branch's tree.
    $json = gh run list --repo "$Owner/$Repo" --workflow ci.yml --event workflow_dispatch --status success --limit 100 --json databaseId,headSha,createdAt 2>&1
    if ($LASTEXITCODE -ne 0) { Die "Cannot list GitHub builds: $json" }
    try { $runs = @($json | ConvertFrom-Json) }
    catch { Die "Cannot parse GitHub build list: $_" }
    foreach ($run in ($runs | Sort-Object createdAt -Descending)) {
        if (-not $run.headSha) { continue }
        if ((Get-CommitTreeSha $run.headSha) -eq $ExpectedTree) {
            return $run.databaseId
        }
    }
    return $null
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

    $expectedTree = Get-ExpectedTreeSha
    $buildTriggered = $false
    $rid = $null
    for ($try = 0; ; $try++) {
        $rid = Get-LatestIsoRunId $expectedTree
        if (-not $rid) {
            Say "no completed workflow_dispatch build yet..."
        } else {
            Say "trying run $rid ..."
            # Does the artifact actually EXIST on this run? Ask the API directly,
            # separately from downloading it, so a flaky/interrupted transfer of a
            # multi-GB file is never misreported as "no artifact built".
            $present = $false
            $meta = gh api "repos/$Owner/$Repo/actions/runs/$rid/artifacts" `
                        -q '.artifacts[] | select(.name=="kratosos-iso") | "\(.size_in_bytes) \(.expired)"' 2>&1
            if ($LASTEXITCODE -eq 0 -and $meta -match '^\s*\d+\s+false') {
                $present = $true
                $szGB = [math]::Round(([int64](($meta -split '\s+')[0]))/1GB, 2)
                Say "  artifact present on run $rid ($szGB GB). downloading (no resume - large file, be patient)..."
            } elseif ($LASTEXITCODE -eq 0 -and $meta -match 'true\s*$') {
                Warn "run $rid built an ISO but its artifact has EXPIRED. I'll trigger a fresh build."
            }

            if ($present) {
                # gh run download won't overwrite existing files; clear any partial
                # extraction from a previous interrupted attempt first.
                Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Work 'kratosos-*.iso'), (Join-Path $Work 'SHA256SUMS')
                $ok = $false
                for ($d = 1; $d -le 4; $d++) {
                    $log = gh run download $rid --repo "$Owner/$Repo" -n kratosos-iso -D $Work 2>&1
                    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
                    Warn "download attempt $d/4 failed:"
                    $log | ForEach-Object { Write-Host "      $_" }
                    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Work 'kratosos-*.iso'), (Join-Path $Work 'SHA256SUMS')
                    if ($d -lt 4) { $w = [math]::Pow(2,$d)*3; Say "  retrying in ${w}s..."; Start-Sleep -Seconds $w }
                }
                if ($ok) { break }
                Die @"
The ISO artifact EXISTS on run $rid but the download kept failing (see errors above).
This is a transfer problem on this PC, not a missing build. Try:
  * a more stable network, then re-run:  .\kratos-validate.ps1 getiso -Wait
  * or download it by hand from:         $ActionsUrl  (open run $rid -> Artifacts -> kratosos-iso)
    then unzip it into:                  $Work
    and re-run:                          .\kratos-validate.ps1 vm
"@
            }
        }
        if ($Wait -and -not $buildTriggered) {
            Say "No usable ISO yet for this branch's Git tree; dispatching a fresh build..."
            $dispatch = gh workflow run ci.yml --repo "$Owner/$Repo" --ref "$Branch" 2>&1
            if ($LASTEXITCODE -ne 0) { Die "Cannot dispatch a build on $Branch: $dispatch" }
            $buildTriggered = $true
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

    # The checksum and provenance are security gates, not warnings. Never boot
    # an ISO if the artifact is missing verification data or verification fails.
    $sums = Join-Path $Work 'SHA256SUMS'
    if (-not (Test-Path $sums)) { Die 'SHA256SUMS missing from the ISO artifact.' }
    $hashLine = Get-Content $sums | Where-Object {
        (($_ -split '\s+')[-1]).TrimStart('*') -eq $iso.Name
    } | Select-Object -First 1
    if (-not $hashLine) { Die "No checksum found for $($iso.Name)." }
    $want = ($hashLine -split '\s+')[0]
    if ($want -notmatch '^[0-9a-fA-F]{64}$') { Die 'Malformed SHA256SUMS entry.' }
    $got = (Get-FileHash $iso.FullName -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want.ToLower()) { Die "CHECKSUM MISMATCH: do not boot this ISO (expected $want, got $got)." }
    Say 'checksum VERIFIED (SHA256SUMS)'

    $info = Join-Path $Work 'kratosos-build-info.txt'
    if (-not (Test-Path $info)) { Die 'kratosos-build-info.txt missing from the ISO artifact.' }
    $revisionLine = Get-Content $info | Where-Object { $_ -match '^source_revision:\s+[0-9a-f]{40}\s*$' } | Select-Object -First 1
    if (-not $revisionLine) { Die 'Build info has no valid source revision.' }
    $sourceRevision = ($revisionLine -split '\s+')[-1]
    if ((Get-CommitTreeSha $sourceRevision) -ne $expectedTree) {
        Die "Artifact revision $sourceRevision does not match branch $Branch; refuse stale or unrelated ISO."
    }
    Say "build source VERIFIED ($sourceRevision)"
    $attestation = gh attestation verify $iso.FullName -R "$Owner/$Repo" 2>&1
    if ($LASTEXITCODE -ne 0) { Die "Build provenance attestation FAILED: $attestation" }
    Say 'build provenance attestation VERIFIED'
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
        # Give the VM a USB controller (OHCI/USB 1.1 - no Extension Pack needed) so
        # the USB bus (/sys/bus/usb) exists in the guest; otherwise usbguard has
        # nothing to enumerate and the USBGuard test is meaningless.
        & $vbox modifyvm $VMName --usbohci on 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { & $vbox modifyvm $VMName --usb on 2>&1 | Out-Null }  # older VBox flag

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
