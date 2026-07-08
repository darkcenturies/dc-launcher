#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Dad's MMO Lab -- Windows Substrate Installer
.DESCRIPTION
    Bootstraps a clean Arch Linux (dml-arch) + Docker Engine environment in
    WSL2 -- the same substrate the DML scripts already run on for Steam Deck.
    No game logic lives here. Games are layered on top with 'dml run'.

    Phase 1 (PowerShell, elevated): preflights, enables WSL2 features, reboots once.
    Phase 2 (PowerShell, elevated): installs Arch Linux as 'dml-arch', Docker Engine.
    Phase 3 (bash, inside dml-arch): core deps + the 'dml' CLI.

    Supports Windows 10 (2004 / build 19041+) and Windows 11 (22H2+).
    Install location is chosen at first run; defaults to C:\DML.

    Run as Administrator. One click, one reboot, then run any DML script.
#>
[CmdletBinding()]
param(
    [switch]$ResumePhase2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Paths
# =============================================================================
$StateDir   = "$env:LOCALAPPDATA\DadsMMOLab"
$StateFile  = "$StateDir\install-state.json"
$LogFile    = "$StateDir\install.log"
$WslDir     = "$StateDir\wsl"
$ScriptPath = $MyInvocation.MyCommand.Path
if (-not $ScriptPath) { $ScriptPath = $PSCommandPath }

# =============================================================================
# Constants
# =============================================================================
$DiskNeededBytes = 30GB
$DmlDistroName   = 'dml-arch'
$DmlLinuxUser    = 'dml'
$TaskName        = 'DadsMmoLab-Phase2'
$DmlCliVersion   = '2.2.1'   # bundled dml CLI version (keep in sync with embedded VERSION)

$Script:FailReported = $false

# =============================================================================
# Logging
# =============================================================================
function Write-Step([string]$msg) {
    $line = "[step] $msg"
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'HH:mm:ss') $line"
}

function Write-Diag([string]$msg) {
    $line = "[diag] $msg"
    Write-Host $line -ForegroundColor DarkGray
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'HH:mm:ss') $line"
}

function Write-Warn([string]$msg) {
    $line = "[WARN] $msg"
    Write-Host $line -ForegroundColor Yellow
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'HH:mm:ss') $line"
}

function Write-Ok([string]$msg) {
    $line = "[ok]   $msg"
    Write-Host $line -ForegroundColor Green
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'HH:mm:ss') $line"
}

function Write-Fail([string]$msg) {
    $line = "[FAIL] $msg"
    Write-Host $line -ForegroundColor Red
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'HH:mm:ss') $line"
    $Script:FailReported = $true
    throw $msg
}

# =============================================================================
# State
# =============================================================================
function Save-State([string]$InstallRoot) {
    try {
        @{
            Phase1Complete = $true
            InstallRoot    = $InstallRoot
            Timestamp      = (Get-Date -Format 'o')
        } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    } catch {
        Write-Fail "Could not save installer state to $StateFile -- check disk space and permissions.`n($($_.Exception.Message))"
    }
    Write-Diag "State saved: $StateFile"
}

# =============================================================================
# Step-completion markers (re-run safety for slow Phase 2/3 steps)
# =============================================================================
function Test-StepDone([string]$step) {
    Test-Path "$StateDir\done-$step"
}
function Mark-StepDone([string]$step) {
    New-Item -ItemType File -Force -Path "$StateDir\done-$step" | Out-Null
    Write-Diag "Step '$step' marked complete"
}
function Clear-DistroStepMarkers {
    # Called when we do a fresh distro import so stale inside-distro markers
    # from a previous install don't cause those steps to be skipped.
    foreach ($step in @('dml-user', 'wsl-conf', 'arch-keyring', 'docker-install', 'phase3-bootstrap')) {
        Remove-Item "$StateDir\done-$step" -Force -ErrorAction SilentlyContinue
    }
    Write-Diag "Cleared inside-distro step markers for fresh import"
}

# =============================================================================
# Preflight checks
# =============================================================================
function Assert-WindowsBuild {
    Write-Step "Checking Windows version..."
    $build      = [System.Environment]::OSVersion.Version.Build
    $Win11Build = 22621  # Win11 22H2
    $Win10Build = 19041  # Win10 2004
    Write-Diag "Build: $build  (Win10 min: $Win10Build  Win11 min: $Win11Build)"
    if ($build -ge $Win11Build) {
        Write-Ok "Windows 11 (build $build) -- OK"
    } elseif ($build -ge $Win10Build) {
        Write-Ok "Windows 10 (build $build) -- OK"
    } else {
        Write-Fail "Windows 10 version 2004 (build 19041) or Windows 11 22H2 (build 22621) or later is required.`nPlease run Windows Update, then try again."
    }
}

function Assert-VirtualizationFirmware {
    Write-Step "Checking CPU virtualization (required for WSL2)..."

    # Tri-state: $true = confirmed on, $null = inconclusive.
    # Never hard-fail on inconclusive -- the real test is whether WSL2 starts.
    $virtState = $null

    # Check 1 (authoritative): is a hypervisor already running?
    # Covers Hyper-V, Core Isolation / Memory Integrity, and any prior WSL2 run.
    # When true, virtualization is working -- do not parse systeminfo.
    try {
        $hv = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent
        Write-Diag "Win32_ComputerSystem.HypervisorPresent: $hv"
        if ($hv -eq $true) { $virtState = $true }
    } catch {
        Write-Diag "HypervisorPresent query failed: $($_.Exception.Message)"
    }

    # Check 2: firmware flag -- positive only.
    # A $false here is ignored; it's false-negative-prone when Hyper-V is active.
    if ($virtState -ne $true) {
        try {
            $vals = @(Get-CimInstance Win32_Processor -ErrorAction Stop |
                      Select-Object -ExpandProperty VirtualizationFirmwareEnabled)
            Write-Diag "Win32_Processor.VirtualizationFirmwareEnabled: $($vals -join ', ')"
            if ($vals -contains $true) { $virtState = $true }
        } catch {
            Write-Diag "Win32_Processor query failed: $($_.Exception.Message)"
        }
    }

    if ($virtState -eq $true) {
        Write-Ok "CPU virtualization enabled"
        return
    }

    Write-Warn "Couldn't positively confirm CPU virtualization, but found no blocker -- continuing."
    Write-Warn "If WSL2 fails to start later, enable Intel VT-x or AMD-V (SVM) in your BIOS/UEFI."
}

function Assert-DiskSpace([string]$InstallRoot) {
    $driveLetter = $InstallRoot.Substring(0, 1).ToUpper()
    Write-Step "Checking disk space on ${driveLetter}:..."
    try {
        $drive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
        if ($null -ne $drive.Free) {
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            Write-Diag "${driveLetter}: free: $freeGB GB  (need: 30 GB)"
            if ($drive.Free -lt $DiskNeededBytes) {
                Write-Fail "Not enough disk space on ${driveLetter}:. Need 30 GB free, found $freeGB GB.`nFree up space or choose a different drive."
            }
            Write-Ok "${driveLetter}: $freeGB GB free -- OK"
        } else {
            Write-Warn "Could not read free space on ${driveLetter}: -- continuing"
        }
    } catch {
        Write-Warn "Could not check disk space on ${driveLetter}: ($($_.Exception.Message)) -- continuing"
    }
}

function Assert-Internet {
    Write-Step "Checking internet connection..."
    try {
        $null = Invoke-WebRequest -Uri 'https://www.microsoft.com' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        Write-Ok "Internet connection OK"
    } catch {
        Write-Fail "No internet connection detected.`nThe installer needs to download WSL2 components and the Arch Linux image.`nConnect to the internet and try again."
    }
}

# =============================================================================
# WSL enable
# =============================================================================
function Enable-Wsl2Features {
    Write-Step "Enabling WSL2 features..."

    # Three cases to handle:
    #   (A) Fully working: wsl --version exit 0 AND hypervisor loaded  -> skip, no reboot
    #   (B) Features enabled but never rebooted: HypervisorPresent=False, features Enabled -> reboot
    #   (C) Features missing: enable them (wsl --install or Enable-WindowsOptionalFeature) -> reboot
    #
    # Cannot rely on wsl --version alone: Store-installed WSL makes exit 0 even when
    # VirtualMachinePlatform is inactive. Cannot rely on Get-WindowsOptionalFeature
    # alone: Store-installed WSL reports features as 'Disabled' even when fully working.
    # Both signals together cover all known machine states.

    $hvPresent = $false
    try { $hvPresent = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch {}
    Write-Diag "HypervisorPresent: $hvPresent"

    Write-Diag "Running: wsl --version (idempotency check)"
    wsl --version | Out-Null
    $wslVersionExit = $LASTEXITCODE
    Write-Diag "wsl --version exit code: $wslVersionExit"

    # Case A: everything is working
    if ($wslVersionExit -eq 0 -and $hvPresent) {
        Write-Ok "WSL2 already installed and working -- no reboot needed"
        return $false
    }

    if ($wslVersionExit -eq 0 -and -not $hvPresent) {
        Write-Diag "WSL executable present but hypervisor not loaded -- checking Windows feature state"
    }

    $wslFeat = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    $vmFeat  = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform            -ErrorAction SilentlyContinue
    Write-Diag "WSL feature state:         $($wslFeat.State)"
    Write-Diag "VM Platform feature state: $($vmFeat.State)"

    # Case B: features already on, just needs a reboot to load the hypervisor
    if ($wslFeat.State -eq 'Enabled' -and $vmFeat.State -eq 'Enabled') {
        if (-not $hvPresent) {
            Write-Ok "WSL2 features are enabled -- a reboot is needed to activate the hypervisor"
            return $true
        }
        Write-Ok "WSL2 features already enabled"
        return $false
    }

    # Case C: one or both features are missing -- enable them
    Write-Diag "Running: wsl --install --no-distribution"
    wsl --install --no-distribution
    $wslExit = $LASTEXITCODE
    Write-Diag "wsl --install exit code: $wslExit"

    if ($wslExit -ne 0) {
        Write-Warn "wsl --install returned $wslExit -- falling back to Enable-WindowsOptionalFeature"

        try {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -All | Out-Null
        } catch {
            Write-Fail "Failed to enable the Windows Subsystem for Linux feature.`nTry running Windows Update, restarting, and running this installer again.`n($($_.Exception.Message))"
        }

        try {
            Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -All | Out-Null
        } catch {
            Write-Fail "Failed to enable the Virtual Machine Platform feature.`nTry running Windows Update, restarting, and running this installer again.`n($($_.Exception.Message))"
        }
    }

    Write-Ok "WSL2 features enabled -- reboot required"
    return $true
}

# =============================================================================
# Scheduled task registration
# =============================================================================
function Register-Phase2Task {
    Write-Step "Registering Phase 2 to auto-run after you log back in..."

    if (-not $ScriptPath) {
        Write-Fail "Cannot determine installer script path -- save the script to a fixed location and run it from there."
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-ExecutionPolicy Bypass -WindowStyle Normal -File `"$ScriptPath`" -ResumePhase2"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
                     -RunOnlyIfNetworkAvailable:$false
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    Write-Diag "Scheduled task '$TaskName' registered for user '$($env:USERNAME)'"
    Write-Ok "Phase 2 will start automatically after you log in"
}

# =============================================================================
# Phase 1
# =============================================================================
function Invoke-Phase1 {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Dad's MMO Lab -- Environment Setup  [Phase 1 of 2]" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Setting up a clean Arch Linux + Docker environment in WSL2." -ForegroundColor White
    Write-Host "  It runs the same scripts as the Steam Deck." -ForegroundColor White
    Write-Host "  Games are installed separately with 'dml run' once this is done." -ForegroundColor White
    Write-Host "  Phase 1 runs some checks and may need one reboot." -ForegroundColor White
    Write-Host ""

    # Choose install location
    Write-Host "  Where do you want to install DML?" -ForegroundColor White
    Write-Host "  This is where the Linux environment (WSL VHD) and launcher will be stored." -ForegroundColor White
    Write-Host "  The folder will be created if it doesn't exist." -ForegroundColor White
    Write-Host "  Examples: D:\DML   E:\Games\DML" -ForegroundColor DarkGray
    Write-Host ""
    $defaultRoot = 'C:\DML'
    $rawInput    = Read-Host "  Install location (press Enter for $defaultRoot)"
    $InstallRoot = if ([string]::IsNullOrWhiteSpace($rawInput)) { $defaultRoot } else { $rawInput.Trim().TrimEnd('\') }
    if ($InstallRoot -notmatch '^[A-Za-z]:') {
        Write-Fail "Install path must start with a drive letter (e.g., D:\DML).`nNetwork paths and relative paths are not supported by WSL."
    }
    Write-Diag "Install root: $InstallRoot"
    Write-Ok "Installing to: $InstallRoot"
    Write-Host ""

    Assert-WindowsBuild
    Assert-VirtualizationFirmware
    Assert-DiskSpace -InstallRoot $InstallRoot
    Assert-Internet

    Write-Step "Saving installer state..."
    Save-State -InstallRoot $InstallRoot

    $rebootNeeded = Enable-Wsl2Features

    if ($rebootNeeded) {
        Register-Phase2Task

        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host "  Phase 1 complete -- one reboot needed" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Alright, we need to reboot once -- totally normal." -ForegroundColor White
        Write-Host "  I'll pick up right where we left off." -ForegroundColor White
        Write-Host "  Phase 2 installs Arch Linux and Docker (10-20 min, runs automatically)." -ForegroundColor White
        Write-Host ""

        $go = Read-Host "  Restart now? (y/n)"
        if ($go -match '^[Yy]') {
            Write-Diag "Initiating restart..."
            Restart-Computer -Force
        } else {
            Write-Host ""
            Write-Host "  No problem -- restart whenever you're ready." -ForegroundColor Yellow
            Write-Host "  Phase 2 kicks off automatically when you log back in." -ForegroundColor Yellow
        }
    } else {
        Write-Host ""
        Write-Host "  WSL2 was already enabled -- no reboot needed." -ForegroundColor Green
        Write-Host "  Moving straight to Phase 2..." -ForegroundColor White
        Write-Host ""
        Invoke-Phase2
    }
}

# =============================================================================
# Phase 2 helper
# =============================================================================
function Invoke-WslBash {
    param(
        [string]$Distro,
        [string]$User,
        [string]$Script,
        [string]$Label
    )
    Write-Diag "[$Label] running in $Distro as $User"

    # Ensure the distro is running before touching \\wsl$\.
    # wsl can auto-start a distro on UNC access, but an explicit no-op run here
    # surfaces any startup failure with a clear message rather than a cryptic
    # file-write error, and guarantees the distro is fully initialised first.
    wsl -d $Distro -u $User -- true
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "[$Label] Distro '$Distro' failed to start (exit $LASTEXITCODE)."
    }

    # The \\wsl$\ share is served by the WSL service and is usually ready
    # immediately after the distro starts, but allow up to two retries (3 s each)
    # in case the share lags slightly behind the distro.
    $wslTmp = "\\wsl$\$Distro\tmp"
    $ready  = $false
    for ($i = 0; $i -lt 3; $i++) {
        if (Test-Path $wslTmp) { $ready = $true; break }
        Write-Diag "[$Label] \\wsl$\$Distro\tmp not yet accessible -- waiting 3 s (attempt $($i+1)/3)..."
        Start-Sleep -Seconds 3
    }
    if (-not $ready) {
        Write-Fail "[$Label] WSL filesystem '$wslTmp' is not accessible after distro start."
    }
    Write-Diag "[$Label] WSL filesystem ready"

    # Write the script as a file via \\wsl$\ rather than piping via stdin.
    # Piping through PowerShell encodes strings with $OutputEncoding, which on
    # some Windows locale/codepage combinations injects a BOM or mis-encodes
    # characters before bash sees them. Writing raw UTF-8 bytes directly to the
    # WSL filesystem bypasses the encoding pipeline entirely.
    $cleanScript = $Script.Replace("`r`n", "`n")
    $tmpWin   = "$wslTmp\dml-step.sh"
    $tmpLinux = '/tmp/dml-step.sh'
    [System.IO.File]::WriteAllBytes($tmpWin, [System.Text.UTF8Encoding]::new($false).GetBytes($cleanScript))

    # PS 5.1 with $ErrorActionPreference = 'Stop' promotes native-command stderr
    # to a terminating error. Commands like pacman-key / gpg write informational
    # lines to stderr that are not failures -- lowering EAP to Continue for this
    # call prevents PS from aborting on them. Real bash failures are still caught
    # via $LASTEXITCODE (bash's own set -euo pipefail handles internal errors).
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        wsl -d $Distro -u $User -- bash $tmpLinux | Out-Host
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }

    wsl -d $Distro -u $User -- rm -f $tmpLinux | Out-Null

    Write-Diag "[$Label] exit code: $exit"
    return $exit
}

# =============================================================================
# Phase 2
# =============================================================================
function Invoke-Phase2 {
    param([switch]$AfterReboot)
    New-Item -ItemType Directory -Force -Path $StateDir -ErrorAction SilentlyContinue | Out-Null

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Dad's MMO Lab -- Environment Setup  [Phase 2 of 2]" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    if ($AfterReboot) {
        Write-Step "Resuming after reboot..."
    } else {
        Write-Step "Starting Phase 2 (WSL2 already enabled)..."
    }

    # Remove the scheduled task immediately -- must not fire again on next login
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Diag "Scheduled task removed"

    if (-not (Test-Path $StateFile)) {
        Write-Fail "Install state not found at $StateFile.`nPlease re-run Phase 1 (run Install-DML.ps1 without -ResumePhase2)."
    }

    # Load install root saved by Phase 1; fall back to C:\DML for legacy state files
    $stateJson   = $null
    try { $stateJson = (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch {}
    $InstallRoot = if ($stateJson -and $stateJson.InstallRoot) { $stateJson.InstallRoot } else { 'C:\DML' }
    $WslDir      = "$InstallRoot\wsl"
    Write-Diag "Install root: $InstallRoot"
    Write-Diag "WSL dir:      $WslDir"

    # -------------------------------------------------------------------------
    # Step 5: Update WSL + set default version to 2
    # -------------------------------------------------------------------------
    Write-Step "Updating WSL to latest version..."
    wsl --update
    $wslUpdateExit = $LASTEXITCODE
    Write-Diag "wsl --update exit code: $wslUpdateExit"
    if ($wslUpdateExit -ne 0) {
        Write-Warn "wsl --update returned $wslUpdateExit -- continuing with current version"
    } else {
        Write-Ok "WSL updated"
    }

    Write-Step "Setting WSL2 as default distro version..."
    wsl --set-default-version 2
    $wslDefaultExit = $LASTEXITCODE
    Write-Diag "wsl --set-default-version 2 exit code: $wslDefaultExit"
    if ($wslDefaultExit -ne 0) {
        Write-Fail "Failed to set WSL default version to 2 (exit $wslDefaultExit)."
    }
    Write-Ok "WSL2 set as default version"

    # Guard against null: Select-String returns $null when wsl --version output
    # encoding doesn't match (e.g. Store WSL on Windows 11 outputs UTF-16).
    $wslVerMatch = wsl --version | Select-String 'WSL version' | Select-Object -First 1
    $wslVerStr   = if ($wslVerMatch) { $wslVerMatch.Line -replace '.*WSL version:\s*', '' } else { '' }
    Write-Diag "WSL version: '$wslVerStr'"
    if ($wslVerStr) {
        try {
            $wslVer = [version]($wslVerStr.Trim().Split('.')[0..2] -join '.')
            if ($wslVer -lt [version]'2.4.4') {
                Write-Warn "WSL $wslVerStr is below the recommended minimum 2.4.4."
                Write-Warn "Run 'wsl --update' from an admin terminal, then re-run this installer."
            } else {
                Write-Ok "WSL version $wslVerStr -- OK"
            }
        } catch {
            Write-Diag "Could not parse WSL version string -- skipping version floor check"
        }
    }

    # -------------------------------------------------------------------------
    # Step 6: Write .wslconfig (RAM + CPU + swap caps, localhost forwarding)
    # -------------------------------------------------------------------------
    Write-Step "Configuring WSL2 resource limits (.wslconfig)..."
    $cs          = Get-CimInstance Win32_ComputerSystem
    $totalRamGB  = [math]::Round($cs.TotalPhysicalMemory / 1GB)
    $hostCores   = $cs.NumberOfLogicalProcessors
    $wslRamGB    = [math]::Max(2, [math]::Round($totalRamGB * 0.60))
    $wslSwapGB   = [math]::Max(2, [math]::Round($wslRamGB / 2))
    $wslCores    = [math]::Min(4, $hostCores)
    Write-Diag "Host: ${totalRamGB} GB RAM, $hostCores logical cores"
    Write-Diag "WSL2 cap: ${wslRamGB} GB RAM, $wslCores cores, ${wslSwapGB} GB swap"

    $wslConfigPath = "$env:USERPROFILE\.wslconfig"
    @"
[general]
instanceIdleTimeout=-1

[wsl2]
memory=${wslRamGB}GB
processors=$wslCores
swap=${wslSwapGB}GB
networkingMode=mirrored
dnsTunneling=true
firewall=true
kernelCommandLine=vm.swappiness=1
vmIdleTimeout=-1

[experimental]
autoMemoryReclaim=gradual
"@ | Set-Content -Path $wslConfigPath -Encoding UTF8
    Write-Ok ".wslconfig written: ${wslRamGB} GB RAM, $wslCores cores, mirror networking, vm.swappiness=1, autoMemoryReclaim=gradual"
    Write-Diag "Applying .wslconfig (requires brief WSL shutdown)..."
    wsl --shutdown 2>$null | Out-Null
    Start-Sleep -Seconds 3
    Write-Ok "WSL restarted with Windows 11 optimisations active"

    # -------------------------------------------------------------------------
    # Step 6.5: Windows Defender exclusions — WSL2 + Docker I/O performance
    # -------------------------------------------------------------------------
    Write-Step "Adding Windows Defender exclusions for WSL2 performance..."
    $defenderPaths = @(
        "$env:LOCALAPPDATA\Packages",
        "$env:USERPROFILE\.docker",
        "$env:APPDATA\Docker"
    )
    $wslPkg = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'CanonicalGroupLimited*' } | Select-Object -First 1
    if ($wslPkg) { $defenderPaths += $wslPkg.FullName }
    $added = 0
    foreach ($p in $defenderPaths) {
        try {
            $cur = (Get-MpPreference -ErrorAction Stop).ExclusionPath
            if ($cur -notcontains $p) {
                Add-MpPreference -ExclusionPath $p -ErrorAction Stop
                Write-Ok "Defender: excluded $p"
                $added++
            } else { Write-Diag "Defender: already excluded $p" }
        } catch { Write-Warn "Could not add Defender exclusion for ${p}: $($_.Exception.Message)" }
    }
    if ($added -gt 0) { Write-Ok "Defender: $added exclusion(s) added — Docker I/O will be faster" }

    # -------------------------------------------------------------------------
    # Step 6.6: Docker daemon — faster log driver
    # -------------------------------------------------------------------------
    Write-Step "Configuring Docker daemon (log-driver: local)..."
    $daemonJson = @'
{
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
'@
    try {
        Invoke-WslBash "mkdir -p /etc/docker && cat > /etc/docker/daemon.json << 'EOF'
$daemonJson
EOF"
        Write-Ok "Docker daemon.json: log-driver=local (faster than json-file, capped 10 MB x3)"
        Invoke-WslBash "systemctl is-active docker &>/dev/null && systemctl restart docker || true" | Out-Null
    } catch { Write-Warn "Could not configure Docker daemon.json: $($_.Exception.Message)" }

    # -------------------------------------------------------------------------
    # Step 7: Install Arch Linux as isolated 'dml-arch' distro
    #
    # wsl --install has no --name flag, so we:
    #   1. Install as 'archlinux' (official Store image)
    #   2. Export to a temp tar
    #   3. Import as 'dml-arch' into $WslDir (isolated VHD, no collision)
    #   4. Unregister 'archlinux' only if we were the ones who installed it
    # -------------------------------------------------------------------------
    Write-Step "Installing Arch Linux as '$DmlDistroName' (isolated distro)..."

    # wsl -l --quiet outputs UTF-16 LE on Windows 11; strip null bytes before matching
    $distroRaw      = (wsl -l --quiet) -replace "`0", ""
    Write-Diag "Registered distros: $($distroRaw -join ' | ')"
    $dmlArchPresent = [bool]($distroRaw | Where-Object { $_ -match '^dml-arch$' })

    if ($dmlArchPresent) {
        Write-Ok "'$DmlDistroName' already registered -- skipping install"
    } else {
        $archlinuxPreExisted = [bool]($distroRaw | Where-Object { $_ -match '^archlinux$' })
        Write-Diag "archlinux pre-existed: $archlinuxPreExisted"

        if (-not $archlinuxPreExisted) {
            Write-Step "Downloading official Arch Linux WSL image (source for import)..."
            wsl --install -d archlinux --no-launch
            $archInstallExit = $LASTEXITCODE
            Write-Diag "wsl --install archlinux exit code: $archInstallExit"
            if ($archInstallExit -ne 0) {
                Write-Fail "Failed to download Arch Linux from the Microsoft Store (exit $archInstallExit).`nCheck your internet connection and try again."
            }
        } else {
            Write-Diag "Using pre-existing 'archlinux' as import source"
        }

        # Brief init run to ensure the filesystem is fully unpacked before export
        Write-Diag "Initializing Arch Linux filesystem..."
        wsl -d archlinux -u root -- true
        $initExit = $LASTEXITCODE
        Write-Diag "Init run exit code: $initExit"
        if ($initExit -ne 0) {
            Write-Warn "Arch Linux init run returned $initExit -- proceeding with export (export will fail if the image is corrupt)."
        }

        # bsdtar (used by wsl --export) cannot archive Unix socket files and hard-fails.
        # Socket files are created by gpg-agent and other daemons during init and persist in
        # the VHD after forced termination. Remove them while the distro is still live.
        Write-Diag "Removing socket files before export (bsdtar cannot archive sockets)..."
        wsl -d archlinux -u root -- find / -xdev -type s -delete
        Write-Diag "Socket cleanup exit code: $LASTEXITCODE"

        wsl --terminate archlinux
        Write-Diag "wsl --terminate archlinux exit code: $LASTEXITCODE"

        # Export archlinux → import as dml-arch
        New-Item -ItemType Directory -Force -Path $WslDir | Out-Null
        $TmpTar = "$env:TEMP\dml-arch-rootfs.tar"

        # Remove any leftover tar from a prior interrupted run -- wsl --export will not overwrite.
        Remove-Item $TmpTar -Force -ErrorAction SilentlyContinue

        Write-Step "Exporting Arch Linux filesystem to temp tar..."
        wsl --export archlinux $TmpTar
        $exportExit = $LASTEXITCODE
        Write-Diag "wsl --export exit code: $exportExit"
        if ($exportExit -ne 0) {
            Remove-Item $TmpTar -Force -ErrorAction SilentlyContinue
            Write-Fail "Failed to export Arch Linux filesystem (exit $exportExit)."
        }

        Write-Step "Importing as '$DmlDistroName' to $WslDir..."
        wsl --import $DmlDistroName $WslDir $TmpTar
        $importExit = $LASTEXITCODE
        Remove-Item $TmpTar -Force -ErrorAction SilentlyContinue
        Write-Diag "wsl --import exit code: $importExit"
        if ($importExit -ne 0) {
            Write-Fail "Failed to import Arch Linux as '$DmlDistroName' (exit $importExit)."
        }

        if (-not $archlinuxPreExisted) {
            Write-Diag "Removing temporary 'archlinux' registration..."
            wsl --unregister archlinux
            $unregExit = $LASTEXITCODE
            Write-Diag "wsl --unregister exit code: $unregExit"
            if ($unregExit -ne 0) {
                Write-Warn "Could not remove temporary 'archlinux' distro (exit $unregExit).`nRemove it manually when convenient: wsl --unregister archlinux"
            }
        }

        # Clear any stale inside-distro step markers from a prior install attempt
        Clear-DistroStepMarkers
        Write-Ok "Arch Linux installed as '$DmlDistroName'"
    }

    wsl --set-default $DmlDistroName
    $setDefaultExit = $LASTEXITCODE
    Write-Diag "wsl --set-default exit code: $setDefaultExit"
    if ($setDefaultExit -ne 0) {
        Write-Warn "Could not set '$DmlDistroName' as default WSL distro (exit $setDefaultExit).`nFix manually: wsl --set-default dml-arch"
    }

    # -------------------------------------------------------------------------
    # Step 8a: Initialize pacman keyring + full system update
    # Fresh Arch-WSL ships with an empty keyring -- pacman fails until this runs.
    # -------------------------------------------------------------------------
    if (Test-StepDone 'arch-keyring') {
        Write-Ok "Arch Linux keyring + system update already done -- skipping"
    } else {
        Write-Step "Initializing Arch Linux (keyring + system update -- a few minutes)..."

        $exit8a = Invoke-WslBash -Distro $DmlDistroName -User root -Label 'keyring' -Script @'
set -euo pipefail
echo "[arch] Initializing pacman keyring..."
pacman-key --init
pacman-key --populate archlinux
echo "[arch] Keyring ready"
echo "[arch] Running full system update..."
pacman -Syu --noconfirm
echo "[arch] System up to date"
'@
        if ($exit8a -ne 0) {
            Write-Fail "Arch Linux keyring / system update failed (exit $exit8a).`nCheck your internet connection and the log: $LogFile"
        }
        Write-Ok "Arch Linux packages up to date"
        Mark-StepDone 'arch-keyring'
    }

    # -------------------------------------------------------------------------
    # Step 8b: Create the dml Linux user with sudo access
    # Docker group does not exist yet -- added in Step 9 after docker install.
    # -------------------------------------------------------------------------
    if (Test-StepDone 'dml-user') {
        Write-Ok "Linux user '$DmlLinuxUser' already configured -- skipping"
    } else {
        Write-Step "Creating Linux user '$DmlLinuxUser'..."

        $exit8b = Invoke-WslBash -Distro $DmlDistroName -User root -Label 'useradd' -Script @'
set -euo pipefail
pacman -S --noconfirm --needed sudo
if id dml &>/dev/null; then
    echo "[arch] User 'dml' already exists"
else
    useradd -m -G wheel dml
    echo "[arch] User 'dml' created"
fi
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel
echo "[arch] sudo configured"
'@
        if ($exit8b -ne 0) {
            Write-Fail "Failed to create Linux user '$DmlLinuxUser' (exit $exit8b)."
        }
        Write-Ok "Linux user '$DmlLinuxUser' ready with sudo access"
        Mark-StepDone 'dml-user'
    }

    # -------------------------------------------------------------------------
    # Step 8c: Write /etc/wsl.conf and restart distro to activate systemd
    # -------------------------------------------------------------------------
    if (Test-StepDone 'wsl-conf') {
        Write-Ok "systemd already configured in wsl.conf -- skipping"
    } else {
        Write-Step "Enabling systemd in Arch Linux..."

        $exit8c = Invoke-WslBash -Distro $DmlDistroName -User root -Label 'wsl.conf' -Script @'
set -euo pipefail
printf '[boot]\nsystemd=true\n\n[user]\ndefault=dml\n' > /etc/wsl.conf
echo "[arch] /etc/wsl.conf written"
'@
        if ($exit8c -ne 0) {
            Write-Fail "Failed to write /etc/wsl.conf (exit $exit8c)."
        }

        Write-Step "Restarting distro to activate systemd (wsl --terminate)..."
        wsl --terminate $DmlDistroName
        Write-Diag "wsl --terminate exit code: $LASTEXITCODE"
        Start-Sleep -Seconds 3
        Write-Ok "Systemd active on next distro start"
        Mark-StepDone 'wsl-conf'
    }

    # -------------------------------------------------------------------------
    # Step 9: Install Docker Engine inside Arch (now with systemd running)
    # usermod -aG docker dml runs after the docker package creates the docker group.
    # -------------------------------------------------------------------------
    if (Test-StepDone 'docker-install') {
        Write-Ok "Docker Engine already installed -- skipping"
    } else {
        Write-Step "Installing Docker Engine (downloading packages -- several minutes)..."

        $exit9 = Invoke-WslBash -Distro $DmlDistroName -User root -Label 'docker-install' -Script @'
set -euo pipefail
echo "[docker] Waiting for systemd to initialize..."
timeout 60 bash -c 'until systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"; do sleep 2; done'
echo "[docker] systemd ready"
echo "[docker] Installing packages..."
pacman -S --noconfirm --needed docker docker-compose docker-buildx
echo "[docker] Enabling docker service..."
systemctl enable --now docker
echo "[docker] Adding dml to docker group..."
usermod -aG docker dml
echo "[docker] Waiting for Docker socket..."
timeout 30 bash -c 'until [ -S /var/run/docker.sock ]; do sleep 1; done'
echo "[docker] Done"
'@
        if ($exit9 -ne 0) {
            Write-Fail "Docker Engine installation failed (exit $exit9).`nCheck the log: $LogFile"
        }
        Write-Ok "Docker Engine installed and enabled"
        Mark-StepDone 'docker-install'
    }

    Write-Step "Verifying Docker..."
    # Wait for the Docker socket before running hello-world. This handles the case
    # where the distro was just started fresh (systemd takes a few seconds to bring
    # docker.service up) or a re-run where Docker was never stopped but is slow.
    $socketWait = Invoke-WslBash -Distro $DmlDistroName -User root -Label 'docker-socket' -Script @'
set -euo pipefail
timeout 30 bash -c 'until [ -S /var/run/docker.sock ]; do sleep 1; done'
echo "[docker] Socket ready"
'@
    if ($socketWait -ne 0) {
        Write-Warn "Docker socket not available within 30s (exit $socketWait) -- hello-world test may fail."
    }
    wsl -d $DmlDistroName -u root -- docker run --rm hello-world
    $dockerTestExit = $LASTEXITCODE
    Write-Diag "Docker hello-world exit code: $dockerTestExit"
    if ($dockerTestExit -ne 0) {
        Write-Warn "Docker hello-world test failed (exit $dockerTestExit). Check the log: $LogFile"
    } else {
        Write-Ok "Docker is working"
    }

    # -------------------------------------------------------------------------
    # CLI version check (always runs -- fast if already current)
    # If the installed version doesn't match the bundled version, clear the
    # phase3-bootstrap marker so Step 10 re-installs the CLI automatically.
    # -------------------------------------------------------------------------
    $ExpectedCliVersion = "dml v$DmlCliVersion"
    $installedCliRaw = ''
    try {
        $installedCliRaw = (wsl -d $DmlDistroName -- dml version 2>$null)
        if ($installedCliRaw) { $installedCliRaw = ($installedCliRaw -replace "`0","").Trim() }
    } catch { }
    Write-Diag "dml CLI: installed='$installedCliRaw'  expected='$ExpectedCliVersion'"
    if ($installedCliRaw -ne $ExpectedCliVersion) {
        Write-Diag "CLI version mismatch -- clearing phase3-bootstrap marker to force re-install"
        Remove-Item "$StateDir\done-phase3-bootstrap" -Force -ErrorAction SilentlyContinue
    }

    # -------------------------------------------------------------------------
    # Step 10: Phase 3 bootstrap -- core deps + dml CLI
    #
    # The dml CLI is base64-encoded here and decoded inside the distro.
    # This avoids nested-heredoc quoting issues and CRLF contamination.
    # -------------------------------------------------------------------------
    if (Test-StepDone 'phase3-bootstrap') {
        Write-Ok "Phase 3 bootstrap already done -- skipping"
    } else {
        Write-Step "Installing core dependencies and dml CLI (Phase 3)..."

        $DmlCli = @'
#!/usr/bin/env bash
set -euo pipefail

VERSION="__DML_CLI_VERSION__"
GAMES_DIR="$HOME/games"

_require_docker() {
    if ! docker info &>/dev/null; then
        echo "[dml] Docker is not running. Try: sudo systemctl start docker" >&2
        exit 1
    fi
}

_has_compose() {
    local dir="$1" name
    for name in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$dir/$name" ]] && return 0
    done
    return 1
}

_compose_running() {
    local dir="$1" name compose_file=""
    for name in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [[ -f "$dir/$name" ]]; then compose_file="$dir/$name"; break; fi
    done
    [[ -z "$compose_file" ]] && echo 0 && return
    { docker compose -f "$compose_file" ps --status running -q 2>/dev/null || true; } | wc -l | tr -d '[:space:]'
}

_check_port_conflicts() {
    local in_use
    in_use=$(ss -tlnp 2>/dev/null)

    # DB port: remap silently -- safe to move because clients never connect to it directly
    if echo "$in_use" | grep -q ':3306[[:space:]]'; then
        if ! grep -q 'DOCKER_DB_EXTERNAL_PORT' .env 2>/dev/null; then
            printf 'DOCKER_DB_EXTERNAL_PORT=13306\n' >> .env
            echo "[dml] Port 3306 in use — remapped DB host port to 13306"
        fi
    fi

    # Game server ports: warn only -- clients connect to fixed ports, cannot silently remap
    local _ports=(
        "3724:WoW auth/login server (TrinityCore, AzerothCore, MaNGOS)"
        "8085:WoW world server (TrinityCore, AzerothCore)"
        "8086:WoW SOAP API (TrinityCore, AzerothCore)"
        "4000:EverQuest zone server (EQEmu)"
        "5998:EverQuest login server (EQEmu)"
        "5999:EverQuest login server (EQEmu)"
        "9000:EverQuest world/zone server (EQEmu)"
        "2593:Ultima Online game server (ServUO / RunUO)"
        "7171:Tibia game server (OpenTibia / OTServBR)"
        "6112:Blizzard legacy port (Warcraft III / Diablo II)"
        "43594:RuneScape private server (RSPS)"
        "2106:Lineage II login server (L2J)"
        "7777:Lineage II game server (L2J)"
        "54230:Final Fantasy XI auth server (Darkstar)"
        "54231:Final Fantasy XI game server (Darkstar)"
        "44453:Star Wars Galaxies login server"
        "44462:Star Wars Galaxies connection server"
    )
    local entry port desc
    for entry in "${_ports[@]}"; do
        port="${entry%%:*}"
        desc="${entry#*:}"
        if echo "$in_use" | grep -q ":${port}[[:space:]]"; then
            echo "[WARN] Port $port is already in use -- $desc."
            echo "[WARN]   Stop whatever is using port $port before starting this server."
        fi
    done
}

# Windows-side helpers (paths written at install time by Install-DML.ps1)
DML_WIN_ROOT='__DML_INSTALL_ROOT__'

_win_path() { echo "${DML_WIN_ROOT//\\//}/$1"; }

_ensure_keepalive() {
    command -v powershell.exe &>/dev/null || return 0
    local ps1
    ps1=$(_win_path "DML-Ensure-Keepalive.ps1")
    powershell.exe -NoProfile -WindowStyle Hidden -File "$ps1" 2>/dev/null || true
}

_release_wsl() {
    # Must run detached on Windows AFTER this WSL session exits -- cannot self-terminate.
    command -v powershell.exe &>/dev/null || return 0
    local ps1 win_ps1
    ps1=$(_win_path "DML-Release-WSL.ps1")
    win_ps1="${ps1//\//\\}"
    powershell.exe -NoProfile -WindowStyle Hidden -Command \
        "Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-File','${win_ps1}') -WindowStyle Hidden" \
        2>/dev/null || true
}

_update_titles_cache() {
    command -v powershell.exe &>/dev/null || return 0
    local cache titles=() dir title
    cache=$(_win_path "dml-titles.cache")
    [[ ! -d "$GAMES_DIR" ]] && return 0
    for dir in "$GAMES_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        title=$(basename "$dir")
        if _has_compose "$dir"; then
            titles+=("$title")
        else
            for subdir in "$dir"*/; do
                [[ -d "$subdir" ]] && _has_compose "$subdir" && titles+=("$title") && break
            done
        fi
    done
    [[ ${#titles[@]} -eq 0 ]] && return 0
    printf '%s\n' "${titles[@]}" | powershell.exe -NoProfile -Command \
        "\$p='$cache'; \$i=\$input | Out-String; Set-Content -Path \$p -Value \$i.TrimEnd() -Encoding UTF8" \
        2>/dev/null || true
}

_win_to_mnt() {
    local p="${1//\\//}"
    echo "/mnt/c${p#C:}"
}

_wslconfig_path() {
    local p
    p=$(powershell.exe -NoProfile -Command '$env:USERPROFILE + "\.wslconfig"' 2>/dev/null | tr -d '\r\n')
    [[ -n "$p" ]] && _win_to_mnt "$p"
}

_doctor_section() { echo ""; echo "== $1 =="; }

_DML_WOW_HOOK_BASE="https://raw.githubusercontent.com/DadsMmoLab/dads-mmo-lab/main/guides/wow-wotlk"

_sync_missing_wow_hooks() {
    local dir="$1" file dest
    [[ -x "$dir/dml-start.sh" ]] || return 0
    for file in wow-manage.sh; do
        dest="$dir/$file"
        [[ -f "$dest" ]] && continue
        if curl -fsSL "${_DML_WOW_HOOK_BASE}/${file}" -o "$dest"; then
            chmod +x "$dest"
            echo "[dml] Fetched missing $file for $(basename "$dir")"
        else
            echo "[WARN]  $(basename "$dir"): could not fetch $file"
            warns=$((warns + 1))
        fi
    done
}

_stop_title_graceful() {
    local title="$1" dir="$GAMES_DIR/$title" compose_dir="$GAMES_DIR/$title"
    if [[ ! -d "$dir" ]]; then
        echo "[dml] ERROR: Title not found: $title" >&2
        return 1
    fi
    if [[ -x "$dir/dml-stop.sh" ]]; then
        bash "$dir/dml-stop.sh"
        return
    fi
    if ! _has_compose "$dir"; then
        for subdir in "$dir"*/; do
            if [[ -d "$subdir" ]] && _has_compose "$subdir"; then
                compose_dir="$subdir"; break
            fi
        done
    fi
    if ! _has_compose "$compose_dir"; then
        echo "[dml] ERROR: No compose file found in $title or its subdirectories." >&2
        return 1
    fi
    _require_docker
    cd "$compose_dir" || return 1
    echo "[dml] Stopping $title (containers only -- data volumes are preserved)..."
    docker compose down >"$compose_dir/.dml-stop.log" 2>&1 \
        || { echo "[dml] ERROR: Stop failed -- see $compose_dir/.dml-stop.log" >&2; return 1; }
    echo "[dml] $title stopped -- progress saved on disk"
}

_stop_all_running_titles() {
    command -v docker &>/dev/null || { echo "[dml] Docker not available -- skipping server stop"; return 0; }
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        echo "[dml] Docker not running -- no servers to stop"
        return 0
    fi

    local -A _seen=()
    local -a titles=()
    local dir title compose_dir count subdir project

    if [[ -d "$GAMES_DIR" ]]; then
        for dir in "$GAMES_DIR"/*/; do
            [[ -d "$dir" ]] || continue
            title=$(basename "$dir")
            compose_dir="$dir"
            if ! _has_compose "$dir"; then
                for subdir in "$dir"*/; do
                    if [[ -d "$subdir" ]] && _has_compose "$subdir"; then
                        compose_dir="$subdir"; break
                    fi
                done
            fi
            if _has_compose "$compose_dir"; then
                count=$(_compose_running "$compose_dir")
                if [[ "$count" -gt 0 ]]; then
                    titles+=("$title")
                    _seen["$title"]=1
                fi
            fi
        done
    fi

    while IFS= read -r project; do
        [[ -z "$project" ]] || [[ -n "${_seen[$project]:-}" ]] && continue
        if docker ps -q --filter "label=com.docker.compose.project=$project" 2>/dev/null | grep -q .; then
            titles+=("$project")
            _seen["$project"]=1
        fi
    done < <(docker ps --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null | sort -u | grep -v '^$')

    if [[ ${#titles[@]} -eq 0 ]]; then
        echo "[dml] No running game servers to stop"
        return 0
    fi

    for title in "${titles[@]}"; do
        compose_dir=""
        if [[ -d "$GAMES_DIR/$title" ]]; then
            compose_dir="$GAMES_DIR/$title"
            if ! _has_compose "$compose_dir"; then
                for subdir in "$GAMES_DIR/$title"*/; do
                    if [[ -d "$subdir" ]] && _has_compose "$subdir"; then
                        compose_dir="$subdir"; break
                    fi
                done
            fi
        fi
        if [[ -n "$compose_dir" ]] && _has_compose "$compose_dir"; then
            echo "[dml] Stopping $title..."
            ( cd "$compose_dir" && docker compose down ) \
                || echo "[WARN] Failed to stop $title" >&2
            echo "[dml] $title stopped"
        else
            echo "[dml] Stopping compose project $title..."
            docker compose -p "$title" down 2>/dev/null \
                || echo "[WARN] Failed to stop project $title" >&2
        fi
    done
    _update_titles_cache
}

_restart_all_running_titles() {
    command -v docker &>/dev/null || { echo "[dml] Docker not available"; return 1; }
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        echo "[dml] Docker not running -- no servers to restart"
        return 1
    fi

    local -A _seen=()
    local -a titles=()
    local dir title compose_dir count subdir project

    if [[ -d "$GAMES_DIR" ]]; then
        for dir in "$GAMES_DIR"/*/; do
            [[ -d "$dir" ]] || continue
            title=$(basename "$dir")
            compose_dir="$dir"
            if ! _has_compose "$dir"; then
                for subdir in "$dir"*/; do
                    if [[ -d "$subdir" ]] && _has_compose "$subdir"; then
                        compose_dir="$subdir"; break
                    fi
                done
            fi
            if _has_compose "$compose_dir"; then
                count=$(_compose_running "$compose_dir")
                if [[ "$count" -gt 0 ]]; then
                    titles+=("$title")
                    _seen["$title"]=1
                fi
            fi
        done
    fi

    while IFS= read -r project; do
        [[ -z "$project" ]] || [[ -n "${_seen[$project]:-}" ]] && continue
        if docker ps -q --filter "label=com.docker.compose.project=$project" 2>/dev/null | grep -q .; then
            titles+=("$project")
            _seen["$project"]=1
        fi
    done < <(docker ps --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null | sort -u | grep -v '^$')

    if [[ ${#titles[@]} -eq 0 ]]; then
        echo "[dml] No active servers to restart"
        return 1
    fi

    for title in "${titles[@]}"; do
        compose_dir=""
        if [[ -d "$GAMES_DIR/$title" ]]; then
            compose_dir="$GAMES_DIR/$title"
            if ! _has_compose "$compose_dir"; then
                for subdir in "$GAMES_DIR/$title"*/; do
                    if [[ -d "$subdir" ]] && _has_compose "$subdir"; then
                        compose_dir="$subdir"; break
                    fi
                done
            fi
        fi
        if [[ -n "$compose_dir" ]] && _has_compose "$compose_dir"; then
            _start_title "$title" restart || echo "[WARN] Failed to restart $title" >&2
        else
            echo "[dml] Restarting compose project $title..."
            docker compose -p "$title" down 2>/dev/null || true
            docker compose -p "$title" up -d 2>/dev/null \
                || echo "[WARN] Failed to restart project $title" >&2
        fi
    done
    _update_titles_cache
}

_start_title() {
    local title="$1"
    local mode="${2:-start}"
    local dir="$GAMES_DIR/$title"
    if [[ ! -d "$dir" ]]; then echo "[dml] ERROR: Title not found: $title" >&2; exit 1; fi
    local compose_dir="$dir"
    if ! _has_compose "$dir"; then
        for subdir in "$dir"*/; do
            if [[ -d "$subdir" ]] && _has_compose "$subdir"; then
                compose_dir="$subdir"; break
            fi
        done
    fi
    if ! _has_compose "$compose_dir"; then
        echo "[dml] ERROR: No compose file found in $title or its subdirectories." >&2; exit 1
    fi
    _require_docker
    _ensure_keepalive
    cd "$compose_dir"

    if [[ -x "$dir/dml-start.sh" ]]; then
        echo "[dml] ${mode^}ing $title (staged)..."
        bash "$dir/dml-start.sh" "$mode"
        return
    fi

    _check_port_conflicts
    echo "[dml] ${mode^}ing $title..."
    if [[ "$mode" == "restart" ]]; then
        docker compose down
    fi
    docker compose up -d
    echo "[dml] $title started"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  doctor)
    echo "[dml] DML Doctor v$VERSION"
    errors=0
    warns=0

    _doctor_section "Linux environment"
    if systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"; then
        echo "[ok]  systemd is running"
    else
        echo "[WARN] systemd is not running -- from Windows: wsl --shutdown, then reopen"
        errors=$((errors + 1))
    fi

    if docker info &>/dev/null; then
        echo "[ok]  Docker Engine is running"
    else
        echo "[WARN] Docker is not responding -- try: sudo systemctl start docker"
        errors=$((errors + 1))
    fi

    if systemctl is-active dml-keepalive.service &>/dev/null; then
        echo "[ok]  dml-keepalive.service is active (WSL idle backup)"
    else
        echo "[WARN] dml-keepalive.service is not active -- WSL may idle-shutdown while playing"
        warns=$((warns + 1))
    fi

    free_kb=$(df /home --output=avail 2>/dev/null | tail -1 | tr -d ' ')
    if [[ "$free_kb" =~ ^[0-9]+$ ]]; then
        free_gb=$(( free_kb / 1024 / 1024 ))
        if (( free_gb >= 20 )); then
            echo "[ok]  Disk space: ${free_gb} GB free on ext4"
        else
            echo "[WARN] Low disk space: ${free_gb} GB free under /home (need 20+ GB)"
            errors=$((errors + 1))
        fi
    else
        echo "[WARN] Could not read disk space for /home"
        errors=$((errors + 1))
    fi

    if curl -fsS --max-time 5 https://www.google.com > /dev/null 2>&1; then
        echo "[ok]  Internet connection"
    else
        echo "[WARN] No internet connection detected"
        warns=$((warns + 1))
    fi

    _doctor_section "WSL stability (disconnects while playing)"
    wslconf=$(_wslconfig_path || true)
    if [[ -n "$wslconf" && -f "$wslconf" ]]; then
        echo "[ok]  .wslconfig found: $wslconf"
        if grep -qE 'instanceIdleTimeout=-1' "$wslconf" 2>/dev/null; then
            echo "[ok]  instanceIdleTimeout=-1 (distro idle disabled)"
        else
            echo "[WARN] instanceIdleTimeout not -1 -- WSL may shut down the distro after ~10 min idle"
            warns=$((warns + 1))
        fi
        if grep -qE 'vmIdleTimeout=-1' "$wslconf" 2>/dev/null; then
            echo "[ok]  vmIdleTimeout=-1 (VM idle disabled)"
        else
            echo "[WARN] vmIdleTimeout not -1 -- WSL VM may shut down after ~60s idle"
            warns=$((warns + 1))
        fi
        if grep -qE 'autoMemoryReclaim=gradual' "$wslconf" 2>/dev/null; then
            echo "[ok]  autoMemoryReclaim=gradual"
        else
            echo "[WARN] autoMemoryReclaim=gradual not set -- WSL may hold RAM when idle"
            warns=$((warns + 1))
        fi
    else
        echo "[WARN] .wslconfig not found -- re-run Install-DML.ps1 as Administrator"
        warns=$((warns + 1))
    fi

    if command -v journalctl &>/dev/null; then
        po_count=$(journalctl -b --no-pager 2>/dev/null | grep -c 'poweroff requested' || true)
        if (( po_count > 0 )); then
            echo "[WARN] $po_count unexpected WSL poweroff event(s) this boot -- check .wslconfig + keepalive"
            warns=$((warns + 1))
        else
            echo "[ok]  No unexpected WSL poweroff events this boot"
        fi
    fi

    if command -v powershell.exe &>/dev/null; then
        _doctor_section "Windows host + WSL"
        win_root_mnt=$(_win_to_mnt "$DML_WIN_ROOT")
        stopped_marker="$win_root_mnt/.dml-servers-stopped"
        wsl_ver=$(wsl.exe --version 2>&1 | tr -d '\0' | grep -i 'WSL version' | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '\r' || true)
        if [[ -n "$wsl_ver" ]]; then
            echo "[ok]  WSL version: $wsl_ver"
        else
            echo "[WARN] Could not read WSL version -- run: wsl --update"
            warns=$((warns + 1))
        fi
        wsl_line=$(wsl.exe -l -v 2>/dev/null | tr -d '\0' | grep -i 'dml-arch' | head -1 || true)
        if [[ "$wsl_line" == *Running* ]]; then
            echo "[ok]  WSL distro dml-arch: Running (Windows view)"
        elif [[ "$wsl_line" == *Stopped* ]]; then
            echo "[ok]  WSL distro dml-arch: Stopped (RAM released)"
            if docker ps -q 2>/dev/null | grep -q .; then
                echo "[WARN] dml-arch Stopped on Windows but Docker has containers -- stale state?"
                warns=$((warns + 1))
            fi
        else
            echo "[WARN] dml-arch not found in 'wsl -l -v' -- re-run Install-DML.ps1"
            warns=$((warns + 1))
        fi
        vmmem_mb=$(powershell.exe -NoProfile -Command \
            "\$p=Get-Process vmmem,VmmemWSL -EA SilentlyContinue | Select-Object -First 1; if(\$p){[math]::Round(\$p.WorkingSet64/1MB)}else{'0'}" \
            2>/dev/null | tr -d '\r\n')
        if [[ "$vmmem_mb" =~ ^[0-9]+$ ]]; then
            if (( vmmem_mb == 0 )); then
                echo "[ok]  Vmmem not active (WSL VM fully released)"
            elif [[ "$wsl_line" == *Stopped* ]] && (( vmmem_mb > 150 )); then
                echo "[WARN] Vmmem ${vmmem_mb} MB but dml-arch Stopped -- WSL VM still loaded; run: wsl --shutdown"
                warns=$((warns + 1))
            elif docker ps -q 2>/dev/null | grep -q .; then
                echo "[ok]  Vmmem RAM: ${vmmem_mb} MB (servers running)"
            elif [[ -f "$stopped_marker" ]] && (( vmmem_mb > 500 )); then
                echo "[WARN] Vmmem ${vmmem_mb} MB after intentional stop -- WSL woke (doctor/tray) -- re-releasing RAM..."
                warns=$((warns + 1))
                _release_wsl
            elif (( vmmem_mb > 500 )); then
                echo "[WARN] Vmmem ${vmmem_mb} MB with no containers -- tray: Stop WSL (release RAM), or: dml release-wsl"
                warns=$((warns + 1))
            else
                echo "[ok]  Vmmem RAM: ${vmmem_mb} MB"
            fi
        fi

        _doctor_section "Windows DML install ($DML_WIN_ROOT)"
        for script in WSL-Keepalive.ps1 DML-Ensure-Keepalive.ps1 DML-Release-WSL.ps1 DML-Launcher.exe dml-titles.cache; do
            if [[ -f "$win_root_mnt/$script" ]]; then
                echo "[ok]  $script present"
            else
                echo "[WARN] Missing $DML_WIN_ROOT\\$script -- re-run Install-DML.ps1"
                warns=$((warns + 1))
            fi
        done
        launcher_ver=$(grep -oE 'VERSION\s*=\s*"[0-9.]+"' "$win_root_mnt/DML-Launcher.cs" 2>/dev/null | head -1 | grep -oE '[0-9.]+' || true)
        if [[ -n "$launcher_ver" ]]; then
            echo "[ok]  DML Launcher source version: v$launcher_ver"
        fi
        if powershell.exe -NoProfile -Command 'Get-Process DML-Launcher -EA SilentlyContinue' &>/dev/null; then
            echo "[ok]  DML Launcher tray app is running"
        else
            echo "[WARN] DML Launcher is not running -- start $DML_WIN_ROOT\\DML-Launcher.exe"
            warns=$((warns + 1))
        fi
        legacy_vbs=$(powershell.exe -NoProfile -Command \
            "Test-Path (Join-Path \$env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs\\Startup\\DML-WSL-Keepalive.vbs')" \
            2>/dev/null | tr -d '\r\n')
        if [[ "$legacy_vbs" == "True" ]]; then
            echo "[WARN] Legacy always-on keepalive VBS in Startup -- remove or re-run Install-DML.ps1"
            warns=$((warns + 1))
        else
            echo "[ok]  No legacy always-on keepalive in Startup"
        fi
        if schtasks /Query /TN 'DML-WSL-Keepalive' &>/dev/null; then
            echo "[WARN] Legacy scheduled task DML-WSL-Keepalive exists -- re-run Install-DML.ps1 to remove"
            warns=$((warns + 1))
        fi

        _doctor_section "Windows keepalive + tray state"
        ka_count=$(powershell.exe -NoProfile -Command \
            "(Get-CimInstance Win32_Process -EA SilentlyContinue | Where-Object { \$_.CommandLine -match 'WSL-Keepalive|sleep.+infinity' }).Count" \
            2>/dev/null | tr -d '\r\n')
        if [[ "$ka_count" =~ ^[0-9]+$ ]] && (( ka_count > 0 )); then
            echo "[ok]  Windows WSL keepalive running ($ka_count process(es))"
        elif docker ps -q 2>/dev/null | grep -q .; then
            echo "[WARN] Game containers running but Windows keepalive is off -- WSL may idle-shutdown"
            warns=$((warns + 1))
        else
            echo "[ok]  Windows keepalive off (no game servers running)"
        fi
        if [[ -f "$stopped_marker" ]] && docker ps -q 2>/dev/null | grep -q .; then
            echo "[WARN] .dml-servers-stopped marker exists but containers are running -- tray may show Stopped"
            warns=$((warns + 1))
        elif [[ -f "$stopped_marker" ]]; then
            echo "[ok]  .dml-servers-stopped marker set (intentional stop / RAM released)"
        fi
        if [[ -f "$win_root_mnt/dml-titles.cache" ]]; then
            cache_lines=$(wc -l < "$win_root_mnt/dml-titles.cache" | tr -d ' ')
            echo "[ok]  dml-titles.cache: $cache_lines title(s) (tray uses when WSL is Stopped)"
        else
            echo "[WARN] dml-titles.cache missing -- tray may be empty after reboot; run 'dml list'"
            warns=$((warns + 1))
        fi
        win_ports=$(powershell.exe -NoProfile -Command \
            "(Get-NetTCPConnection -State Listen -EA SilentlyContinue | Where-Object { \$_.LocalPort -in 3724,8085 } | ForEach-Object { \$_.LocalPort }) -join ','" \
            2>/dev/null | tr -d '\r\n')
        if docker ps -q 2>/dev/null | grep -q .; then
            if [[ "$win_ports" == *3724* ]]; then
                echo "[ok]  Windows forwarding: port 3724 listening"
            else
                echo "[WARN] Port 3724 not listening on Windows -- WoW client may not connect"
                warns=$((warns + 1))
            fi
            if [[ "$win_ports" == *8085* ]]; then
                echo "[ok]  Windows forwarding: port 8085 listening"
            else
                echo "[WARN] Port 8085 not listening on Windows"
                warns=$((warns + 1))
            fi
        fi
    else
        _doctor_section "Windows host"
        echo "[INFO] powershell.exe unavailable -- skipping Windows checks (not WSL-on-Windows?)"
    fi

    _doctor_section "Installed titles"
    title_count=0
    running_count=0
    if [[ -d "$GAMES_DIR" ]]; then
        for dir in "$GAMES_DIR"/*/; do
            [[ -d "$dir" ]] || continue
            title=$(basename "$dir")
            compose_dir="$dir"
            if ! _has_compose "$dir"; then
                for subdir in "$dir"*/; do
                    [[ -d "$subdir" ]] && _has_compose "$subdir" && compose_dir="$subdir" && break
                done
            fi
            [[ -d "$compose_dir" ]] && _has_compose "$compose_dir" || continue
            title_count=$((title_count + 1))
            rc=$(_compose_running "$compose_dir")
            if (( rc > 0 )); then
                running_count=$((running_count + 1))
                echo "[ok]  $title: running ($rc container(s))"
            else
                echo "[ok]  $title: stopped"
            fi
            if [[ -x "$dir/dml-start.sh" ]]; then
                echo "[ok]    dml-start.sh present (safe restart)"
            elif [[ -f "$dir/dml-start.sh" ]]; then
                echo "[WARN]  $title: dml-start.sh not executable"
                warns=$((warns + 1))
            else
                echo "[WARN]  $title: no dml-start.sh -- 'dml restart' may re-import DB (WoW/AzerothCore)"
                warns=$((warns + 1))
            fi
            if [[ -x "$dir/wow-manage.sh" ]]; then
                echo "[ok]    wow-manage.sh present (module manager)"
            elif [[ -f "$dir/wow-manage.sh" ]]; then
                echo "[WARN]  $title: wow-manage.sh not executable"
                warns=$((warns + 1))
            elif [[ -x "$dir/dml-start.sh" ]]; then
                _sync_missing_wow_hooks "$dir"
                if [[ -x "$dir/wow-manage.sh" ]]; then
                    echo "[ok]    wow-manage.sh installed (fetched from repo)"
                else
                    echo "[WARN]  $title: no wow-manage.sh -- tray Manage menu unavailable"
                    warns=$((warns + 1))
                fi
            fi
        done
    fi
    if (( title_count == 0 )); then
        echo "[INFO] No installed titles with compose files"
    fi

    if (( running_count > 0 )); then
        if ss -tln 2>/dev/null | grep -q ':3724 '; then
            echo "[ok]  WoW auth port 3724 listening"
        else
            echo "[WARN] Containers running but port 3724 not listening yet"
            warns=$((warns + 1))
        fi
        if ss -tln 2>/dev/null | grep -q ':8085 '; then
            echo "[ok]  WoW world port 8085 listening"
        else
            echo "[WARN] Containers running but port 8085 not listening yet"
            warns=$((warns + 1))
        fi
    fi

    echo ""
    if (( errors == 0 && warns == 0 )); then
        echo "[ok]  All checks passed."
    elif (( errors == 0 )); then
        echo "[dml] $warns warning(s), 0 critical issue(s). Share this output if you need help."
    else
        echo "[dml] $errors critical issue(s), $warns warning(s)."
    fi
    ;;

  list)
    if [[ ! -d "$GAMES_DIR" ]]; then
        echo "[dml] No titles installed yet. Run 'dml run <url>' to install one."
        exit 0
    fi
    found=0
    declare -A _list_seen
    for dir in "$GAMES_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        title=$(basename "$dir")
        if _has_compose "$dir" || [[ -f "$dir/install.sh" ]]; then
            echo "$title"
            found=$((found + 1))
            _list_seen["$title"]=1
        else
            for subdir in "$dir"*/; do
                [[ -d "$subdir" ]] || continue
                [[ -n "${_list_seen[$title]:-}" ]] && continue
                if _has_compose "$subdir" || [[ -f "$subdir/install.sh" ]]; then
                    echo "$title"
                    found=$((found + 1))
                    _list_seen["$title"]=1
                    break
                fi
            done
        fi
    done
    if [[ $found -eq 0 ]]; then
        echo "[dml] No titles found in $GAMES_DIR"
    fi
    ;;

  status)
    target="${1:-}"
    if [[ -n "$target" ]]; then
        dir="$GAMES_DIR/$target"
        if [[ ! -d "$dir" ]]; then echo "not-found"; exit 1; fi
        compose_dir="$dir"
        if ! _has_compose "$dir"; then
            for subdir in "$dir"*/; do
                if [[ -d "$subdir" ]] && _has_compose "$subdir"; then
                    compose_dir="$subdir"; break
                fi
            done
        fi
        if _has_compose "$compose_dir"; then
            count=$(_compose_running "$compose_dir")
            if [[ "$count" -gt 0 ]]; then echo "running"; else echo "stopped"; fi
        else
            echo "stopped"
        fi
    else
        [[ ! -d "$GAMES_DIR" ]] && exit 0
        declare -A _seen
        for dir in "$GAMES_DIR"/*/; do
            [[ -d "$dir" ]] || continue
            title=$(basename "$dir")
            if _has_compose "$dir"; then
                count=$(_compose_running "$dir")
                if [[ "$count" -gt 0 ]]; then echo "$title:running"; else echo "$title:stopped"; fi
                _seen["$title"]=1
            else
                # One level deeper -- catches repos with compose file in a subdirectory
                for subdir in "$dir"*/; do
                    [[ -d "$subdir" ]] || continue
                    _has_compose "$subdir" || continue
                    [[ -n "${_seen[$title]:-}" ]] && continue
                    count=$(_compose_running "$subdir")
                    if [[ "$count" -gt 0 ]]; then echo "$title:running"; else echo "$title:stopped"; fi
                    _seen["$title"]=1
                    break
                done
            fi
        done
        # Fallback: catch running Compose projects not found by directory scan
        while IFS= read -r project; do
            [[ -z "$project" ]] && continue
            [[ -n "${_seen[$project]:-}" ]] && continue
            echo "$project:running"
        done < <(docker ps --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null | sort -u | grep -v '^$')
    fi
    ;;

  start)
    title="${1:?Usage: dml start <title>}"
    _start_title "$title" start
    ;;

  restart)
    title="${1:?Usage: dml restart <title>}"
    _start_title "$title" restart
    ;;

  restart-active)
    echo "[dml] Restarting active server(s)..."
    _restart_all_running_titles || exit 1
    ;;

  stop)
    title="${1:?Usage: dml stop <title>}"
    if [[ -x "$GAMES_DIR/$title/dml-stop.sh" ]]; then
      bash "$GAMES_DIR/$title/dml-stop.sh"
    else
      _stop_title_graceful "$title" || exit 1
    fi
    running=$(docker ps -q 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ "$running" -eq 0 ]]; then
      echo "[dml] No servers running -- releasing WSL memory to Windows..."
      _release_wsl
    fi
    ;;

  release-wsl)
    echo "[dml] Stopping any running game servers cleanly..."
    _stop_all_running_titles
    remaining=$(docker ps -q 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ "$remaining" -gt 0 ]]; then
        echo "[WARN] $remaining container(s) still running -- stopping..."
        docker ps -q 2>/dev/null | xargs docker stop 2>/dev/null || true
    fi
    echo "[dml] Shutting down WSL and returning RAM to Windows..."
    _release_wsl
    echo "[dml] Scheduled -- Vmmem should drop in a few seconds."
    echo "[dml] Use 'dml start <title>' when you want to play again."
    ;;

  scan)
    _require_docker
    echo "[dml] Scanning for all running containers in dml-arch..."
    echo ""

    total=$(docker ps -q 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ "$total" -eq 0 ]]; then
        echo "[dml] No running containers found."
        exit 0
    fi

    declare -A _known_ports
    _known_ports["3306"]="MySQL/MariaDB"
    _known_ports["3724"]="WoW auth/login"
    _known_ports["8085"]="WoW world server"
    _known_ports["8086"]="WoW SOAP API"
    _known_ports["4000"]="EQ zone (EQEmu)"
    _known_ports["5998"]="EQ login (EQEmu)"
    _known_ports["5999"]="EQ login (EQEmu)"
    _known_ports["9000"]="EQ world (EQEmu)"
    _known_ports["2593"]="Ultima Online"
    _known_ports["7171"]="Tibia"
    _known_ports["6112"]="Blizzard legacy"
    _known_ports["43594"]="RuneScape (RSPS)"
    _known_ports["2106"]="Lineage II login"
    _known_ports["7777"]="Lineage II game"
    _known_ports["54230"]="FFXI auth"
    _known_ports["54231"]="FFXI game"
    _known_ports["44453"]="SWG login"
    _known_ports["44462"]="SWG connection"

    prev_project="__unset__"
    while IFS='|' read -r cid cname project; do
        if [[ "$project" != "$prev_project" ]]; then
            [[ "$prev_project" != "__unset__" ]] && echo ""
            if [[ -z "$project" ]]; then
                echo "[ standalone containers -- no compose project ]"
            else
                echo "[ project: $project ]"
            fi
            prev_project="$project"
        fi
        printf "  %-40s  %s\n" "$cname" "$cid"
        while IFS= read -r pline; do
            [[ -z "$pline" ]] && continue
            hostport=$(echo "$pline" | grep -oE ':[0-9]+$' | tr -d ':')
            note="${_known_ports[$hostport]:-}"
            if [[ -n "$note" ]]; then
                printf "    %-36s  [%s]\n" "$pline" "$note"
            else
                printf "    %s\n" "$pline"
            fi
        done < <(docker port "$cid" 2>/dev/null)
    done < <(docker ps --format '{{.ID}}|{{.Names}}|{{index .Labels "com.docker.compose.project"}}' \
             2>/dev/null | sort -t'|' -k3)

    echo ""
    echo "[dml] To stop a project: dml kill <project-name>  or  dml kill --all"
    ;;

  kill)
    _require_docker
    target="${1:-}"
    if [[ -z "$target" ]]; then
        echo "[dml] Usage: dml kill <project-name> | --all" >&2
        exit 1
    fi

    if [[ "$target" == "--all" ]]; then
        running=$(docker ps -q 2>/dev/null)
        if [[ -z "$running" ]]; then
            echo "[dml] No running containers to stop."
            exit 0
        fi
        count=$(echo "$running" | wc -l | tr -d '[:space:]')
        echo "[dml] Stopping $count running container(s)..."
        echo "$running" | xargs docker stop 2>/dev/null || true
        echo "$running" | xargs docker rm -f 2>/dev/null || true
        docker network prune -f 2>/dev/null || true
        echo "[ok]  All containers stopped, removed, and orphaned networks pruned."
    else
        # Find containers by project label -- works with any compose version, no directory needed
        containers=$(docker ps -q --filter "label=com.docker.compose.project=$target" 2>/dev/null)
        if [[ -z "$containers" ]]; then
            echo "[dml] ERROR: No running containers found for project '$target'." >&2
            echo "[dml]   Run 'dml scan' to see what is currently running." >&2
            exit 1
        fi
        count=$(echo "$containers" | wc -l | tr -d '[:space:]')
        echo "[dml] Stopping $count container(s) for project '$target'..."
        echo "$containers" | xargs docker stop 2>/dev/null || true
        # Compose down cleans up networks and volumes; fall back to direct rm if unavailable
        if ! docker compose -p "$target" down 2>/dev/null; then
            echo "$containers" | xargs docker rm -f 2>/dev/null || true
        fi
        echo "[ok]  '$target' stopped."
    fi
    ;;

  clean)
    _require_docker
    yes_flag="${1:-}"
    _confirm() {
        local prompt="$1" ans
        if [[ "$yes_flag" == "--yes" ]]; then return 0; fi
        read -rp "    $prompt [y/N] " ans
        [[ "$ans" =~ ^[Yy] ]]
    }

    echo "[dml] Running DML cleanup..."
    echo ""

    # 1. Stop DML-managed containers (compose-project containers only; standalone containers not touched)
    running=$(docker ps -q --filter "label=com.docker.compose.project" 2>/dev/null)
    if [[ -n "$running" ]]; then
        count=$(echo "$running" | wc -l | tr -d '[:space:]')
        echo "[dml] $count Docker Compose container(s) found:"
        docker ps --filter "label=com.docker.compose.project" \
            --format '  {{.Names}}  (project: {{index .Labels "com.docker.compose.project"}})' 2>/dev/null
        echo ""
        echo "  Note: standalone containers not part of a compose project are not affected."
        echo ""
        if _confirm "Stop these containers?"; then
            echo "$running" | xargs docker stop 2>/dev/null || true
            echo "$running" | xargs docker rm -f 2>/dev/null || true
            echo "[ok]  Containers stopped."
        fi
    else
        echo "[ok]  No running Docker Compose containers found."
    fi
    echo ""

    # 2. Identify and optionally remove incomplete install directories
    if [[ -d "$GAMES_DIR" ]]; then
        echo "[dml] Checking $GAMES_DIR for incomplete installs..."
        declare -a incomplete
        for dir in "$GAMES_DIR"/*/; do
            [[ -d "$dir" ]] || continue
            if ! _has_compose "$dir" && [[ ! -f "$dir/install.sh" ]]; then
                found_nested=0
                for subdir in "$dir"*/; do
                    if [[ -d "$subdir" ]] && ( _has_compose "$subdir" || [[ -f "$subdir/install.sh" ]] ); then
                        found_nested=1; break
                    fi
                done
                [[ $found_nested -eq 0 ]] && incomplete+=("$dir")
            fi
        done

        if [[ ${#incomplete[@]} -gt 0 ]]; then
            echo "[dml] Incomplete directories (no compose file or install.sh found):"
            for d in "${incomplete[@]}"; do echo "    $(basename "$d")  ($d)"; done
            echo ""
            if _confirm "Remove these directories?"; then
                for d in "${incomplete[@]}"; do
                    [[ -z "$d" ]] && continue
                    rm -rf "$d" && echo "[ok]  Removed: $(basename "$d")"
                done
            fi
        else
            echo "[ok]  No incomplete install directories found."
        fi
    fi
    echo ""

    # 3. Docker prune
    dangling=$(docker images -f dangling=true -q 2>/dev/null | wc -l | tr -d '[:space:]')
    stopped_ct=$(docker ps -a -q --filter status=exited 2>/dev/null | wc -l | tr -d '[:space:]')
    echo "[dml] Docker: $dangling dangling image(s), $stopped_ct exited container(s)."
    if [[ "$dangling" -gt 0 || "$stopped_ct" -gt 0 ]]; then
        if _confirm "Run docker system prune? Warning: removes ALL unused Docker resources system-wide, not just DML ones."; then
            docker system prune -f
            echo "[ok]  Docker pruned."
        fi
    else
        echo "[ok]  Docker is already clean."
    fi
    echo ""
    echo "[ok]  Cleanup complete."
    ;;

  shell)
    exec bash --login
    ;;

  run)
    target="${1:?Usage: dml run <git-url|local-path>}"
    _require_docker
    mkdir -p "$GAMES_DIR"

    if [[ "$target" == /* ]]; then
        if [[ ! -d "$target" ]]; then
            echo "[dml] ERROR: Local path not found: $target" >&2; exit 1
        fi
        repo_name=$(basename "$target")
        clone_dir="$GAMES_DIR/$repo_name"
        if [[ -d "$clone_dir" ]]; then
            echo "[dml] $repo_name already exists in games dir -- skipping copy"
        else
            echo "[dml] Copying $target -> $clone_dir ..."
            cp -r "$target" "$clone_dir"
        fi
    else
        repo_name=$(basename "$target" .git)
        clone_dir="$GAMES_DIR/$repo_name"
        if [[ -d "$clone_dir/.git" ]]; then
            echo "[dml] $repo_name already cloned -- pulling latest"
            git -C "$clone_dir" pull
        else
            echo "[dml] Cloning $target ..."
            git clone "$target" "$clone_dir"
        fi
    fi

    entrypoint="install.sh"
    if [[ -f "$clone_dir/dml.manifest" ]]; then
        declared=$(jq -r '.entrypoint // empty' "$clone_dir/dml.manifest" 2>/dev/null || true)
        [[ -n "$declared" ]] && entrypoint="$declared"
    fi

    if [[ ! -f "$clone_dir/$entrypoint" ]]; then
        echo "[dml] ERROR: $entrypoint not found in $repo_name" >&2
        echo "[dml] This repo may not follow the DML convention (install.sh at root)." >&2
        exit 1
    fi

    echo "[dml] Starting $entrypoint from $repo_name ..."
    cd "$clone_dir"
    exec bash "$entrypoint"
    ;;

  lan)
    # dml lan <title> on <ip> | off | status | refresh <ip>
    #
    # LAN play = point the realm's advertised address at the Windows host's
    # LAN IP so other PCs on the home network can reach the world server.
    # The Windows side (portproxy + firewall, set up by Install-DML.ps1)
    # carries LAN traffic to 127.0.0.1; this command only flips the address
    # the auth server hands to clients (acore_auth.realmlist).
    #
    # Messages go to STDOUT even on failure -- the DML Launcher tray only
    # captures stdout, and these are user-facing results, not diagnostics.
    title="${1:-}"
    action="${2:-}"
    lan_usage="[dml] Usage: dml lan <title> on <lan-ip> | off | status | refresh <lan-ip>"
    if [[ -z "$title" || -z "$action" ]]; then echo "$lan_usage"; exit 1; fi

    # Validate arguments up front -- the database wait below can take a
    # while, and a usage mistake should fail instantly, not after it.
    ip="${3:-}"
    case "$action" in
      on|refresh)
        if [[ -z "$ip" ]]; then echo "$lan_usage"; exit 1; fi ;;
      off|status) ;;
      *) echo "$lan_usage"; exit 1 ;;
    esac

    dir="$GAMES_DIR/$title"
    if [[ ! -d "$dir" ]]; then echo "[dml] ERROR: Title not found: $title"; exit 1; fi
    compose_dir="$dir"
    if ! _has_compose "$dir"; then
        for subdir in "$dir"*/; do
            if [[ -d "$subdir" ]] && _has_compose "$subdir"; then
                compose_dir="$subdir"; break
            fi
        done
    fi
    if ! _has_compose "$compose_dir"; then
        echo "[dml] ERROR: No compose file found in $title or its subdirectories."; exit 1
    fi
    _require_docker
    cd "$compose_dir"

    # Only AzerothCore-family titles are supported: they expose an
    # 'ac-database' service and store the advertised address in
    # acore_auth.realmlist.
    if ! docker compose config --services 2>/dev/null | grep -qx 'ac-database'; then
        echo "[dml] LAN play is not supported for '$title' yet."
        echo "[dml] (Currently supported: AzerothCore-based servers like WoW WotLK Playerbots.)"
        exit 1
    fi
    db=$(docker compose ps -q ac-database 2>/dev/null | head -1 || true)
    if [[ -z "$db" ]]; then
        echo "[dml] ERROR: '$title' is not running. Start the server first, then change LAN settings."
        exit 1
    fi

    _lan_sql() { docker exec "$db" mysql -uroot -ppassword acore_auth -sN -e "$1" 2>/dev/null; }

    # The database can lag the containers (first boot imports take a while).
    # 'refresh' is fired automatically by the tray right after 'dml start',
    # so it gets a long budget; interactive actions get a short one.
    if [[ "$action" == "refresh" ]]; then _lan_tries=60; _lan_gap=10; else _lan_tries=18; _lan_gap=5; fi
    _n=0
    until _lan_sql "SELECT 1" >/dev/null 2>&1; do
        _n=$((_n + 1))
        if (( _n >= _lan_tries )); then
            echo "[dml] ERROR: The realm database is not answering yet. Wait for the server to finish starting, then try again."
            exit 1
        fi
        sleep "$_lan_gap"
    done

    _lan_set() {
        local ip="$1" newaddr
        if [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "[dml] ERROR: '$ip' does not look like an IPv4 address."; exit 1
        fi
        if ! _lan_sql "UPDATE realmlist SET address='$ip' WHERE id=1;"; then
            echo "[dml] ERROR: Could not update the realm address."; exit 1
        fi
        # Read back what actually landed: an UPDATE that matches no row
        # (realm id != 1) still exits 0, and reporting success on a no-op
        # would leave the user chasing ghosts on the other PCs.
        newaddr=$(_lan_sql "SELECT address FROM realmlist WHERE id=1;" || true)
        if [[ "$newaddr" != "$ip" ]]; then
            echo "[dml] ERROR: The realm address did not change (no realm with id 1?)."
            echo "[dml]   Wanted '$ip' but the database says '${newaddr:-nothing}'."
            exit 1
        fi
    }

    current=$(_lan_sql "SELECT address FROM realmlist WHERE id=1;" || true)
    case "$action" in
      on)
        _lan_set "$ip"
        echo "[ok] LAN play ENABLED for $title."
        echo ""
        echo "Other PCs on your network: set realmlist $ip"
        echo "(in realmlist.wtf inside the WoW client folder)"
        echo ""
        echo "This PC keeps working with 127.0.0.1 or $ip -- both reach the server."
        ;;
      off)
        _lan_set "127.0.0.1"
        echo "[ok] LAN play DISABLED for $title."
        echo "The server only accepts world connections from this PC again."
        ;;
      status)
        if [[ -z "$current" ]]; then
            echo "[dml] ERROR: Could not read the realm address from the database."
            exit 1
        elif [[ "$current" == "127.0.0.1" ]]; then
            echo "LAN play: OFF (realm address 127.0.0.1 -- this PC only)"
        else
            echo "LAN play: ON  (realm address $current)"
            echo "Other PCs use: set realmlist $current"
        fi
        ;;
      refresh)
        # Re-point an already-LAN-enabled realm at the host's current IP
        # (DHCP can hand the PC a new address between sessions). No-op when
        # LAN play is off. Called automatically by the tray after each start.
        if [[ -z "$current" || "$current" == "127.0.0.1" ]]; then
            echo "[dml] LAN play is off for $title -- nothing to refresh."
            exit 0
        fi
        if [[ "$current" == "$ip" ]]; then
            echo "[ok] LAN address already current ($ip)."
            exit 0
        fi
        # Only rewrite private (LAN) addresses. A public IP means the user
        # set up internet hosting by hand -- clobbering it with the LAN IP
        # on every start would silently lock their friends out.
        if [[ ! "$current" =~ ^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
            echo "[dml] Realm address $current is not a LAN address -- leaving it alone."
            exit 0
        fi
        _lan_set "$ip"
        echo "[ok] LAN address refreshed: $current -> $ip"
        ;;
      *)
        echo "$lan_usage"; exit 1
        ;;
    esac
    ;;

  version)
    echo "dml v$VERSION"
    ;;

  help|--help|-h)
    echo "dml -- Dad's MMO Lab CLI v$VERSION"
    echo ""
    echo "Commands:"
    echo "  doctor                diagnose Linux + Windows/WSL issues (idle shutdown, tray, RAM)"
    echo "  list                  list installed titles"
    echo "  status [<title>]      show running/stopped status (all titles if no arg)"
    echo "  start <title>         start a title's Docker server"
    echo "  restart <title>       restart a title (uses dml-start.sh if present)"
    echo "  restart-active        restart all currently running titles"
    echo "  stop <title>          stop a title; releases WSL RAM if no servers left"
    echo "  release-wsl           compose-down all titles, then shut down WSL (frees Vmmem RAM)"
    echo "  lan <title> <action>  LAN play: on <lan-ip> | off | status | refresh <lan-ip>"
    echo "  scan                  show all running containers and which game ports they hold"
    echo "  kill <name|--all>     force-stop by project name (no directory needed)"
    echo "  clean [--yes]         stop stuck containers, remove incomplete installs, prune Docker"
    echo "  shell                 open an interactive shell"
    echo "  run <url|path>        install a title from GitHub URL or local folder"
    echo "  version               print version"
    echo ""
    echo "Game data lives in /home/dml/ (ext4), never /mnt/c."
    ;;

  *)
    echo "[dml] Unknown command: $cmd" >&2
    echo "Run 'dml help' for usage." >&2
    exit 1
    ;;
esac
'@

        # Convert CRLF -> LF before encoding so the installed script has Unix line endings
        # Substitute __DML_INSTALL_ROOT__ and __DML_CLI_VERSION__ placeholders
        $DmlCliWinRoot  = ($InstallRoot -replace '\\', '/')
        $DmlCliResolved = $DmlCli.Replace('__DML_INSTALL_ROOT__', $DmlCliWinRoot).Replace('__DML_CLI_VERSION__', $DmlCliVersion).Replace("`r`n", "`n")
        $DmlCliBytes = [System.Text.Encoding]::UTF8.GetBytes($DmlCliResolved)
        $DmlCliB64   = [Convert]::ToBase64String($DmlCliBytes)

        $exit10 = Invoke-WslBash -Distro $DmlDistroName -User root -Label 'phase3' -Script @"
set -euo pipefail
echo "[phase3] Installing core dependencies..."
pacman -S --noconfirm --needed base-devel git curl jq

echo "[phase3] Installing dml CLI..."
printf '%s' '$DmlCliB64' | base64 -d > /usr/local/bin/dml
chmod 0755 /usr/local/bin/dml

echo "[phase3] Verifying dml CLI..."
dml version
dml status >/dev/null 2>&1 || true

echo "[phase3] Installing Linux keepalive service (backup alongside vmIdleTimeout=-1)..."
cat > /usr/local/bin/dml-keepalive.sh << 'KEEPEOF'
#!/usr/bin/env bash
set -euo pipefail
while true; do sleep 3600; done
KEEPEOF
chmod 0755 /usr/local/bin/dml-keepalive.sh
cat > /etc/systemd/system/dml-keepalive.service << 'KEEPEOF'
[Unit]
Description=DML WSL keepalive (prevents vm idle poweroff)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/dml-keepalive.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
KEEPEOF
systemctl daemon-reload
systemctl enable --now dml-keepalive.service

echo "[phase3] Done"
"@
        if ($exit10 -ne 0) {
            Write-Fail "Phase 3 bootstrap failed (exit $exit10).`nCheck the log: $LogFile"
        }
        Write-Ok "Core dependencies and dml CLI installed"
        Mark-StepDone 'phase3-bootstrap'
    }

    # -------------------------------------------------------------------------
    # Step 10.5: Migrate legacy server directories into games/
    #
    # Early WoW installers placed servers directly in /home/dml; the dml CLI
    # only scans /home/dml/games, so those servers are invisible to the tray.
    # Install-WoW-WotLK.ps1 gained its own migration in v1.1, but users who
    # only re-run THIS installer (e.g. to get LAN play) need it here too.
    # Runs every time; does nothing once no compose-bearing directory sits
    # directly in /home/dml. Moving is safe even for a mid-flight server:
    # the compose project name comes from the directory basename, which the
    # move preserves -- but we still skip running servers to be conservative.
    # -------------------------------------------------------------------------
    Write-Step "Checking for servers installed at legacy paths..."
    $exitMigrate = Invoke-WslBash -Distro $DmlDistroName -User dml -Label 'migrate-legacy' -Script @'
set -euo pipefail
GAMES=/home/dml/games
mkdir -p "$GAMES"
found=0
for dir in /home/dml/*/; do
    [[ -d "$dir" ]] || continue
    name=$(basename "$dir")
    [[ "$name" == "games" ]] && continue
    compose_file=""
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$dir/$f" ]] && compose_file="$dir/$f" && break
    done
    [[ -z "$compose_file" ]] && continue
    found=$((found+1))
    if [[ -e "$GAMES/$name" ]]; then
        echo "[migrate] '$name' exists at BOTH /home/dml/$name and games/$name -- not moving."
        echo "[migrate]   The copy in games/ is the one DML manages; remove the legacy one manually."
        continue
    fi
    if docker compose -f "$compose_file" ps -q 2>/dev/null | grep -q .; then
        echo "[migrate] '$name' has running containers -- stop it, then re-run this installer to migrate it."
        continue
    fi
    mv "$dir" "$GAMES/$name"
    echo "[migrate] Moved legacy server '$name' into games/ -- it will now appear in the DML Launcher."
done
[[ $found -eq 0 ]] && echo "[migrate] No legacy server directories found -- nothing to do."
exit 0
'@
    if ($exitMigrate -ne 0) {
        Write-Warn "Legacy server migration hit a problem (exit $exitMigrate) -- a server may not show in the tray."
        Write-Warn "Check the log: $LogFile"
    }

    # -------------------------------------------------------------------------
    # Step 11: Compile DML Launcher (Windows system tray app)
    # Uses csc.exe from .NET Framework 4.8 -- pre-installed on Windows 10/11.
    # Output: $InstallRoot\DML-Launcher.exe + Desktop shortcut + startup shortcut.
    # -------------------------------------------------------------------------
    # Always write the icon so re-runs and upgrades pick it up
    $LauncherDir = $InstallRoot
    New-Item -ItemType Directory -Force -Path $LauncherDir | Out-Null
    # Write bundled icon (base64-encoded dml.ico)
            $IcoPath = "$LauncherDir\dml.ico"
            $IcoB64  = 'AAABAAkAICAQAAEABADoAgAAlgAAABAQEAABAAQAKAEAAH4DAAAwMAAAAQAIAKgOAACmBAAAICAAAAEACACoCAAAThMAABAQAAABAAgAaAUAAPYbAAAAAAAAAQAgAK2/AABeIQAAMDAAAAEAIACoJQAAC+EAACAgAAABACAAqBAAALMGAQAQEAAAAQAgAGgEAABbFwEAKAAAACAAAABAAAAAAQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAIAAAACAgACAAAAAgACAAICAAACAgIAAAAD/AAD/AAAA//8A/wAAAP8A/wD//wAAwMDAAP///wAAAAAAAAAADgAAAAAAAAAAAAAAAAAAAA5wAAAAAAAAAAAAAAAAAA5+fnAAAAAAAAAAAAAAAHdCUGBgdwAAAAAAAAfgDmdDQHQ0AwZH4A7gAAAH7md0dGR0RlZWV3Z/cAAAB353RnR2dnB2RnR353AAAAd3Vnd2ZGRkZGdGdldwAAAFdna+d3c3Q3E3dndnYAAAB2fmfmc4dUN4d2RHd3AAAAdnR7fnp6NzejV2VnRwAAAHR0ftd3OlSnrodkZXUAAAd3du7nroo0qKp2dmdncAAHNH59d+qKd6qnhlZ7dXAAA3e353eqOo4zp6ZHdjZwAAdWZ+t3qHOqh66lZnZHcAABZH1lc6Nzejd6d3tnRXcAB3R3fmo6dzOHOj53Z2d3AAN2vmd6h2ejVnqHR2VjcAAHVndnejd3c3d6Omd3Q1AABzR2V3o3d3NnWjhmdkdwAAd1Z2ajh3d3V2OlVkBwcAAAc0d1qnbnd25zoxdkNAAAAHN2c6eH7uZ+s6eGBDcAAAAFd2en5+7u3nd6dxB3AAAAB3NX7u7+/u7mZWFgcAAAAAd3N27//v7u52RAfnAAAAAHd353fv7+7nYXZ3dwAAAAAAAHd3ZWd2Vld3AAAAAAAAAAAHd3d3dHd2cAAAAAAAAAAAAAB3d3d34AAAAAAAAAAAAAAAAAAAAAAAAAAAAP/+/////n////gf///AA//mAABn4AAAB+AAAAfgAAAH4AAAB+AAAAfgAAAH4AAAB8AAAAPAAAADwAAAA8AAAAPAAAABwAAAAcAAAAPAAAADwAAAA8AAAAPgAAAH4AAAB/AAAAfwAAAP8AAAD/AAAA//AAD//4AB///wB///////KAAAABAAAAAgAAAAAQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAIAAAACAgACAAAAAgACAAICAAACAgIAAAAD/AAD/AAAA//8A/wAAAP8A/wD//wAAwMDAAP///wAAAAAOAAAAAAAAAHd3AAAAAOd0YWBWfgAAd1Z7ZHZ3AAd2dzdTdHdwB3Z+c3p1Z3AHd+eoejZ0cAdOdzo6d2RwBWZaNzc3dnAHZ3p3N6V0cAVnc3d1o2RwDjc3fmdzQ3AAd37u7ncHAAB3fu/nZHcAAAB3d3d3AAAAAAAH4AAAAP7////8P///wAP//8AD//+AAf//gAH//4AB//+AAf//gAH//4AB//+AAf//gAH//8AD///AA///8A////5///8oAAAAMAAAAGAAAAABAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACcXEwA0HhgAOSQaACMdKAAqJioAPCchAC0rNQAyLDQANTM4AEkoCwBWJwcAWzgOAEcqEwBULxQATjIXAFc3FgBkPA8AcD8MAGE9GwBDLCMASTQoAFc7KQBIOjUAVj41AGA+IwBcQxwAdksEAGZCGgB2ShoAf1AeAE1ALgBdQisASUU7AFpDNQBJUDsAXVY9AGdHJwB0TCQAbFEsAHpSKABlSTgAalM4AHhWNwB6ZToAOztIAEU8QgBGNnMAPUpZADdhVAA3UWwAN2xzAElISQBWSEcATVlIAFZXRABJSlYAVU5XAEZSVwBXVVkAaktAAHRNRABqVEcAeFZHAGVYVQB3W1QAUmRWAG9iTgB8YUYAa2VVAHpjWgBzdlwAUFdmAGBeYQBlXWEAUGhwAGZmaQByZ2cAf3JlAGZodgBnd3wAd3Z2AIFRHQCBTyEAiFkoAJFdJgCEWzQAjmIuAJVkLQCIYjkAlmg2AKJtNgCmdD8Agl9RAIllSACUbEMAmHNJAIdnVgCSb1oAh3FYAJl2VwCkeEgAo31VAIdrZACId2oAlnZoAIp5dQCYenIAp3lgACeBdwB2gXcAqINaALKIWgCGgGoAiYZ8AJqBewCpiGYAs4tjAKyQYgC4k2kAooV6AKuSdwC4mHYAwpt2AMOhfAAnMpMAPzuiACJOngAnUZ4AMXCQAC1JqAAkUqEAJ0y9ADZEvgA0WroAKGijADpopAAjc6kALGu0ADZrtQAodLYAS3OLAGlyhwBIXLMAGFbBACxWwgAYbscAHnTHACdyzgAal5wAKZWYAByOtwAlm6UALoq1ADeCtgAXqa8AKq23ADiotgBVio0AaoOGAHqDgwBggZAAdYKTAEuOsABVgrEAbYyoAEumqABdobIAaKmqAByFxAAZkssAGozUABiW1wAlh8wANobHACKXzgA3k8oAIorTADOE2AApldUAMZvSABGv0gAooM8ALLjIACOl1QAzpdQALrfZADa41wAOtuMARZjKAFKnyABEvM0ASafWAFOp2ABFuNYAWL3TAHCw0wBGsuUAdrzoAA3L2QAv0dwABdLlACXL4AAj2OMANNPnADbe8AA65O8AS87aAErY6QBt2eUASeDsAHPl7QCJh4YAlYqHAIWIlQCLlpUAlZGaAKWKgwCplIwAt5qEAK+XkgCwmpQAvKSLALqlmACJj6QAmq2iAImmsQCxrKEApqKzAMWoiADSr4IAxKyVAMmymADRt5oAyralANW9qADAurIA3MarAM3AswDYyLgA6s+kAObTtQCht80AnMjWAK7T2gC84+cA2c7GANrSygDP1dIA49bIAOfd1QDr49sA7+rnAL+x/wDa0f8A////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA3wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADZ6WkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADe8T9iAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGvo+dnveNoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA2UEiPtl4PnNFRT4YQdkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANsAAAAA2wAAAGcpIBQGFQEBAgEDARQGFCA8ZwAAANsAAAAA2wAAAAAAAAAAAAAAc/B4AABz7109PykVBgYVFRYVFhYVBhQVBgYVKT89Xe94AABr8HMAAAAAAAAAAAAAafF4Z9pn+WxEKRUiKRYXGCIYKRYgGCIXFikiFSlEbPln2md48WkAAAAAAAAAAAAAa/Hu6F7ZYl1hIiI/ICUODh0lHBkTEA4OJSA/IiJhXWLZXufu8WsAAAAAAAAAAAAAYeTv+ONdIAY9PVkTHVRVV1dWWlpWEyZUVB0TWTw/BiBd4/jv5F0AAAAAAAAAAAAAP9TWcV4/ZF48JmZUVVVYW1xbW1cMEA8PGVVSViU8XmQ/XmrW1F0AAAAAAAAAAAB4Z+E+YmQpXWFW5eh3W1hbWltYHh0cHBwlJVdaWlpWYV0pZGk+4Wd4AAAAAAAAAABpPZ9eRGxiXlZbe3tiaSAgJSAlExEZIB8fBU5jXmVaVF5ebERenz1nAAAAAAAAAAB4PUVsZkZhJWVwd3BMroCAg4CLRR03roCAg4CLoB4mExZhRmZsRT14AAAAAAAAAAAAP2E82+pGKeZwZXtknbakipqxIFMQurakh5qxICgcDCBG6ts8YT8AAAAAAAAAAADdQV0/3SkQXnB8e+lfpsrCk7isIFUQx8K7vbirGFtXKCAMIt0/XUHcAAAAAAAAAABpTXNnTiAnb3B75u1kv8u9kMKsIR02y8Kvw8+sNFdYUyYQIE5nc0ZpAAAAAAAAAABGNTnaPiVWX+175e9E0cuuks+rMhJty7uryM+vMlZbVB4lJz7aOTRGAAAAAAAAAHhRjk9DY3lc5fno6+Ux0cytk8+thwuYx7i4yMith1NaYFpaWmFBT09R2QAAAAAAAGdMLkkpeXR66eV8fF+o0rurscmwrhDKtbq1ycutrh5YV1taZigTOy5NRgAAAAAAAEGOSUAV5+t6b+l3cCu30rqvq8e5sjXQuLTHx8y0sB4dVVhaWh4mTY5RRgAAAAAAAEqOjjUTZXflfHtk3kPIy7isicm1lIHLtq+bx8i+wSUMEVtvZVcdIjo7Td0AAAAA3E9ISCkmWnB85nUqRELTy6yrMMfHkbbJsJltycvExSJVDFp6YGUdFk9JTtkAAAAA2jlIOBlXX2Z16XRjK57MyaqsIZXJiqzHtIExy9HixjpXVFtYdlooDtbgoGsAAAAAeEg4ORxWZXBwbypkLJzJx6ysGjPJjKy1s0I2y86qwaVfXFdaWFooDjstSWsAAAAA2Uk4ORxaZXBfdXVwV8fJtayqKCTJl6+XsSUqx8mqsKN6elxbWmQoCk+ioGkAAAAA2khPTR1aZXB3d3t3JMnJrKyBWlbHta6KjFYrx8m1rJlWZWVbWldea0w4UWsAAAAA3Ew5SSVaYHB3dXdmM8nJqatIX1+YyYmGM2RXm8fKrawnYFxlWlYeJUhISXgAAAAAAE1LTSdaZnV1byxflsnHk6s3b28zyYeRO3RklsnKraw3X1pvdFYoH0hMTd0AAAAAAEowOF1aZXV3J15Wx8m1k6orettFyYmFRHRfM8nJiqxIVl9e33QnITo6QQAAAAAAAGcwOEBUZSxeLCxDycmplIxZenZix5d+LGBgO8nJiZQzKFYrXmQcB0g7RgAAAAAAAHg6S0gZJV9fX2RLycmTlIFgdNtkmKkvWWRkIsm8l5GIHCdWHBAVLQk5awAAAAAAAABKMDA1E2BgZVmWybyKlEh0enpvM5QuYHRgJrW8qn2CEBkrExAXLTRA3QAAAAAAAABnS41JD2Bvdl62vLWGskB53tt5RZMrYOpvK5e8vH2EHyonHA0ICS5nAAAAAAAAAAAASTI6Nyt620XHvKmUlETe5+rbZIhfb953Y4G4vH2QMhkmDBUHCTXaAAAAAAAAAAAAZ0hLoSdweTOswPOLlGHo++/o3nJ5d3reZDKswPKPkB8TAwgECEEAAAAAAAAAAAAAeEChOjAdcazM0tLTvXLu7+7v5+Xn2+jldIHQzs3TxIgKCAgFF2sAAAAAAAAAAAAA2kpLS400LHJubm5u1+z49/f39u/q7+fneUdDNjc3IyEuBy0JSXMAAAAAAAAAAAAA2eJJS40yMFfq9vf4+/v8+/v5+/nv+fnr229mWVkeCzUtLi44jXgAAAAAAAAAAAAA2o7g1E+njUhX5vz8/Pz8/Pz7/Pr8+/rlfHpvWxsNLQc4QFGOjngAAAAAAAAAAAAAANj09G5uUL6eK2Xt/Pz8/Pz7/Pz57+/r6GVXGiNIQD81bvX04NoAAAAAAAAAAAAAANlnZ0E92uKejUwsdOXx+/v7+/r563t1VBwfME81Yms9RmdncwAAAAAAAAAAAAAAAAAAAAAAa2l44qVLn0ApLGB2d2ZgUyUgQDiOO015aGkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABp1diijkhPS0k4SUpAUVFQ1i5NTUZh3QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA2mdq1dbWSdZPT9Y4T1FRTU5nZ9kAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAa2drcmpyanLUampnRmsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA3dlza2treNwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP///v///wAH///8f///AAf///w///8AB///+A///wAH//+AAf//AAf97gAAd78AB/jAAAADHwAH+AAAAAAfAAf4AAAAAB8AB/gAAAAAHwAH+AAAAAAfAAfwAAAAAA8AB/AAAAAADwAH8AAAAAAPAAf4AAAAAB8AB/AAAAAADwAH8AAAAAAPAAfwAAAAAA8AB+AAAAAABwAH4AAAAAAHAAfgAAAAAAcAB+AAAAAAAwAHwAAAAAADAAfAAAAAAAMAB8AAAAAAAwAHwAAAAAADAAfAAAAAAAMAB8AAAAAAAwAH4AAAAAADAAfgAAAAAAcAB+AAAAAABwAH4AAAAAAHAAfwAAAAAAcAB/AAAAAADwAH+AAAAAAPAAf4AAAAAB8AB/gAAAAAHwAH+AAAAAAfAAf4AAAAAB8AB/gAAAAAHwAH/AAAAAAfAAf8AAAAAD8AB//gAAAH/wAH//gAAA//AAf//AAAP/8AB///gAH//wAH///wD///AAf///////8ABygAAAAgAAAAQAAAAAEACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMR0XADojGwAuJiwAOyUgAD0qIwA2Ky8ALi01ADUsMQA1MjsAXTcLAE4vEwBaORkAazwNAGE9FgBCLSUARzQnAFI1IgBaPiEAUzcrAFM7LABYOi8ARTo2AFc9MABgPiYAZkIbAHRJGgBbQiwASkM8AFpFNwBbUjwAaUgmAHpPIQB5USkAZUs5AHhaOQA8O0cALDhRAEE5RAA/QUYAPEVnAD9XYwA0XXoAVktKAEpJVABRT1AASVRbAFZUWwBuTkIAaFZFAHlXRABmWVgAeF1VAHtiRgB/cUsAemVXAEhOZABQT2AARFdlAFlaZQBYXXQAYl1lAEtgagBbYmYAVndlAEhheABVZ3QAR3RxAFp9cgBkYmkAdWRiAGJxZQByc2gAZmd0AHBvdABsdnYAgUwXAIRWJwCQXysAhFs1AI9gKwCVYi0AiWM3AJZoNQCfcD8Ao3M/AIJeSwCCX1YAiGZHAJFsRwCYckcAhWBVAIpqVACKZ14AmW9WAId0WACaeVcApXhJAKN6UACDamMAiXNtAJN2ZgCIeXkAkXlyAJl9dwBUg3sAqoJYALCFVgCcgmQAiIN2AJqFdACagXsAqYhlALSMYAC5kmcAp4h0AK2KcACghHkAqpB2ALaWcwDBnncAw6F7ACg6nQA1ZI4AL2eQAD1hlQAqeZsAOX+VAC5dqwAmSLMAKF2yACxlpwA1ZqUAJninACVruQAhcrgAMny2AENsgABNdIQAXHSAAEx9lQBkb4IAaXWGAHZ5iQBud5cAFmjFAB59ywAlasgAJ3bIADB1xwAoddYAgn2BACyLiwA+iIEANJOLADuLnAAonJgANJSYABqRvQAug6gAK52zABesuAAPtb4AIKKtACG1uABejoYAVYGUAEyZnAB5gosAa4eWAGmAugBap7kAcqu7AGSytgAci8oAG5THABuK0AAamtgAI4jHADyHygAnms0AOIjVACKf0gATpMoAFLrGABKt2QANvtQAFLHZADChwAA8vcUAJqfXADil0wAuvNYAN7bWAA224QBFlMwAZJ7KAEe9xABbqtoAQrbWAFiw2wAIxt0AGMzZAAPW3gAnytsANsTbAAbH6AAD1+UAEtHhACTT4wA53OoASMXYAGjN3QCShoMAjJCIAJSZmwCghoAApY2HAKiPhQCijYkArJWDAKmUjACumosAtJyEALuegACzno4ArpaQALCZlAC9o4gAqKGYALeglQC8ppYAm5ukAJeprQDGpocAz7COAMmxmADQtZcAxbWsANO+qADXx60A28OuAMTFvQDTxLMA2sa2ANHEuwDUyLwA2cq9AN7TyQDq28kA5dvTAOvi2gDw598A6+XhAPHu6wD///8AAAAAAAAAAAAAAAAAAAAA5gAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADxWwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADZdfPe4dgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGgwBBcWAg8BEAQwaAAAAAAAAAAAAAAAAADi6wAA51YyFw8TBRUdHRAFEw8XMlbnAADr4gAAAAAAANr5c1vcXDAdIhEYHxgMEhgRIh0wXNxbc/naAAAAAAAAaOjybjIVMiFMTVFQU1MOHyAaITIVMm7y6G8AAAAAAABd1jdWNVZg6lVRU1ROGg4OG1BTI1g1VjfWXQAAAAAAADJIXF4yU3F3SiwsLR4NLiwlSWNTTTJeXEgyAAAAAAAAV1Z03iJya2uniISIPhqbiISIQh8OFN50NVcAAAAAAABXV90bUnF47aXRlb46TKPHv74+U00SHd1XVwAAAAAAADNGRh9a7ergrc2Rx3wNyr7Bx3xRUBofN0YzAAAAAABkSUU1cHnv62zTwZLAhxTQvszAh01UU1MyPT1nAAAAAEY/HdzkeOpxN9K+sMq1Q82+y8yzTU1TVCAxSUYAAAAAPY0dUnd5cGxp0raFz5Sgvn7P08gZGWFqURsvMwAAAAA5Ox9Sa+tsNafRsSqisru2OsrUxh5NU2JTDKioAAAAADksIFprYFlZusmxLpivu7IipNHDqGFTU1IMRTviAAAAO0UgYXFycljPubEyQLqyhk+cy7CmalVTUlg/SuMAAAA/MyFaa3JxQM+vrlJYz4N9YJnQtJ9SVGJNH0I9AAAAAD05I2FyWViaz4d+anC4gDxwQM6vsk9TdlkbLjMAAAAARjgxUlhSWKHJk4lwdJ2TMWAxzq+WH08jIxY4NAAAAADYOjkMWlpYzreWP3d3RIJScCHCt4EcHx8LJCdvAAAAAAA9QR1adEfOrpY35OBfe1rkWa+7eighGRAHKwAAAAAAAGc6i0/ff77ElGX2899tdORgfr6qgRsLAwdjAAAAAAAAAD8+LDa8xcWr5fX17+zk7HSbvb2rKQgJFuIAAAAAAAAAqEJBLWLu7vb6+/r69/j05GJPTQocCRZBAAAAAAAAAACP6UuMQmL5/v79/f77+/TqcVMKJggz6JAAAAAAAAAAANvVRm2sijXf8Pz8+/nx6nAgJ0c0Y2PV1QAAAAAAAAAAAAAAAGXXjqkzMV9sWVgxMzk9Y2UAAAAAAAAAAAAAAAAAAAAAANlnl49KjjuOO0qXRmPYAAAAAAAAAAAAAAAAAAAAAAAAAAAAb2djZGRjZGfjAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP/+/////n////gf///AA//mAABn4AAAB+AAAAfgAAAH4AAAB+AAAAfgAAAH4AAAB8AAAAPAAAADwAAAA8AAAAPAAAABwAAAAcAAAAPAAAADwAAAA8AAAAPgAAAH4AAAB/AAAAfwAAAP8AAAD/AAAA//AAD//4AB///wB///////KAAAABAAAAAgAAAAAQAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0LC8AUTUlAFU6JgBYPzEAX0AfAHBKHwBfQCkAUUAxAGRFJABoRSEAakwkAHlRJQB1USoAclEuAGhPPQB1UzIAd1c1AHhWMwB8WDMAdlM8AD48QwBBQkkAXE5DAFlZRgBWW1kAb1hDAHxaRAB6WkkAaFhTAGhcXQB2YlgAd2deAHlnXAB/al8AT1xkAEpcawBWU2IAWllgAFpcagBAUXsAaV9iAEh9agBMfm8AX3xuAE9gfQBdanMAWHJ0AF94fgBqZ2YAY2NrAGphaABwZmMAcWVnAHRmaAB5cWcAcH9lAHV+ZwB/em4AbWxzAG53dwCEWCoAilsqAI1fLQCVYi0AjGEyAIBjPwCOZjsAlWUxAJlqOACcbDgAj2xEAIdqSQCVbEEAl3NPAJ94TwCFZVEAhmdUAIlqVwCJcFwAl3pbAJ5/WQCid0kAgGdgAINqZQCFb2cAaYZ4AHyNewCug1UAq4VbAK6HXACGgW8AhoV3AKmLbAColH8AuJh1AL6adADCoHoANVmBADxUnAA8YJcAO3yVAEBegQBZboAAd36FADSQlgA1hqkAKpWiACGfrQAlgbIANJewAD60uQBKjogAT56UAG+CgABmo50Ad6OgABuT0AAji8kANILMACGYxAAun80AJZrTACqd0QAWocwADq3VABaz1gAbutkAIqfNACmh0AA6rtQAIbDWAFi62gAMwdkAiYaOAI6KjgCfiIQAm5WRAKCIgQCojoMAp4+IAKeTjQCynIQAqJaTAKyZlQCTpJQAvKKQALChnwCPtrkAv6qiAMSkigDHqokAw6qSAMKynQDPvKoA0cnDANnNwQDn2MwA6ODVAO/n4QAAAAAALwMAAFAEAABwBgAAkAkAALAKAADPDAAA8A4AAP8gEgD/PjEA/1xRAP96cQD/l5EA/7axAP/U0QD///8AAAAAAC8ADgBQABcAcAAhAJAAKwCwADYAzwBAAPAASQD/EVoA/zFwAP9RhgD/cZwA/5GyAP+xyAD/0d8A////AAAAAAAvACAAUAA2AHAATACQAGIAsAB4AM8AjgDwAKQA/xGzAP8xvgD/UccA/3HRAP+R3AD/seUA/9HwAP///wAAAAAALAAvAEsAUABpAHAAhwCQAKUAsADEAM8A4QDwAPAR/wDyMf8A9FH/APZx/wD3kf8A+bH/APvR/wD///8AAAAAABsALwAtAFAAPwBwAFIAkABjALAAdgDPAIgA8ACZEf8ApjH/ALRR/wDCcf8Az5H/ANyx/wDr0f8A////AAAAAAAIAC8ADgBQABUAcAAbAJAAIQCwACYAzwAsAPAAPhH/AFgx/wBxUf8AjHH/AKaR/wC/sf8A2tH/AP///wAAAAAAAAAAlQAAAAAAAAAAAAAAAAAAVCIfUwAAAAAAAAAAkoscBAIHAwIEHIuSAAAAAIlMG0lARAYKPRRMiQAAAIxPTlhcZiQYYmcMTU+MAACIVRFhkXtqKoJqPwlViAAANSFfl3N6gWl/eT5FGjYAACcSYFBvbXyAbIQLUg07AAAlQVpKhWVrdiuDW0YTMgAAJkNZOH0wcWQ5fi9LECYAADMPR3B1OlctSH0oDggeAACTI1Fud16OOl14YwUBjwAAAC4ZdJSbnJqYViwVFgAAAACHPHKZnp+dlkIXHYYAAAAAAACNaDE3IDQpigAAAAAAAAAAAAAAkJAAAAAAAAAA/v8AAPw/AADAAwAAwAMAAIABAACAAQAAgAEAAIABAACAAQAAgAEAAIABAACAAQAAwAMAAMADAADwDwAA/n8AAIlQTkcNChoKAAAADUlIRFIAAAEAAAABAAgGAAAAXHKoZgAAv3RJREFUeNrsfXeAXFd1/pveZ2d7700radUtq7hIcjfu2GBwISQEHEJIAgZCICEQSohN+RkbU2yDwcZxAfduq9hqlqy62tVqV1u0vc3OTu/zfrP3+67QbmxTIqeY9/7Q0czOvHfLOd+ce6pO0a731LXy7Ft0/O/vor/rypCq86i49r3+I/X3vI92/S++fl9m0K7/I5cGANr1h1waAPwvuaTgSsHKvjbwT3pS49tQuYemee8b5j1CN+99dd795wt8Zt735eskaWre5+XrxLz306dSDTj+d10aAPwvuTQA0K7/iUsDgP+hKyvg8wVbCrD5baiV1DLv/fnfmw8QhnlUPvft9l4KevptaPJtqBT8OGn0bf4+/7W8rwAQDSD+ey8NAP6HLg0ANAD433BpAPAuXacI+HxBl4JqI50v2I55VH7OPvuPqoJm/2ed930b/y7un8ng/UwmI56rKnoAgErA0GHvJQPo9Sf/K1V5IagGg0EKKAU783YCLl7rdEp43t8j82ho7v1Ofi5GOh9I5hxJNIA4vZcGAO/SpQGABgD/Fy4NAE7TdYrRTqrkUqDnCGj2cpE657xWFTeIKv+eO/tPVpCdoGreLE0kMx5B40nx+bSazsH3VQCEkhbPy8q3AAKTxSjGo1fSYnwGgxHj1AGYdKoqBCqVTKq4ny6Dz5nTeE4sidvrIZgGo6AGvU4Irl5n9PO1EGyL1ejDa72gOp0a4Hz8eA2avYKnvq/8Fhgi8/4ugSE+j2qAcBouDQBO06UBgAYA/xcvDQD+wOuUQJv5xjsp6PMF3EMqBDUrbnytQsBVpXCWplMZQaPRRMksDcfieD+dEtSoVwWA5BU4hWDXVpWI55SWFInnRGOQi7wcnBBKi/PxFB00+IwKTT0GeVbSGdr60qDRaJSfhzxlBV7QweERTFKPaRpN9jnf9/lCQlBD0YQQ9MGhMXGESMR1YkAWq10IuNVkmhTUahyfpQaDbozrMjX7TxYYpvnaR+qfRyWQzAcKCRDSzTjffald73BpAPAHXhoAaADwXro0APgd1ymqvVyr+Sp9DqmbVEheVtBz8VItnf03Ky9FszSVypTP0nAkXiloOCao0awT92tuLhMC3dJUJYCitlx8TXFA7rOCAwHVczSjY0KuFO/0jKC5ORiekaZHmwsCm6FAx0IAigwFOJUGQFhsOLGkUtD0K0qLBR0bF/KqhAOQv2gcAOLOyedzcF+z1S4GZjKZxciGhr3ifV8Acjo0Oi4Ee3w8KgQ4kzZlOA4AglE5Ib5v1A2JxdYp41z2Mb6e4vpKOh8gJCBIo6IEBGnE1K63uDQA+B2XBgAaALyXLw0A5l2nuO+k4M93z0kVXwholushKaoqVPesSl8maDojBDurctfP0plAuGaWmi2qEPCFCyrE/c47u1VQlwu3D8fhRXOaKZAxaLjBKPjbYqYqbsDWTYxD0LxT0JydBIp4BPfJdWO4Iz58bngIKv3lF5+PWagQ+MkJAEhGBTDkFxZxFXA/uwknnngCfx8em8B4LBhPXV2FoEPDkM/JaQCGkeO12DGOI0eFnCsnTgwIWlZeLiY2PBISA5jxRsQDjCbTqHiu1dQzS/UGXd8s1ekAEFnOBTBkH8X9mA8M892RArlOCbWeE3r9p3ppADDv0gBAA4A/petPHgBOMepJgZeBOs55VLjhsqp9KV6qEPSMWj1LUwm1ZpYGwvFFszQSCwtVv7mpUNzvok3LhATUVQAvXHao6pEwbFoTM+Dj4THYxhpqxG0VXRIC9/K21wXtGwT/X3H+2YKesbxR0KAX/J5fLHBIOXbkqKA79h0WtLwCAjgxBSBxOXFiueWmy/HcYTz3wGF8r7vnuKBJeBeVihIAQl4hTjYBP56nqtCwqxsXCPrwo88I6snByai6CvMIJ4GrPb24f/uhvYJe9L6rBK1vWirolB/y29U1KBCrvWNYPECnGsVC2a3mY2KzTLquWZo9CvVjP+YfHU4CgjQeSreiBITMqfRPFQg0ANAAAM/VAEADgD+l6xTjnmUepfFOKZj9R1VVUkWo9OmMWitoKi0kzx9OCIHPKHDfXbhpoTDmffCyc4Xgx+JQ4XsHoPpOjEDQbIzMbagDIPhDEKjKPACDzSXwRpmh6h6Kgn+37GkTtL8PXrPz1kFwyty4XyqDSN6eCQDKrn0Q5AvOXSeoFXE8WSDA885cvFBQuwnGvdvufUpQh0MaDyEXr7y6RdCrLzpL0LoqAE0oARaqaWgRNJnE/Q+2HcPnr7pS0HAIcvfmwQ5BYykAh8kCvLVa6FWVRkUz1qG4uBzzHRoWN35122FxVEgnreIGdpupfZYaDPqj/LpY6OxR4QT3cZRUAoJ0M0qj4ZwkpT81INAAQAMAQTUA0ADgPXmdouLLSwq+NOpJFV8IflbgwXGqIqxa6UxGGPGSyXTTLI1Gk0Lg9Sao/peev0hw7NUXrxMAEk+Dn/a8eUjQmQkYy+JJAME5q1sFfeghCNryZpwopqmgFhXQGMijQUutwB+l4zj4+NggjHWLG2l0GwEQSFV8QSOAIxqGgB9qgxzYCiCwObkQNO8Evreitp7fB98HUxDA51/bh3GnAAyrG8WJR6mswFFg9eozBB0cAdAc7mjHeJcvU7hueP4+CPyCWoGbSk19E743BmDbsfsNQcvKqwQtL8M4+wdhrEwyMKmyHPPNzcP8TgyPCgHevrNTLGzEnxELb7GbBEIa9DoBCNkjgTQe9nGfR0jnHxFkgJEEgj+JgCINADQA4Pc1ACDVAOC9dJ0CADJwRwq8DNwRHJ0VAMGBmUymYZYm4gmh02ZVfgi8XhGce83VK4WEXHvJeiHwg/0QzNd2vymo3QEBWlCBiN8KD1TZvj7w3e7DcH+9eRACtoyC3DcJgMh3wVh3wdo6QUMB8GXvMIxjCbrpFi6BQMVjmN7AAPg7MIH79/VD8I16TLeyDEBSWoHnGa0Y34khCHB1Of6+YoWYrvLiZsynpxfzW38m3u/tw/2r62B8TBng5svJB3DteWMn7k+YXdG6HONtXiKoys9PMcT47p/ew3nhCzYH5n/upgsETTIwSafDuoYjkFe9Cdu5etUqQfe1dYuF2ra9UyxIFg6EgBtMeoFAJqMB1lCd0oX76Qa4/zIk2Us6J9T4vR5IpAGABgCCagCgAcB76soK/vx03HmhuiokQVWEJMUp8JlUSnB6lhFXzNKlG8Bg61dUC0lqKgAjvrptt6AG5MAoy5qhIh9uhyAeHwS9ZL3AE6WhRtgQla5euPG27YUxL9cGwWvvw1Gh2AnjW54Nqq8vBKOeJxcMb0jiCBBjPZBQlIBQi9DcWAbfmwzDuDYwBOCoroHqnjbg/oEgjHL9PRDwmlqMXyYTzYSg+ocDOJusWb1Y0BQFsbQSxsuunm6MOxfLvW3La4KW5AN4Fi2CkbHn2LCg/iDGV1AEW+sTL76I8VHFX1iL+4bCfH4CzyuvBSCmUgCKx556SVCLDdu69qwzsU5urMuBIz3C2Dc2ErZgv/UioMhsNB2ZpUaT7gjYQScmkD0qSECYIJ0hlcbC9+TRQAMADQAE1QBAA4B39TpFFdfP+9P8stbz3TBv9/n5dH5BDpbOOpmsw0Cek6q+UOnDoYjwo1lNBmGdK2qoF5J04YeuExxsMUKQBjth5EpO9wp60TK8v7AIjztBY9i/3wXj3vZDcL/d9k/vF3R5C2yLoxPQNHUmfL+/BwL2ymYYy5qaRfavMhME303NAACWLYbK39EN/pw2Ylrd01iucAzjiMvKX1bcX01CkBLyfbKvytBiswnvJwkcqShUbpNBP4fa3RBoHdOHzSoApK4Yqv+GtQIvlYYyHC3MCYxz3z4cdcJjMDpW18DYN+nF66effwF/T+D5G1fjyLB8FaiZgHiCxs5DR/sFzaRZ2UwHml9Ct2kU4127Zo2g0RDGsX37UYHUk75IFMyCgCKLBUbD7BGvDfc7aSyUQCDdhjK0eE5BklOut3Mfqm/zOj3v9f9I6TMNADQAwLw0ANAA4N243iLUVhbSmF/U0jLvc1KQ307g55e3lveVxr75Kr/gvHgMobrBQFjErhaXFgl6wTUbBSdH7HDLhWa43wHww6WLMCx5BAgHEXEa9cmCGRjGCbrpDvbClpSbC6OW3UmBsoLuP4zvtVTgaBBzQkU/Nobv7drXKWj/NATYkEsV3gFGNzmxXMWFAIJcFwTU4cD0PXztJtVzecw0wkUTuG+UAh8JwggZCUOwZWCSyYDvZehW7CIQyu/J95UINeUczNftBgAVuzDOc1YBwJbXYbxHX9smaCIEwXY68f7QBOa/5pzVgtbUYd6d7T2YhwXz6x+EF+/EMNa7aeV6jMeKo0xdDWhpEdbLP4UjyL4394iB7j8wJBYiHEkLo6DZbBWIbTTq9gum0un6yT8ytFgmGc0vhvq7BFUKugSM+Q1U5pc8S576vXfbCKkBgAYAgmoAoAHAu3KdEnJrm0elgObMozJAxzSP/q6jgH3e9+e492KRuPBbqZm0kLjK5lphhbrw6svFeOxufP3l557F4NJgrCX5HLQeDFeYC5V9WRNU3cFRCMDIFPapoxMqvj8APimuBqDk5eII4CgGQz+7exCfHwQ/TFhofKMgeVxYpoZqAERpBQJkjCzcYaIgVxaCwauKsHx2HlnsDLF12UBTCTyH8UJKRsWyJZJ4IxxlqbAU+HR8BvOMRCjo/Nz+Y7CVzTAZKB6BXIwPYT7eSXjVkn7G2Ti4rTZsi9uB51rjWKcNC2H0W1FoJ3PgeQOjuI8vg3EVeQAsr7bBaJkJQzM/fwNCk9VShDofH8K6LyHQhA0AQIMV96/0ANBGBwGwh97oFBPo7pvA0cDkFlZai0kRgKDTKd3kJ5l2LJOK5pctl3S+TKXmfV4K/My8+71dYZN3NURZAwANAATVAEADgNN6nVJYY356bS5XC5LA0NuMTLNVFYrcyWKaUqDnj9XId4UkZFU2Fz8kjX3iOdFQSjx3OuAX93vftecLQPrQzdcICWvrgLEuNI7kleHjoMdovGqthkC0MRT3ussgiJed3yzoy7vhBuzqxX5V5AHXRhjY0z7BIppOAMAgk2eiLNGVsUtBhlvMkwfGLSmGe7CGAr66seqUSc8a/SCQOVbgq4uFOUw63F8W9kimVVKWAEvO1ShVWVtM1gjln5mTc9IdF0vgD+M8KoTpRjwxDv4dYmhvWzeOTMYM/p7nxAlvgiXFenq68Jwkjw58fo4NM1tUBHYp0jMexwe5W1YB4+jPtiGN+MxVYJ9zzrxY0MNeuBEzBIz+boRi798D2rTmPEHLGuCWPHc9ApOmhyHfR/e/IQTyzTdHxcwttnwxMZtNlYI5Bb5CwJAqBVX9T81Q5/OpFHxx/+z2eEF1ElCG+b5MWpLFUeVzxYK/W+5HDQA0AMB/NADQAODduLJAIAVfCjYkIaOKCJkgC2j0DvqERKUSSLdVdHoIvp5WKMaCGmgcyWqw4n2z2SLm4HC7xetCt1lwUDIWEK8N9oB4/hnrNwnOqGluEH9vLQcDlrmhqsa8LGGVofvqANxyOW6G4vZgv/MLgUvUjLPAAgZf1AS31eZ+SM4L7di/mSAEs3EhBHrRAuBcFZNqivJwv3wHpptvB2AUumVAEASiocg1Z8emWGzTTIGPU8AdZpbukqo9VX8T3YBBlgW3onanYuT77AuikChBGvli/H6KyT3eGQBAMYuP7u/B+nn9EPguuutKOP4SN44shxhSvK8DAJtKYPwZ9htJJbAf8giRikDFX1AM9jmnEsC4tBTPN6v4/PO78TlDIQKuFiwGMB88iMjfLS+hkMrqDRcK2nom9ilqAZC7XQBeQxhHmPH+dvGAQ0e8YiVmZux4oC4tNtY7Df9pFg/FwmRSqNiSyKSxoKrcIWRXZQVdbITBiDLpZptxGPtuFwuR5zId5cZ2cnsxkN+6IQUQZQFAHiVO66UBgAYAgmoAoAHAu3JlASCP/y3FskDwI9GkiBzJz3MKHe7rX7pM+H0iYQhiIEBNKDFXpU2RmkxgrCBVRGW6Q/zhrif7sFAuuIGu+cAFQoKK3MCfUADGn4vAB8qSejBA52sHBa1ogOA6yyHIA0fBqN/+AYxfRXTHmXQwXj3Sgcf5PAhVHeiljWchjHfXXID038sW4fPFDFU1sdhmiYfuOiPm6bJCgC3EPVngQ26VnmXBkynQaFw2/sC6GKhS6/X8floa9xTeD5/Lc8LImKTuHwhCU7UyMGgigNc+Il2SxsEZGjfNDBBa3QJAe34vVP+BCRwJLlkBHM+lG/C+l+E+9BFAxlj668Qkjg4mPcbpnwD/h/0AjEgCAJxK4bkLi2nc9MGttzQf46tpgko/nsE6e+z43Iu7EHKt8vB01uq1gh6fATDXL0J6ciyCBXLG4J4NT2O/3+gcFw/OK4H18MOXLBRf9DGZKWXCfrqlsZNnKNpYFSMBWUejrWEG6/rM5i4xgW1d/t/M0gKncY/4nA6lzpTfAoFgcA0ANAAQ/2oAoAHA6bz+O4yAUvUXHJEFAKHy+4Kxc8WbpflXz9JXn/803YLSa8g6DXEwwtRQP17b8bGCwgquMBb0s5/6lqDP7cX3/u7Wrwg6PIg4jqTvgKDFpdiwwX4w6vXn4jal7FSVU44lGZyCgP3mZXyuqgACfXwc07kPNkJleIxngXIwXss5YMRLV4Kx1lcBYJbkkeHKwChJhuj6/WDwNDnGbMKysWJWlnEheAkKvI4qf74bR4ZYYm48SogqfiiKdYlEydg2PL8kH88fYBlwaQPMdQMQJn0Q0Cmq9H7ex0RA0evxnDgB4Yq1KCjyxHYY0470Q6BbKjDvS9ZANR8ex77s6MA672cS0pEB7I8VJzclwKNBaAYasD2Ev/uDAPp+WWCF+9q4FIB8wzIcpc6swu/NLv4OdJzAc70+3LeiHKXL8isAUGM00ZlT+Lx+EqHeQ8PgtwUrML9+/tBcshFp0Z/8IH5BZKEXC9OrFR3NtARqRQd+8x5nufTX8AN072tICrt/z6SIha7MN7/M/T3IDT1OKhYsCwDS2HhaLw0ANAAQlwYAGgC8K1cWCNhhQkEgjqqIWlLBaEpUfHDb9eIIcNuHG2Dko2pasQQCF8lAVYwlIIiuXLjDGgrxuc27sWGf/CbSQxfWYYM2rsMGH92LZJO+Hmzg8laorCU5kLB0AJrWDVdhmMfHIEA9vRDEHQdhzDoWgxvq9UECVDHus/QcJMGctwiAtLIUjFDDUNhCBwTFZcb9Cgqg8ht5BJA9Oid9mKdETacLjDM5SSDkY80URCfLisvGG5M0Ypot+KB3GsCS4R3rqzB+G1XSE2MwnknVv7URRrEwG5G0Hcd6yeKdKlXbOBXRGAWmrhjznfDBKNdGo6AvBIFrqcZzCxjYdHQAf68tARD9fAuOBjIAKcWGJ1NBjN+W5pEjjvmNegEcbWwsokwBcIxufO+cajzHHcZzmstgPD0+iXmHA5hHRRWA4GgA+xAOYb6jB1D8VGXI8aZNGwXNzcUPzyss9XbtdecI+uW/RIOVJNfHwICuaBzyOt4PwOvYAcG3stTb5kEAxINbhoW1sqrQIrLIsgCwmyxA4yBKmGUBQAYQndZLAwANAATVAEADgNN6nZIEVEIq/DNZABAxm6FY5pJZ6jQrwvj312chYMg7CBXPaIfbbMklKPSw8kIU5vCwZNbNf/N9QfuHsaCFbqh+lgwY79wzKXhUYQcGwTi+oHQjQeCKciAg3Z3YsKveD8YY1SFg5OP3QFWO0CZpPm+loDdsgAp4YQOAoyEHjJRnkao8nm+jSm9it04ZzWG1QIATFLAIslRPtv7S8/M+huTabCwIQrddgm6/RALjlgFC8v0QjXdN1cRfIkuSz7Pz+Qe7AIBuO+5fSYHu5j40s/z3iXGswxCBpoBuPrcDRr6RKezDFJOoDh7H92NJAEWcxkq3w8x1wYinI9ifGe5LkG3OvUxKMnA9ggHuQwjAdYwBSkGWQFO8pJP4nDWD+31gOfiosgTz27UD7l1HXg3Wi6r7oX4IqCWN8VdU4Oiy4WwUPx1g0pFcvym2VNvEgKIvfuoaQVMRPHf38yiNtvvFHYI6PVinBZUshHIIn3twt1+cnapy9c/P0iwAbOVWtpGKs4IGABoACKoBgAYAp/P67zACSgAQkpUFAJG3GYpmLpulbrde+Mn+8VrovD0HwJBpuv82noNkjyUbIXhffQZlpF/ZA6PTFathpBnrQIWnFS1Yp+s/gKPCiR5I7sQJuI3GellUMoMNeeBlGGPMLM1VeiZUvjtfYy6GCmNb65WwFn6QxTiXl+L9Rg8E0smUJemm09Eop2dMrYmMrFJAkxSMNMtxp1iQw0j3Wpqf0/HvZiu+H2PSTiDGwh00OtlsGEeaDBpiqHBlKYDR64OAFtMImGADj55RrI/NwIAgqvZ2AkIDi4mOTAMwRycBSDk8qnWNQCDL8t1zxvv0LgT8mCjoAQqGREAJfE4mLfmjEgAwPxnCrNK9OTDJ8ud6vO6Jgj+GGWLsSvIINdqP+/WzrgfboV9CY2FujIVF+sBnFSxoEuF6H5vEvns8WKf3XQh+SBNBAwGML0Mj7hizdxe2oGTa9U14zku/wZFUj/4lSkkp7lfmwPo+cwTjf/SoXgy00q2IL+h0yssY+EkAEAPNAoBMDjqtlwYAGgDg+xoACKoBwGm6TgGAYlJhnVNVVRwBZkJp0ZWyosQl3v/Fl1sFRz33xFYMzAAVtb4E+PHSEWzw62OgN5yPppOjvSh/HYvB2GJnoYyYEev18XPgthsbBYMd6cP7Ayeg6tUthqr34zcgYPv3k0NXwph4yeVIM72mAeNo8uBzVXTrGekWs9L4pqcAy9JbGZkjQvedQYfPRam6608GjurmvpZAQeOYTj/3Pn6qwGVFUGFl4Y7pGQhEmKG8Cot42th6q5ZJNcMjMJINT2E9U3y+dDNaGJjUzGKhDoYkTxBIinJhzPTO4MjVPYT7uexY/+1tUMnjTCJKcxxDUxifScfAJVo3ZbLSZEgehTBeK+e98wgKgtQw7XkkxPd9EHCVrdPsYRovgzAOZlguXWFb83I9xvuRc7Gfncfxw9DOQi5V9fy9YkOSpha4cyNxjHN4AHymMwIAM9ywQ7xPjhWA8rfvA1+Zk5hvIoxx1gBPlZcHMY9fHbIKK3alO003oPIKPqEcJtUAYPbSAEADgNlLA4DTe/13AoCwqkkA8AVSV8zS0iK7kLTt954vVrTrKBayhyWfHtsOb8iTb/QL+tlr0HoqTuNYLIINWcqQ3t+8CtVT8v/fXA2g2HUE6xeIYWMXs6323c9Bhd13hMO9HCrfX1yOkNFLyqHaNufie04ypkJB1hnxfiZD45/8M1c2fTL7VgoYPm8wyVBfur8oKFJl1vNzakYeCaA6ypDfOG+sowCpPGoEKEBWkwxBxXNDYQBgLVX6fA/mJd2PATLoGANmUgwwqqRbs4JHh/0sXy4LhTRV4oiR5wTjHx/Gvk1zf7a1YT99NPa5uUBDDCmWBUnKWfZcMuSEH+P1+XEf7wz2yePAD4PdCAD2M2S5jca/GM8YMpQ65GNI8Th7hY5jfI1shHJpC9YhHML7SfPc9Gov121qGnSaAVKlpQBSs93JcWAd9x7D0eKcc3FkvQZZxUpoDEfNhgaM/5l+uJEfaysWAFDhjhMA1PfsEUADAEUDAA0ANAAgACQEAJQUOgUA7Lz/EsEBvhGoTPc/I2ozKl99AIEZV62DapZLFVNlkos0wkXjYIBDnVjwICNWMixAlubn7WYw6v4BMHTPKF47brxK0E9uRLvt1Xl4Tp4VDOVhMU+5YjqqsDq+IUN5pepuMs5VbaXg28hYtVUV/DvuNzImQ2JpVHSAMVUeIaaZ/mu3YlxpGusCLMppodEulWJ6cBKCkeYDrGy3Le+3uBFZ2e1UXaXApjmfKEOPUwxoqZPGxBBeb2vr5/sA3puYXfUGG6ME+DkzBdHB5Jz9FJAtbRCI4RkITqmL+8CjVJCAEaWxdCZINxzTk6Xbsp7jmhyFAO86hvuaGDJu4D5MTQO4gpOs8XkC4yxvwhHxPDZVzQSnua5Y736GKi9dVMN1wXx6BvHDU9eAfZzmkcw/jvf7gnh92blwX5+LbF+lCvFtyuO9MCb/+lAeASCpAYB4XwMAQTUA0ACA9L0JADPBpACA8hK3AIBX7londvTxh9Fa6i++A1vI1VchzXZBETa0vReq4KWr4eazsJDEMaqeBjaNfHErjgJmVla64lK48f7mDhiTFBM2rvgTHxD0xlYcFVrMYFwH3XmGkyo+jVZShaeRjF6vk24i2abbQKOXDMBJUaBcZNyFTWAAJwuB9A0Mc/xg2HyW13awMUaSgTSJJAN9YtJNCYGwsZBImMk/YQZAGejek0cAGeqboLstl+nIOQwtHmTo8RhV3TK2+GqthXvLzc8d7cd6dw5BsFiZLXukwfrJ+li5Tny/mUeFw90QkJcOQCD6xrE/LcXYX1mOPMUjj8OE+3ay8YoEPp5sFAvqbSgOhlqrdIvK9eqjkVIaRXUhPE9NY55TLD5qYeDVh88Gv8WnIPgvbRFZukoFW7vlsUTb7kNwO1eWY12KC4o5PozLO43x+sw4avz5egDlleUAqJ+3Y/+f7CgRAFD6p3YE0ABAAwAxbw0A3vMAIJOB6AZEKHAwQjdgsU1EUNx2CyJLbv065u+lUeufP14j6EOPIgnj4jMQGlxdiyPBZBgqmyENht91AFmU4z0w+lyy6WxBv/EmBL57CsPJWw9j4vlFUKlLWXhCr0JA4nHcTya9yAoP1GizRwoa7aSg62TxTQIGl1aq9DLd1caWXc21UMGrKyEgiRRDfi2WOZ9zOVgum4LnZznuCAVYhtZG43g9OA2GdzLUd3kLGLezHwwtjy5yc6SKLEODXz+M5CqZpGSn+28j02J7hye53pi/j4Dz0n587/zlEKDiXLYL74SASeNYcR7m46Rg72UZ9UGGdEfYjPRkOjMBK0xgcNjkEQgCHZVAyBktacR8Z/j5gWGq/Ey+UmIsRspAKiXO7/vZAawQG3zTevBXOsyy52zT7oviKDIyhPuuXwE34WSAR05WBotEcd+haQZKNWL9br8OQLCtA0Dy09fQtLQsJ/V2bkAZCqwBwOylAYAGAGL9NQA4Ldd/RzJQGalowZUFABHbG4sr4ghQnGcQSUKtjZOCY36zCwz2b59AKS1zChtw7xPQiAqdcL9ccDYWPuODoHf2QaU7zvRLox3uq7Z8FIPs6GWpqsshoJctw328vWC0IJNdpLEpIlVmGqGkO01PoElxow1kZOWk6ov7S6Oj2cQkGIbq5hdC4MvZuspmRTJJrlssj5LjlIKPI4CNhTwydAfKtFOZVCSPIDaqsIx3UUa9AIJFjXA3ycIgEpBSGdxnyz4ciQrZFtzFtN1JP77vp/FRhgRL4+s0m5fO0H0ok2RWNEMAh6bw9zc6ERC0vxsAsKgCjF+ZC+Pb+MCjggbMECgn+7sMDwHY43QXGghcVgZaTbOkmM4JgdJJFV/Po48VgKZT6VZlSbEkj3T6DIDA6CEgMZnr4AHcp/soxnnFylyOF+u2bx/Sl8fGwacrF0Owk2YAk54lwnws9BKnO7WHIcQXXoAfsPw4Pv/knoiwRuY5VQkAL3Fr2b785BFANgw5rZcGABoAYF01ABBUA4DTdJ3SEqyUdBGpqKSQTuuuFAunpoX1zeYZF5KxohQbsnYZBOVYNwI59Cks7LZDMKLE4liP2gKmzzLw5YIFMK7c3Qaj0v5eSkQrVNNvrEU66GcW/hrvV7GoZwEELhbGxiQmyDBUtZVUnM+h307HfiUMSNEZ8ByVDTEUg2POArsrMf2YE26hzifh5ty+n8bIZR8UtJJlx110i8nipzI0Nq3IACHcWSbvyHRjpw3rFKP7L8S220aq+j1M8z2ZhETjZE0JnnvWshpBX94DYBgchyDKNuIhqs4zLCQi24qfsxDzGKM78Yk38X0DjXKLy+F2reDRYOtBAHWD/4eC/uN14HfnWdiniAGfT/ds4Xrz0JJmeXSTh+sLoM5EINBpA454Bsl93DddAgBjKkGIrq10I7/Po8E2VOK640EcSf72PgCAuxgq/JUrYSQePIEfHD+PBOVl+CFxMrCqg0ckGwuKyFZsigl8nXBj3NY0aDTiEAhpMCa3kF9e4DcOkfbP/vN/8QigAYCiAYAGABzHnyAAyHbf5aRCp8/y3YZZmgUAEXkTz6CV16pFUbGCLWYwUFg2kUxAwLZuRfpvARtFdI2AkW1WCMANFyC0d3c/HvfAdvZcpPuqer14rHK2CQy8KvKwoB8ofFpQzxJWL2+FqmujcU5JsGpkAAymqpxWiqq/gcYkA1RaNQVG1btQUESxg9F8ClTjl+4QVaCVxvYHBf1JEG2tC9eI2qhKE4ta5rshAAYaBWV/FAuNo17ZnJOqvNEoC21g3fJYNNTPctf9U1gPH1Vql022C8fngzwiSKOitH1OMBRXAoaexrYQVW4rk4xu3ITSaHuOQuXf0wVaXcIWZwTYQ939gu4nsO/dA0B+ejX2o6EFn7NcfqOgDv58pAIAbDXMwh8EWH2UST86CJjOKNkNRjwDA78MBWfzfQDxyC7cJ/EY7hs8ASPmh3oAEO0zBIZR8F1NJQT8/GXYx7YOvJ/LtOjucYwjSKOlje7oBP2CpXQfWtiuPKbWi18MXcwq/Kk6fWI7Hqg+zYEeIBVHhCwAsDbc6b00ANAAQFANADQAOK3XKS3BqkmF301VdcIqF03iCOBxIVLnysXjIrLneD+McC1nQJVfwBZavT0M2DBgYfd2IZBk8Cj6KJQ1wrhyXzfjjmjsyVsHlftjLTC6xSkQe44AQK4y3QuqIuloLIxh21axLfelGwTNYXPOFItTpkdh1JINJ3QqAMDsxHgdhUgjfoUtwjq+/wNBVwVQ83FJFRjm42MQ/OKFKHyyvB6qdDXnnaEKfYINN+wsMbZiAcYzwPTak0YnnlhK8rj8aQjq0HSY98HnkhkZooyPyUCZRAo3yKERTZYUm5hhs06mJwcYIiytkPU0Ep5Bt2NdEYxn33scJbH2dEDAmkog4CcGAACPvop1/PaZaMt+bTHeD2YgwI71SKpxrkSItp4BPxkvgEOlUdZgw3N1NiCGtfA8sh3dv2+gjnvfd7Df9l4EnJUUY13vCEPwfx7FvuXosK4hv5f7jUYgLUUs2x7C0aiYTV1lcpeeRtJxumPjBOyWRozDRzfkTKxEnC2s9iZadYNsQ64+xIG/SSrLg4uBnO4moRoAaAAgLg0ANAA4Ldcpxj/ZEESsbJZPhCSm0jpRCiyt14t823WLg2IBcsJD0HnNYJBVrTVYUB4FnDSK7duPJI58F1StaBQL/9n7qaovgDtNacKGfno5GGMp3TiDkzDqyPLVvT0w/ty2DAy4Ih8b1NMLoIlOQfUzL8R98y5GGeiCVrgpMzEwis0MY1DcjOc98wiMV957v4f7mmAUq6yF8WeKhTVumXqfoEtWAqha66HCFhdBoCw06hXn4nteGt/qq/D3DANijhyHkcsbwrqsXoBxjE9injKyp3cMANs2xHGfTDvG95J6Jg3x8+9bi3nvPQbBzNAN6eZ+dA7C6NU3AYH42k2i2vtvjY5D+PuuI+DjvmHcZ2QU423vgID9RSv4/VtXICQ66MW8AuMMvaYKbV/9Z4K61n5SUB3LhltYQEbHuLOudriNO28D8MY3PwO+cWPeC5bg8/toTLxhPwLD8jx4jouh3oEoAba/H+s4DiC7mkVq/VOYT1evDInG99x0qzoc4CMzQ8Bn/Fh/s7tIMGLa1iIW2mywebFNCZwRFZVHAqWTVCzM6S4OqgGABgCCagCgAcB/6TpF8KXxTwYAMQlIJ7JxYmm94HiPIy524H2LpsQRoYtJIrnc6BQZuYoCYXcDGIZGoDJefA4Cge7eyeKKB7FRK1ZDZazPh0AuLGC7bRcLRISg8g2yueNTr2PjrlsEAPjSRhwp0jFMYzrI5JpeqHbxAN43NUPFrPvEZwT16XHSeezvbhe0YO/PBV23HJ/XcfwWNokc9YPBP9oNI+CyVpQjb2SIsJ3pwAUFYNCPXYEjQorpxSMEMjNLUj21HW60MNOgZdpwgMU2rUxuqmDgy0wC4xnrgc2pzgGBfNkLgCvNw33tLNr5Jo9gDWyBJrNepDGwqRLrPUXj5Ovt/YLeeh2Mb6/tR3JWgqG7vmkAxi+eBADfuhb8/vkNEJCUC+NN8EwTHiPgD+B5ttbrBC3+8OfxXBbzfPlzWPfUSzS21uF7ziIAVg6bs7qKMb+rt+ModVTF/hWwoQu9ukpSulPRFVyJdCIQqLwav1cb6gHER44D4GMMjBoZw/yWLWDadR+AsJb7a7QydNxcLfzaBmutmFgmmaT7LzXfGEjrpyIW6HQdBTQA0AAA89AAAOutAcAfd2UBQPamkKq/WFmp+qczuovEtFTDplm6acGYsFJFJsbFGGaCYJwRHzZ4cAQLeMkmFJpw5mDj8lxUzZw1gt72HAS5qhSPXdAKAFhWA0YtcUvVkIE6CTDK2ARUz31sVjnSh7TPxz/9oqB14GclQDdjMkC3nxEAkoKmqoQjYKC923DkyGGDiUq8VMxlNA7m4vtWNrw40A9G+VQvBHvVUrin6tiIo7AQqmxhDox5axbDKCpDbh0U8Fw3/t7DIp9jPgBh7zDWL0FjnWwgUpkPQdjbh/Wujj2A+wRgg3og9GlBN6zA+nUPYX1iSTCsiUUv5VGgiqW81i1GAI/LifX+wVNYzzNYTLWfSTmGDAWER4ZnngFwPXLzVkEvWoajkV8WC+XJLu0HexlMWH93Lua5ayvWZd/PsL51JvBD+Qqsi5UhviYnvp9vwbgfReS58sV2Ai+rdcp4o0iEodwsLBIK0z3tA9+EWWBkHdujt+SAL5/firL1GQJHMdOcrTmgeWyXfvgw+CS3olJshMm9HG5BvVOclXSZxFMYiQorqqIcIxUbfbpCgzUA0AAA99EAAHyiAcAfdp2S9MPY2LnpvxlVh+SfhF70Tiorj4sduaLVLyTn+S1QndI6LExrC9wl6gzbVzPZxsU00hkmUdy5HRthNuP9+hYIUEUDAnCWlkF1LiODRpiUoafqGmAyyfAoNvLhF8E4P7zxV4LevAkhx74EQ2uDZEAn20FbcB/ZiqvjQRxJchjiaXOCQeMZpgOzXLmNoanHpyCQNx9G8dHli2BsW9wA411BIYGDIaUBtszKMN1YtuaS6cKVdMMFCKRt3SzLTRXdGwQDRyOyqCjev6Hmp4KaWBrsljc/JmjJQtzPmsE8G6ugurIeiTJMoPGwEMkVa0ROl3LWIgjkNx7eKuiOQzD+VRdgHYfHsd5jBKixPgLxF+GWayjCuIJWptUO0yjJkFpbIfaxsBL8/51vYl/ie7HuH7oAR5tJlhRTCDge3i9KALhgBwLHFBeQPpdFTS10M8p119mxD8EZjNPvBZDN8AhjY/JW+QyMgQ6nLBzDlm10Uy5uqRFUthgbYqGSogIAg95TJxYqFCkSDJM9Cgh/sU6XkaHBc8qEK789CpwsO/vHXBoAaAAgqAYAGgD8UVcWAKgbKx5SYU3Jqv5CF5eqfyxtFEbA96+bFla+RAQLmleIDd6+FwsoQ2llYQzfFFTbD164RtBtg9ioh15CMk1RDVTM2mUIBCouAqOW5WAD89m80sl0XFmn2+8HA08TaF7ZDVX3nPznBL3jU3vxeSNbW3mp+ibx2mQDI1qLoNI/cg9U5tCbwL9r12KDxymwVqrs+gAYw1WGv296Ce6khgVwQy2ug0pZVo55lRXhvgOT/jnr7mBykAQ2RcX8LFaWCWfrLy9Deacmsd4dJwBgDisE8far/gPzeg6M/WevXIHPr0Crq2U0nrkp6EmVLcqYlutn6bA1LTgKvX89VOrbH90qaEUevr+BR5hfvgBBf2kHNNrwKICq+/bXsU8ZNjgJgi8ysiEKiYNJTxYH5v0Pd+Dzuf0wyn3kTLz2ssmnkQFhVWzJ9Q+dOBr8Jg1+aSmD0VkGUlkVmfTFIqtW/D0YgMDHaEQOsky5yh+UtQsx/8X5WPdHHkA8z6Y12NcI162LpevqGthwxSwbriDSKmFeIhAkmbSLBdIpceG/1OmUXdz6LlKxYf9Vt6AGABoAYF4aAGCfNAD4w64sAEjVX6b9Cl1Qqv6RmE74a5ob0mJnluQOC4CQBR9WM/20n8UhJ8dZaILJjy21bNrZDIb8zD0wsiQC2IBFqwEMZY0orGGgm01H91gBkzWqPGwoQSdlhMa46WkIxuFjcNMMH0PI6M47Hhe0EBqaMjkGBtOT8ZQ4GNFdDkbbsgsCcuROjOP61QAab4bNJFmowskuotWlYLiNj2P+mTIcBRqqIPCF+WC8xlowlgzZlc0ywzRSxRkIlMtCHn1jtA2xgEaxHeMYZtnsLQew7qV5EMCHPo4knPFv4ftf2AG35KGLEOjUwHbsTqrEZhYqiRPYYizd9eHzYaxdQrftP90nul0rVzCQqJqtxJ6kkexnz8K7tdAAr9ezf4dQbIsdADYTgmDo3eBvA9utexz4+8QQNvKbX8MGNfmxrusXY75JC9bFacBrSz4W8OzdOKo4i+D2qykE+04RyGTAVIpJTxYr7h+NYb9iBNwZGgNLWcbcxvVeWMWGL9NY7z0HccSVjV5yaNSdYUiwm+XSi9jyzJbfKBhw3Jdbgm1Mb5ulRqNeFApJp9PSLSiPAkJw/li3oAYAGgAIqgGABgB/0HVK4I9U/YWOl53mUgwUST/BhEUUAPnAWWNiQiEG4LhZ6MJmxwYUVFJAGdJ5kCW8nBSE1/uYFrwd88+vgKAsXL0Bgygo4YTo7mMRzxwusCwQYWWIZ64FGxxmS6cBtiJ7fisKPuz+2s8FXVpLVT6CceldYJQUjwSeMrzunsADtn4PgrOphO7HDBgnRDeck27MymK8/tgWbPxBu1gmZVkTBKiyjI1QcjB/ox73L8yDICZpjRtlSLFsTCLbip/c4Dj+PsMWYC/vxvpvWgxB/OlnIahHboRg/PQQnv/wWfBjluRgnUvdTHohIEyxZNjGVqj23/qry7FPh7F+3/4Vals6zEw3psoc5NFr9xEcva6vwZHgrk9Asw0HMb/gNADV3ozPpUPY/5IyCOCePfj7HV/CD8RVpRCw6koIfJxuxCI9VPRHo9jvr09jf5qKMI88uuciCXzexDRs2VAlxB+aFF8nicRpAkEmgvGNHwWglrNRzcpmGBef2gLNvbUOxl0D+dPH1mom8mNhMda5rMwmbjjib0xhXPoufC8ljwJvcGulW1D8cmUBIKH8EZcGABoACKoBgAYAf9B1SsEP9lNWhB9MVRVhXYnG9R+apXW1iBxZVtgtdK4pNnhYxmQVmS6p10N1mpzBwsbYHHIsDEH75Q4Y6RQrNqK+GQxbTtU/xwMGlf4ig0EW0qDb62RDCTwnzw6GUpnMMzoGAHhpG+jdN6Bgx0fX0+jDAJG4yv/wJOAqwLr72aDj8TvhxqzswniaF+GDQVlGnEapSnxM+WU33v/++KWCnr0YqqlsPqlnKal8Fxg1ze9LVbWQqv80k4S8dH+pdN919cK9V8CSXrtY9vujGxD6/LkbENr68oegqnccxnbetQoMqRYgwKc2lwBgZ+k0Op+uXQe36wVr4Ib9839/iOuLcYciXN9hjEPPAiYdLNX2LxsAALdehkAk6eYNjeD75iKW9CKulRVj/i/swP797DsQ2E804bUtB/dX9bhPjRPA9/5ONiYxYH2rGJDjcOH3y2IBn4VZas7CH6YEBT3EcuUyXTpD41+Ypcjk+ELt8Na1NGK9FpfDjRinO9BKfjQyoMpkxDyPMWkqt4ABUPrSnWI/Z3LFGVCnyzwLqr6KJyntpLJs+B9VMEQDAA0ABNUAQAOA3+s6RfWXBT/Y7lARVrqMqhNZMt6wReiEN26MCU5KTIHxbGYsAOtTKD0TWPAL2HhibAp/KMqDard9GI97cjPSO4tr6CarB+PlFsGdYqe7TyWDyVDV9ElA4FGARTxTVMVSbODgn4YqN9gPlfnCWkRg/vDjSFJJsgRYNM0y3QYwgDnNowyNevf9gCr76xjXVR/Ac8YnOB42tyyvxHgG2GjimtcBAGcuwTpUlIBxXC7cr4TFQvWMVZ1mG3APrZq0eSrHx8EHfaNgKJUlzQJerGtgGm63b137M8xzPca964sIoY5vBkN+vhHA0lsCwV5RBkBwOyFwERZCObcVATVFHnz+W/8B1f/MBTVYrwjGGQ3CaDY9DUHavR1ux6c+B7frJa1Yh+EhsFVK9lthc1ZLDgSvyIrnPvw0BOjFnwIY/6KVxU892B8jx+ewYB3Wt2E8ihN8VUjjsO5k81b82chCKI4CsHWKjUPGhrFuqRDGabThuTNcX6PspMLP15VgHS+uwb7t2IXQ6HwaQ/MZIl5YBrex1w/+GBjDkcNmCAmBGYm0CoZXM+prGGcGC6Yowk+tqqosGCKsu/u3//gPCgzSAEADAEE1AMCfNQD4HdcpLb8KSBlTiaSfRMooQn6TakxYkz64xis4eugENjyRxAZ1HMdEfWwPvXopFry8FLpxQSVu+/VHEfATZuhuTTOMU4XlUE09BfncOAoCjWWyiaSawFHCyIALM1W7FANlJhnSWcQQ0BRDZfupyu3/+S9wHy7r9Ag2NM3GIBYnNjyvGc/59f1Ylv4nMP4PvQ/vB4M0IoUYQMSVd+biyLH0SaTNlhLYFtZC4BbUwCiXTxV8nGnEYY5fGv0qGPhkZvpu7yCMfQGWr95zGOvvScN2tPWfkQRkyMfnX70dR6r0j7F+360D3dPE5KpSAFpJMY4IcTYqqWVzzBI3nn+E+xxmOfUQBYbeOyUcxLhffQklvQ58/zHMvxIC3M+jk2phSG0u1tdeCEGzUFK/823s+4lH8fk/X4vnBcjShWzD7nPheVf1AFhtNux/GQuspGT1U7rpmGuV5T+EdpvMmNeJ7jbyIfglx419DqWwv/KHZ3oSgGNXMd7r1oIPZrrh5gyy4UwzQ6b9DA0PRTHfYAiv3VbQiXSzEPRIDGcvvZKGf5oFQ0wGvcgqSqkZseH7XvvDAoM0ANAAQFANADQA+L2uLABY+d95Lb8Y+JO03TBLK929wop13pKoWMH2Y2DEoTEmtbCH1XQAquGiJizUZIAbkQNG2/YmNJxcJqN4uHEONljILYCxzEYjmY4AYGQZ7QyTXuQGG5k8pLKhxfgYjFOLKsFQMRYA+c1zCFDpfABFJCtrcBtvPwQmEQBjGD1QrQuq8b0dr0JF3vMzzOfSVXi+2cTAmRgEx0A3UOUCMMzaB6BqT7kQGtzCEOeVzaypynH3ebGOKo2Rsq21nQEpsuCHniW+evoABPvbIZiLPDjaPPJ9NGGlF1F56RswAub/FIz9ShOOZveU4v2KMgBuDY8CZhuMgYEwPmfiGaSxkq3BJvG80RGsbyIm04Dx+aGDUKmPPIis12YW6Bjx0rZMgFHTnB/DzaIUjG9/FvteeAT7ftm5WH8v3XVlXJ8X+P1/8QJY3Qwxz8vF9xwMbJKFYqIsoJJXiKOmTgcgiURZhv1kW3a6mxkQlSCfxRkw5GPSU5UN4/GkWAqMrd7qWEBl50EWGCnG6xND+GFsWAgAsjutIhBoZKpKILFBn2bJsIzYQJPJKH6pnA6bWNBXn7kdD/o9Lw0ANAAQlwYAGgD8XlcWAHL4X2n8E364LENeMkv9cYeoq3x2RZvgmOpCbHgiQxU8jp2MMfBiyI8NtTPgpaAGgvPoHgj+8TYEiNQsXsQNYXINFzKPyT/OPAiwDAHOyKae0rpDo5/JAgFJ6QgUVN2amPQyNgoV78nNCGi5+6NQlW+4GclKPhYCScao07JVmINeyBNTYLA930fAyRInxpGTA8YKxTEemwzsqcQR4JtvQPD+Y0oso9JcC4YoKMC6pPVsE8703woWnQxEofrWFIGh/Uz7PXAM4y9i446+foz/vOr7BP3nL/RjPjTGPvlVrHvJgzXYp2UwJv6VHUcyYyEYsr4MguFmwMzwFBjWROPq8kZ8P0Hj2Mgonjs8DkA40AH+rDehEMizX0OgTAHTfCdHYCTT53JgCQiwVQfA9cUxn3u/jN+f1jhDcBezRRiPQnU5eP8rbVjn+31Iyskhf1jZDt3CNGDfGNK/ndIImAugSxJIQmwaK91/ks/8DPkN05i8sAGqvY78N3wMR4dz6Bac8REYp7EulZWYRzLBpqxerFteCfa/pCAtNuLYZKOYoJrOCMTQ6zICObMAIKqpWq1mEXOc47aLX5SnHv4GzzbvfGkAoAEA5qsBAPhIA4C3vk5x/0njXz1vIXpCpXVW0d3SNz0kZnRe3UANFi4gVrC5AQxkTLPFFRd6eBoCPcXWW63rUGzz64/DbSKbbZZ6oKqpFGgbv19YiWQZG1VSPdN3DdygRByMIRnSwJjgBI1oMj14GTcuEgFgvbwDKur6EoTKPnA3ylaz7oMS97GFFlVVuxP3SzGg6Y1fY3kKBsBguXkwYobCeJ7dBYEpbYUAPbYPAvwP+0XHNOUseH8Us4t4y/TUXA8ExMH5mzmfeoa2pmmUOn4CSNV5DAy3rx0C98BfIlDn/DOxrsEirP+jX+fz7kTS1eIFyDX58zwAQ78D69yUB0DyMETbKkuEsTWZwoCoeASqcE0xGH+CTUafeB7u4I9v2Crodz8OAUmkGDg0jXmlrVhPAwuvuGnU6z6K5/3q6xDQqzBcxZbDACgz5rOqBYBy01YYKZ8c5VHGQ3cx+cPI0PMUQ6bzymqwP/xB8tOo52cJsFgQ+5imcXmGbk6FacvVXJdxAkCSR4Yr6vEcZxIM9OI+GGNLS3DUGxwF/5+9EhMKhzF+Nwu/TCY9wr86PmUWjJo9Cog87uwPojAGZjLKUbxWRMTc/u0/ZkWUd740ANAAQFANADQAeMcrCwDc4blpv6qiEyp/NGX98CwtNg8I1b/ZdUJwps8LgVqyBBPTm8HAOgpO+wAYtIiqfKIAqv7dW8CwS5ohmE4rGMDA1lgxumOSdKO4mKxipptHuv2iVN3iMYzDqGdBixg2Mkjjz1IWE1V4NHid7a3jAxjHxDYYq0KwWWYFGYIuI4NNHqicThvos3djY81dYMBGFg4JMYbWWYJxltTjht0BfG/j/aJjmrKiFQKXQ/ffYqrWKbYFNxvnlu3uZYuwAgvez6ctbc9hAMG+AyKyVDlwO440NhY9TRJfnv53GBujd2Cf3r8GxsNPG/D854wAtDyWaCsiIBeXY1wxRRpfaeRkyGwkjv2Z4lFhH5u23nYLbFm3Xt+P9R1j++wkxp9iU1gDK4EwZ0d5aSve33E3VOe/uhKf9xHQLSaq4lUQ6POfwVHszTiAbHFlHvkBf09wPT25+F2z5xRwPAxdZui4bM5qy4CP7GaMY3wa86opwvijbB57eATvh2cAIDWo4KVctRT8P8L3wywQk1AAEEsX44fyWDcLkFBEM2pCJAH1eyvEBhn1GRGrrlMyDA3WCUbNz3UJ5H756dvYHfedLw0ANAAQlwYAGgC85XVK0U876ZzQX1XViU4SvphF9IQ6r3lCAIAxDBXSmARjjCVojBqA4F3PRhe7O2CsmqQATLkQ6DPCQJKmWjBmmVT1HTQi+rHA/UeRHWk0Y+FlkdA4QzINPBIYZUENHiFkgYbpSahk9SzJlTKBsTuPAgCm2PKp+8GfCOpm8fMZFgRRGarKmqaKh87R3Y8wxPMZqKqVJjCOrQYAEBtnwZJKzNNWir+vvQcBQfZqjKeCIaNVZbixlUk20hjqJgAMeAloLAFWYMRzurrAaEUGJP889l2ENvvoLDIQAF64EwI+fjsY8OYNAJSfKFBlf+kEQLryANQqA5AsBFyzGQxcVc5QbZbj3n0YST4+piPv3Yn1/o8voC33BzdgfKNsuJLRYz2km9PA0GuDHe//+h4YJaOHIajXnANBHhnHfud7mAZegddrH0Lb8hkj+GpxPY17jPhJ8mgoS9DpCWT+KRgFDUwWUo0Q3GJKgd3GxiszENTLN6EwzSuHcXTc34UWdqkwG52wXHx5GklteiajLWEgVXEeO+OxNVkggf3tPIHP5xfYxQJ2jCBiyqBLi9BgPUODdTqdKCRit1vFg5PJpHjw7s13vWNosAYAGgCISwMADQDe8coCAR1dst23TtSASqkGEfobCvvFCn/0IoMAgO72PsEBMeJGdz/cJQa2esrhhCuqwHDOUuDKffuhehaxtVd5KRbIaoMRTAqAi4FAJzoQKpxkE8cFrShNZUhAoPwM7BgewsaoVE2l+3BspF9QTz6e09IIY1H3cQDYoUNg2O/eiOSZG67FPLxehg4zZFVHoHMUYL17jmC8PQ/VCFoawHMdVSxYEcEGO+hGrDwD47/mFwgEOpw+Q9Amtp5avRCBOI0sFurjUcJHI9QYjWw6lQ0tqBIfOoz5Xd6EkOavfAaAy9wgxY5lUJ74HgRr4JtQmW9aivXbYQEAftnEAKXFECgrQ2RHvCzYQfeYgwFZkRjW3U1jpW8a49y9HSHWL/4LmnVeuBrAMOSjcY7JTioLeTgcBEwH1vnXX0HRUXsfBHLDefh+IAFWruJRqz2K73/wGRRaMTnZ7r2QgVIWAL10XyaibJsewQ+LdBNmjKBGupEXs+FMkoE/sjTbhrXYr/ue3op9H8C6u1ky19sLd3ZuAHy4vBH7aKMxuJxHPTsD25I07u7Ygx+i2ibuz4RDBAZl8VQIUPYoKKy6iRTKiBsUnUDcmtoSwai/efBrTFx/60sDAA0AxKUBgAYAb3m9hfsP7b4VndB54imzKPppVkbEznzwHESs7D40JJTliSmZJknGZJNKP1Wcs87DBhU1rRb0a48iVHVBJXCmsASCSdvfrMqDhSUA2Gjsc7MNszTW5LnYBJJtmZ97CVmURw/CvVjfDGNjNDm3UMjKZVC9u3pgBNpLI9rFdVChf/X/YBSchFwoMtqCtT8VBxuj+cYwrof+DRu3xoH7uyigKRrLCptxh9IWqO5fegyCfk8fmnQub2Y6cDHWYWk9GLmQIdGRJO5n0eE+U14Awev74W7btRuq5xO3osDJBhY4kfGi0hj40L8CiPu/j+df2wLBKl5OYBqhG7cSR4EltRjHNAORBsagqhqMEGTJdWmGAPcMQjBtIQYAfQXu1UVV+OQ4W69JQCWbKOYcNnJhabHnPgsgWsz1K25lEVS6/+qKMf9HjuJ+/7hzA/jHifXLpUQaCGAGeYSx4gcpFcH34z4cTWw8O1aVYL2b2dyzohI0o7LpbBxA9dBzKG8+NoHvM95LiRFgVjgx3jXFWJduJqNVFwIAcguxIceZFj86wlDzPADGWDD+ItbbJRjVZlF/LtY7mRJHAoNBJ7KsPG6n+OV69ZnvvKM7UAMADQAwTg0A8HwNAOZepzT+mOv+U3WifnQgYvrALF1Y6RUAsH4By22P4tabt0L1MXLhSxj6WF5Pt1IJ3HyHfdjAZ3cgbbJ1Adw2BWUspkjjnS4D1ctBI4yLRwILGcJHlT/CZpYlDKUdZjrnoZ2iurJS2YjkkDiNjTJgaOMmYctUOvog+O0doC0OBAJt/jUKXvhYoYyPU1S6ryx2PJdeIuV7t0JlPMMGBmpkUcsgocPupDHQA8Z4jgUxPvIMAoLOWMqQ4CLQNQuxXhaqqGEyXg4FJ0W3pnRj7t0DwBt8AgFAEVk6ksY/Zgsr935sHb6/HX+4eAkQ7qyzMN7r2vH+G2YI4IpmAEVDhUxXxriDLEm2uwOh3BlZUGMEkrCkAOv3nb9AMlJBIQuccP3ScXxOFj6xl2J+g/1Yv0c/hX378PkseEKAMDK/urkBAvWdnRCor29HmXNZNLYgH/Ow82gigcphZXKXEc8fHcf93Sr25eJ1cI+uauWRlQVr0uxe+uBTEPwt+4/zvhi3jgFCuhTWwTIKedhQTr6TbmSGbJto5O4dm+E4caTyODH+Id+YCAUeGKsQG2Axp39BDqQ7UBWMnkymxVmj7Y173rGJqAYAGgCISwMADQDe8soCgI3/ZRlLNP1UWfprwo/y31euToqVacoH4xw/QaMXQ2MTVNEaF8HItLcdxr4BL4bQFsXEZ8JY0KZKukdqoapbqaoZ2OhB9o028QhgoTFHz6KZGaaBlhaAcY60wVjYthMMWFyBI4ZMa41GoPJeuOlibACNah3tMJpFx/rx/V/BGKijOyjo47JT1dMzWdpNd+AjX4Lgls2ANjTSOInby96VSlU9G6IUY90a/+l9glY3QtAW1GP51y2GO0sWJ51mCLVZgWRPk3HbO4FQ9cYtgj56D+gkpqPY2ML1RC/W7+EvQLW3joDh1pUwgGsRApW+zySo+9LnghkYALSIjUAW1mB8pXlY784+GFF7BrDPb+wD0mxqRiOS2z7BUG9uZzABQNfR+McKboo5H/vZfRAD3vxlCOB1l8KYFrbi73YXvte0AILzqcfBN7/uhls1vxiC76CA2R2YpwwJ1sVlM1EMaJwh25W5+Pz15+NoaGEJtn7ZNj2MeT22Fenjaaa5K3pOjEcIK49ofXsBFGUhfL+sAusVTOF7LnaikSHr7Yfhjrzwog2YbwbdX48cKxQ/PTYzGofo9erTeKByUMxLVftn6f7tP37H9GANADQAEFQDAA0A3vLKAoCL/6X7TxESnM7oRNFPbyAlVubG8/VCNy02jAsRGPFjB/NYKkoKmj+C12MBLPh4GpL0xF4ETuQXYqOr2RjDUwTq9EDl0tM6ZKXKn8OjgAyN1RlAAyHo5sUebKA/ju8NDiAwpf8IAGFmEgxqz4HKuP58qN7TbGAxMghAG+zChv3g4ygQ8v7r8feJbgBcWhZKM2Oj82rwcscTmN/wgwhkWlKDv6e44awnoVQvgsCpHox7090wigZyQFvqirkOGGdFMdajgm3TD3SJ/Va8E3BTHjiEEOt/OA/Gv8/dCkaaOs5kKpbX7tyJ9T6+FUct7yAYr4RutrXrMe8RNjL5s0MbMU0PJlhSgHEY7Ph8DVtcKUyWCbGU2/NbgXgfXov1+9bHYJwMBLB+SVNqznqwWrwSNWG87a8CCMOvwcp6zibM1x/FeF10Upfl4Tnr70KrtQnzBkHrKmjkk2ngNqxbhsgdp7EyTqNqIob5rqrDEXI523tvb2eSVS8ALkZ3Z5rWPgf5L5bE+6kojmSydNso+e+sXLzfVAWBH50KzRnX0mYckbftRtKQyYb1bVgIPth50Cg65KgpNcT1emSWZk/Kb5ITxVlk3+s/mlLe4dIAQAMAcIsGAKAaAMy9TgkAqiUVkTbxhHK1eLDFIKwjH9xozAcDdYmRHhvAhp69Asa8WBoL1DOBHbaxxVR5s+gkpnzlfrjpCnKxUQ0NKFJpsbKQiInJGEyPNXCBjUxOsdHdZ+BGhGmdS5GhPB6oWoX5YNgYkzFeexFJKRkH7nvW+k2C+n1Yt26W1BroQkDQR84U66x861vQpceOMnmFIaR6MrKVqzY6Ak7e/m9YvtVcRXs+Phcaw9/LlsJIZGQpr1ufxro94oVRckUjGL+EDUOcTsynmA0uRicAVIcYWt22D+Pd8g0cWdZeAICJkB3CVLEf/xqMW+W5mEdEhcDGn8FRY+MmvC6sZnntF3BUcNQgIGhxHY4AZq6fjwU6ErJhBgtlbGFjl3+59h5BP3UdBGnCi331sWCMqmAfLWbcL+bGfAdeRoCXc1DEu2QBEwLoH2GJryKWa3fgedf8Am7UwTiAo6UGgiwBwE438gwbqoRoDJYh41U5uN/aVhxtFrC119b9/Vi3HTAq6ynYpfkQXCeN1R093eQ3PDfKH6Bj7Wg7/2dn4PmLGZg0xNjsEh45bBT4mAWMtHsfjIuLVoIvtu/zCmv25IReDMxiUX4u1vs/tw4TjPF2zUM1ANAAAPugAQDWXwMAXKckAUkAEE9WVUVwQFa+RACQM88o/EKXrkFlheDwCbGjrx3Ehjew+OGJYbw2enCSWNTCkNJ8qDTff3wzFpJlvusWwujicgIokmFY24wEgnQMKpQs8+3KkwFDNDoy5NfCz8ek0ZCBKguq4NUMR3CfcHyuaj5BgRojPdED1bLVDWPa8/cgqYY5OEpMugMzYDBzHhuU0O32yu2Q/IU5bEKpk2XCucjNGF8BS6jduQXr9I87LhL0jKVgpHwCmJ6lzYpzYHVMhDGPgzRa9u2Fij352q84L46PxsuJKLb3J9cgieXCywAY+UsxoLZ/hbvvzLW4b1UFBO7mnVi3o04UblnEwKRaFgsdZXqrPEKNjwEI+jrg3r3/VqQjv4+ANMICK4Ew98+EdcoprMG6GsHHHT9DiHYpvFxZlZqdsGQLsFZMcDAAwfnkMziqHPMCUCrLoWo7mdwTl0DAgiBxph3LkOYV1VjnFS0AAG8Y72+lIPawxZ2TP1AeE9uGj2KdJmCryx5pYQ0OcX96GSJ8+WKI1Xn1GO/gOOSjiq3eVDY2KasGgO3sGuR0MY+ugUnh9uvrtwj3u8WS+ekszQIAIumypxRSscJZAHjLEmEaAGgAIKgGABoAzLlOAQA6jE42/xScEQplrhcLW28Tr69ZqwhddqoXO/raUaZ5TkJCWmnU6GfrIzWNhQ9YsNCdTAduYFnpomqooAYFkiXLTpsZwqnXswAHjwQ6HgX0KjbSxEgcFwMsPCwi2jkEHVgWDMlxYQOY5atMMjImHKJRJomNHBuAijYxKLwsypGfwLiWoUAFZpjEQh1SzyaVbhayePF2NtYIY/x2NomUn7MyrbiAxUNf6ACj3viq8LIqS5bg+24mjbh44zzOa2wU7rpDdP+dUyAiRpVf/xTuNla0UowM6B4awvfuOxuCfNO/Yl66s3CfnX9J4KnE6+oVuO+jk1ipz+yDgC1vgVtuEVu2ydBgbxDrN9CP9TP6oPr+4h+eEHTNcvDjEGyVWcFjSy8DfgDMhViXMNNtO34C1behGYLkP475W8idi1aA357ch/X9+xdwdIraMK7SYpYBd+L+DjtLqvEopCeQjE+CP6Qq7mJg0LEx3D/ISCodAcMia8My0CfAQCyLE/s0NIaFT9IY6DLjC+VmAJhhGsbvunL8UJ67HOu5laHcehYgWXwGjMGHOgAEYzMzwtg3HagRgmU2pQgAaCE2u2Sk4qz1du3DNQDQAEBQDQA0AJhznZIENL/9t4gZnQllRBrwioVOocuvbsAEx1jiy2CCYMoQz1XNNfj7JCbuTWNDDk5iIbd3QnWtyMfCFbAVlYWCbGV7axtVfgPfd7A8td6A1x4KvIVFJMNMC7Vx4W3MKjoxg4WVhSFkwIedSSdRFgdNsMDGgU4ZGgzN6pl/vl/QdavB8BNDPJp4WDaaxkcXA6j3PETVvR3zK6uBoOtdDBllOmtpMZ7bNYXxXvhDGCVzmtEGvaQIwFDB5JF8CWw9ENBtuwHAt9+E8X3ywzBispeoYmSy0hvP4vtP3AhB/twvcaTRXQyGfeRivL/UhvkvpDEwUc2klh9tELSY6dyN1dgvM4F4iu20jx7DfBY6YZu657MorSYbrYwHadRN4f4qj2BGCvZ4G+53/EEcidZ/APwzM0nAIHI3efD9Lz2Bdf423ZWykExxKd7PJXAW52O/B7z8geG4g0yvTlLQbQqOZtLLG+X/kgxxNvIHJ5liEVMTgCTN5LIgjc2xAH74Kksx32oTgLFMYUhzEvPum2A6sg38sHsPgLkgB4zUugzp0KOhmIj1HpksFxtptaRRIuy37cMlAAjEyALAW7YM0wBAAwBBNQDQAGDOlQUAqRXLFmBMAlJEbOVMWHfFLF3VaBJ+vDIHGC2TxnMaKlm6iYEWVhqtJqYZcGEArrw5Ax1sawfcJqU2LGheIQOAuGFWblBuMY4IKq1r0igoy4IXO8xzGCNBP2CYgl7ENuLpjCyowTRlAoxs9VTkxOtkGAy39QAA6vARJNl8dtOTgn751n5B2VdCSSXxYJ0RG2rNA+3ahfEFX8dGNi6BYJCPFAOBwB7Elsimkzc9CbfbSM4GQZc1sb21G0eXBNOZ27ohuEcOYDyH7r9LUEbqKuzgpeiAH8qr90Og2j6PdOxP3o8QVc/N+P63LoQRtjWBfTv7SgzUiR6UytlPwX07lYNCGIuqIbGFLBY6xTbgL++GYF7UAr68//PbsF8FLBQSgvEwE5KCQEEqwbxGdmDAgS3gp4VXAOjCAbpd2cy1yooJ3vIcxvWrgTPBD4UYTx4LbUh3sEknG8XQiMofqhiNx1G2cTcpsikp+CpCY3KMbk6yjRLhAqfT+LtMWtu4DMbL5fU0OjNCuLcHhVHOoHT96jEYlwcn8AN6/QUIZNq2D3LRdRz89/5L4d6M6FJiw7fsRciU264Kf7ZOpyDLKssKpCJmOgsAb5kUpAGABgCCagCgAcCc65Q0YAkAQvfIAoDgmCwAiFDgMxr1IpKkxoON8foxwzwW11RZ/FBxgGGnxmkMYbbMCyMsXjmCiVfm0r1Vw+aITAJyMHDITNVehppaZddIpo9a6ZZJsgBJhsZDEwOEDDTSOQgoMpDGyCPEABnXzw1OxbFuXiYH9XZCAFqLkFT01P0ITJno4bBSVBbJYKw1qQSmMK7OB2AMravkEcDD5qHloOwvokSHsS5//wLSXzenYZRbVg8VMs1YWRPPGqMsuBGbgIAdfggFTFQuF21zisrA7mf/GUlZ0z/C0eLqu8CA9R/H/H7+9xCknG4cFRY0AuEKq7Eun9kFgN4ShJGypRqC7KEbKxrHRF58HQDwsQ2PCnrnF+DGm+Y8w0EabxPJOePVc1uHnoQK76TbzpKP/YiNAGjdDryeYrb6bQeRzHWIyVdmllxzMUkpqQMfSsFtKeNR1U+jJY8EGRaW0TEwSwYI6aW5mPwm28wHpDvZzyag9O9+9FoYWa86D4C0eaeI4FWefhwBaJ++EgCxi+7bnTuhubfz9aozYfw8azVU/0SUgEXr9H88geZuuR69iKTT63UvYIBKG6m4URYAWARu7qUBgAYAgmoAoAHAnOuURiASAJgGrGyYpTMR3aWzdN0Cg+DQcheMT+MDmHguW0bFLSzmydDGXjbfdOeCE98Ig8GO82hQW4ANKapBKLB01+iZXikLTFgosEYb/m5jYZCK/LmlwiZD2KAgAzGSVJnlzIuZrORiee0RP+4vjVgyYCfMUM2jdG9WmrGR2+99TFDaCpWQX7oDacwiv+i5mq//DEeYRdW4r4XFLqNjLBlWinXwGEB/tBOf//zrYOyVi3EEyGNz0HgU9+nohCCc24By2/f/C8YXlwFATFP2MyD0keuhYpZ2QnVf+VUYARf/Ndx+j38XgjfzFM4QZ6zCvhWWgo+2cLwf2opxLWoAIFQW4MgWDgOYDh/G/b56/c8F/dtbADBDTC9WY1j/jEobFdN7jQT+7nsw/7JKrL/KUOPMydBdLOxRFUeW58JorBI1gA/SDBn3sNy2hUbinkmsVwkLhAyN4/7TYfBLmm4+PSOoVJb00pvx/QIaq9NxmfSE7w9NyhZwfo6PP4hsRz5Md6KvB4FR16ymeLGm3AVnIY258zDcg4V12O9Kplt3d8NNaWEBk5/8Cl1f83NNIpLOoNchpj6LgaQSABhyNvfSAEADANxXAwBBNQDglQUAKq8KzUgnAUD4pWZiBqGTnlGZFrpJpR0qfIYdMnw+LOSxYUx4YSVURJUBMG5Wo3yKgSXDdIPVVbMlFtN/HQQOnY5GP6r0srCDrLpYyg2JTCFQoq8HqlReLVTZuloEFuVaKaDc2JEAGCFIhopH8TrFsuI6VqxI0T3UdpSRKwGEqD7xr0i2YZyTMsGGHxmmhbKatGLLxX8O/hrrUEh3kZUNPFI0UhotGF99EQTtlV7M8+J7cASobWKglAcMEAph3O37ML6ffA7uv5vfD0ELygZRLOsyPQyBeeoGGJMaGfpa8wW4mxb9JYyJu5+DALV/D6rn8jImBdUzgKUSz6v+Do4AlWzgUlcCRh/3slhoN9brh3+LkmQf+RDcXEOIc8kKKMajMzDAxkpjbAbA1H0H7ldWhe9FeUZIE9Eq3ACmV8ZwZOwuvRX7XAI+KmQnFzdDynvHcZ/XjuLI6mMyUJhA6nHQOMnGM5aT7eXx99AM1qeyvID3xfiqCwDIr+5ByS95FD3eDbexdwb3kyXonGxNdv1yAOf4BBDx7FX44Wushr92lEfZdJRuwmHwRVE95nfnfR1iIgX5ZhQF1eue4YAPkvbP/pMFgLdsFaYBgAYAgmoAoAHAnOstAICtwE4CwCWz9IyyFEqBlWAjAnT7HWgf40aCodMssGBjgYeVy2AUeaQPgtY/BQarrYaqk1cCamfLL9kO3M2GIbKWVCLE4onciBCbgba9jNJTjORUShuRTlpeDUltbYbxJaRio0b9TN5wYiML7QwBHcTRZmQcG++fYFLHMQDMFy8HY//9LXguI3KVZIytrWikM7MN98gOjDMzDMDyeOgWjbGoaAk22jOAz7f78f5NL6GVmtENo11pAUuCTUOA2xkA9ObD9wm6pIVlwrntRqZ0dW2GyrvtFhwB1jfgcyW3wGZU9hEI7Eg31uXZv0G68LmL8bmCCjByfi3Gfe4dANhhFUbF2hKsn9fPJKxpuLHu+izSqC+/EAw91M9tpM00I41sPCqFmUY99gsAi7MVzxtOYf6FhXjuygLc92e7AFiDRf8KPkzjOWU8UqZZY2zES2MpW4L1jWDD6A0+2TIuw4Hp2Xw2xRJdMar8Tpb4aq2FCi+Tz44eg8Dnsiz9iRNDXA/w9+QQgNlhwj7f+zcfEvT4CSCi24Lxlefj+9EYm79OYiOjDIDTswDLLx8bwBHAYxJnOP1/BgBxltAAQAMAcWkAoAHAqdfvAwDzioFKADAK68/qyoTQWWoKIPCHh2n8iGECFhN0T5keGgliAS+5HCrtgz2YcNcIxledh8872WLKTj+azQEVzsXQXyM3JMlkHR2NgoWlYBjZSqz/CJJQOva9xudD9ZIlwAqKGavLNOLKUryuagSDJXS4bzwIRklwHtt2grEvrAUD3ns7AIFZnUqMxjcjOVvPcuFhH+4XOYzn2A34YCZDoGBrMTtOTspMEq//ejMYf/sQ0ndrS/D+ME8kORk8f+8vsP/EsZPGST0B4MgvAIDBhxhanAujkvvD+H7xRzlP3vfVL2MdFleCYXMYqlzA5393O1Thf9uOcS2owJFldAL7U+EWVayVn3weNStbGnAf4qkS4xHJYmarLhcGHDrE0NzNDChbgrTYeN77BT2jEvxl9f5I0P/3Oo4MnfqbME+2goswPbu5DipzlEU7ZVNQlevuYCkuH42/CR4RZXnypGxZxqNaPAm+bSrGuEdGsPHJGPhx2ot1lKHlIRaoGSQAmGj0/ObNkIMUnxsOjHH/wPdhtkl//DWEUl90AX44wwref+HlGQEAuW6DiOQ6BQCkEbB/9p8sADB/eu6lAYAGAIJqAKABwJzrLY4AQsfLAoDIspiJm8TIV5ZHhC5dZsSCT45jYaeCWKgZNq5Y0FAjaIZFPUMMFNlFRgm48JiGemy0kckVMmBDz9DdnHwYR+w5YDwzVaI0AzLcOVAFDQyU0dnxuoituVQWFtm5E4DQ3QaAMDFZKMNQzwq2C1/EMubeMWycjwB2vB+fW1oMd9tTX0VosJfLPD/uUqeX/cnxnOkdmK+JDUKMdqYH00hqpoqYZ8FzPv8wjiw/fBNHmbJqzG+kF/P/84u2CnrnrQgxjcpAGxbd1LEE2ZZvoBBLSReOUiYjALvkk2xeeTWOcuwzcrKUmYPlwst5ZCiswzx29UNFvexBMOaZCwDQbUexTusWIyL18W8iLTmRhjtuYLqYz4fRy27AipncANSJzZiXrgPIZV4B4HKVXYN9jsEIO3IcgViPT4v6NEqyfIOgrx/EvuzrxX4XF8jWYBDYIrrlZkJ4roHpvEmmBUfo9lP5w2C2QOU2Z/C5MAPE4hHZeYtuQ7qrXfwB8k/gCDA2QqMsy4grQazzmhK2sKNb12LF8wcYGGdiOvyuPZjnzdeKLHylahEChH75GJAnz/OfAOC02wA0AFA0ANAA4E8HABg6crIl2NxAoLhJGAHPrIyLQKCCGIwYBhMWykM3Sd8IVMxypq/u3PcmJ4aFPRrHxoxY8ZiWVhid9Gm6xSggNiZt5FFlNzNQRK9m5iycPAqkGSociWHD6sohcDXlMNoEY9jAF55CYY8cBhTZGbgU5veKctjyisbF3mHMZyqAz29cBob64nWPC9pYgueO+RDIkbExJPlkvwgIbuAABEDnhQAlWFrMXk3VNI7P1TH09c7NGPdnXmBxTBoBQ2yCeedXUQDkLy+HO8kfx9YmqQJH2HDjhU+hVdZSHklSBOiSj+JI47kSjEnNVWl/HOsWfaVG0IWXseGLHR8IRjHws+6AUVG2bT/aDlX4+kuw3w/dBYEcHYAgj3j/P3vvHSBXXbWP3zu97Oxs7zWbbDrpnZKAARJ6E6VJE4RXRbB3QFRAEVEEQQQUpArSQ0sIIb33sslmN9t7mZmdXn7LeZ5PSPYbNBTfV37e+0c+mZ2Zez/lnGdOP2jYMaL881w/ApgGUiga2rmI51CL/U2WsABKOo2CPRuwLs7j+ehNuE8GGpe0t2H/V7JAismJ7+expJorDee6ayMqaHU0QgUaPvN0nhf2RbX+slgwn2DAR3oE/eYzjTzJpLNuFjCJ8XVvG0J6YwwM6uxhwREr3v/iHIR6t/SC4TdvQrn6YTQu7t8Dvqooh/t33slYn5Vuzbv/uEdUgJxsq8Ry/5NAIAMAZCMNAJDRAAADAIT+tA+5jpAMJDMdBACZQV9Il52aOcIqwJCXQgBOUzPcUaUsceRkC6Y+tkHeuadexgmTIYpuHIBI+N4GZNMUj0XATl5hBQiKSUAOpv2qhhEuTxZXoEpqgSF1FmhI0LgTodvG48FBTaoE4OSwuePby5AGG+1t5t8zeVA4aCubO3YxYCjIpI8du3FgFYX4/M+vwfdPPgmE0lkPI1Ao8vph86EkqfVuZQONJoy2DDCWKZ1ltVux3mHpkOVfqsP8P/8YVBMtwciefqxvxZNotz1zNF63K8mUyT+Nq/GfLTfj+1PGqrLpuG/W+WAA13GwzqlqMC2bcY7NzyAgaMJpTKNNARDtZlgrv/gwgOmNnXTT9gJwvnopAOD3twNg9kPT0Jq7YMybNAGBO6nYKhkbDiCNuZNp03v7wfAjxyDQZ3QljHnWPb/Culow7+tWnIPPp2CMnF6NffWzSayP+6UCvOxezDNExvP5wJi5hQAoFeKr052ojM4JqgoTKvD9OFWG9dsQ2huhkVCVC0/FVXIRWK1+J1S04WwKe+vXobrU7YVK09GAoqPjuN5UnI1McjB/N42Du2vh//3Ts+1CaDlZZiE08wfJQFs5fmrZgAYAaAYAGADw3wMAQwuCiBXqYEGQoFkKgswebxd/Urofosv27TAGllTg4EbR/dLnY4un/TCKTJkAgqph3uffn14pY8EEGLtKq+F+SmPIryrYEWJfbhPTNc38e1YeRCQLi4bGqEKoxiATKmA8PHEclkN+1na1Yl+2rUHb8Eg/CGJYGea9fR8OpJ6hrWNYBnv7rnoZm1rAaTdfCca58WsAur4GiPj+TqTnJhJgFCvdcb31FHE3A4iKRoDR+xuAu2Yb5l/CEOLdHUC+c/4Mo1zzXuzv8Ml47pL7UXAjhwDTTQDQyY87/oJ56+9VyOixgoEjPswj/xKIzGknY556kmmnPhBc3YN4bj4LxLlcEGnTc7HeO97Duf3qL+x8wtJot18PuvjujRBl63ayiGkfAmBGVEEVCEdhLOzsxTxDdQAsezrWPXIcjIxhNkPN6ZcamNorLyHg64LnoNqEcwFE44YD6J0OqoRuTLyjBsZIsx10VTwa940HYZwLMQQ4QfrxMr3Z64KqVklG/OKxAIrfvQY+27gbdG1m5FkiRFWB7sXQANPJKeKPoUrzvcsQSt1Ct+HEaswz1Yf9jcVB59tZhtylGok0orbes4tQ7C3LaxY/q8mkg5A/KAiiAOATVwQyAEAzAMAAgP8eAFBSoDICqpJgKAoa1MUfM3ucXWTKvBRE+CjTNbNZhPFAKzZ0Qw1E5LJcMMakKhBKLTtVPPkWRKCyargB0yj6D/S18yCwYZ5M3NfD9E5V2ou2QM3BFlV5BWwvzoiYMRV0B9Jos6sB82oP0SjXBuDqbUYop5vuooZGAE4fy4WPHA5gONCMA12zEaLj2dOx/id/DPdiTw/cNIk0GG3iITBojI0tVOGLnpexD1aKqroLQOMsx+gJMwS1D0d18bMgvPfewXjOFSDAP38bhJVi0coBqkK6G+PORwG4+WEgQrQDomwigM9nXAigc88FIer9QBKTDeuu+xtEUi9DZF05+HsGVZeVB7DfZ9yMEmbp5QCYp26DirVgfh/3E/ufioBRbSYwSiDKENmsB2SMNEF0TtUi2SoQoQhvxecnF+C5f3gN5/bV18HIHpX05WGpOKqGljTQS/1WAPIA66RPnH8R1sP3u5ugo3iZhh4nUAQZQJTGUOG7r56N9a0AsL22AudgtSi3NBA4xrbzvi7Qf18rnptHP+uZ00BP5aSrscX4oYpShVCFSNbWg87MTHPfvWefEOb2Wq8s1ONKCRLquqaKgu7gqEqCfeyqwAYAaAYAGADw3wcAqhLy0MYgYmXxBXXx30yosohxcGIJFnygucuJBYDAJtPoVt+GjXC4wZC1TTQilYBRHn8bDORlO++CMjCGn+m9LpYCKxsJ42F6jmpKic/7uml8JOMnUyCQ448BQcTofktj4Y+l20HwDV3Yl+njMY/dK+FFqW8EYeXl4zkpioTRMAhwgASxYRdez58AgPrDlSj1lMMQUdswlObyt6NwiL8f7iqdRUCbn2fSE4tS2nPYoiyA1w66A/Nzsb8XPQO30YsvgyF//Ru4/266EPNt7eKRpoFQw0zK2forfD6fgVhWJpOkfLi/8wwQcsZpzGZqY6htGiTHt39fIWOJDYxSMAbG0EwL7hPQAKgV3wJjuNOwL6sehEQ6shoqThtDjJOqLguBMMWGHanmi/F+L4uB1qFUWUcHvFq5uZjXhDww0m3LAIQ3L0b59EIW0HC42YCFredU6a7atZiPlUa5wjKce/FoGA9j/MGZOQbr1RmK/sIqGPnqdmOf7rgKz8suxvnd9jgBnoFmyj0dC+B1PwEn1M/CLSNBL9V54Iexo6D6dHZjnltqQc9nzIJqVd+Gc7F58QP31tINwhi9oRLZEKct+VeZr64txY7+P41BlFn4sMsAAAMAZDQAwACAI16DQMBWEgcBQGS8gahJrDh56SGR2U8ZY5WJ7NnXKSfXz2SHkyeBkV9+DwdYXgIjR1URCCmvBAd4xS8RwWjJBQOPm4xWSBFuqI3uuNwyMLSFRkATjX6q8MapsyDqrt8OUb6ahUhqKULPGs5mpR0wqqzZh4NZMBPNMJc8fY+Ma1cj+aJyHETa1h7MY/woMFJvLwi8qQXjnEkQab++EIEss2aBUFNpaIXV03i7jOEAAoZS3np8/zW2++5j4ROTaq/NA2I68PhR+MNN74JQfvc37Nuif8D9d+p0MCSzWwcREkPjJgBk/b0g1PI8EJiDabLBJoagngWCKz4PKk+yk6HJDEWuextGR0s/9imHiqHHiXXEnGCMyTfh3LrZDr75BczPZmNgTC8mlqLor+ptmDKw/rbFKKLpzUe58oidTVSdOPeJOaCryLYrZbz+OUzkL+ukRq02dipem9PZAiyTBTfqIRHvX4uq2XlFWE9WPozCVWNR3ryQJcmOHcfCK+lsofYK3JTrtmO9C06AO3XeNASu3fE0VJ0u0oklqaqwYuxqRkCQrw4qxjcvBYDMGokfmDeWwji5fR8AqLEZKlFJFs7p+HkA1qqJOPdHnlkuN/J14xfVYdce5n6uJAXs4ig3+sjNQdVlAIABAO9fBgD8lwHAEdqDD+MolB6KmtAePC0ifz9pjFUYP+T3y85v3oUFOJj8UliJAyliQwgnI3pGjEAyyFf+jA3sHcBjh9MYqPprF5SBsZ0ZmI6eZAMGhh7nZ0PkLqSRz2ShESfGZA+2Bc9KA2CoAJ+Vu6BiFBeBQZwhHMDjf31QxjSGGE+eiPTZ7DTct70bRsBWP9Y34AOhXDXvMRmvuxgqRl8EyRvhEGtgmTG/qAmirW87CNS8n0k7JMAEAYAVz7QqL87vjsUg2Lu3A0Bf/y2KeU7Mw3609bNYaikIb82jEIntq3O4j2xYYgXj728CQx4YD8ZaeBkA0cv9DSUADJ178bnYNqhgmdlsjJECYadlg1G/8ggYdTnTnlvfxPxaGvC8YBQEbdVU8hP2O2pDK6/aRfgBKJ8EBnH3QMVJH8EkoErQQeeSL8l4zq8ZCNWPYqDTpoNudDvoobcPiHhgC4yz0Va4OzOY7l02EW64PJajH56B/S/OwTnlMv185S64+aJs4RVIgE4znDi39TVQwQb8UH1tBPJYEMa7VgbIxRoAAHdcjZJsvd3Y78dfRUjy+afh72OrYRS8/8/4wUjLA52ctHCujC8t2iRWx2gEdfetVk0IbxAAkDU0+FvMUTZ4EADYkuTwywAAAwBkNADAAIAjXoNAQGFSq+A4ARuhSSCQyW4WGei4EUmhzM7aXfL5aXMgIqWT0BIs4eV1YmP21GFDS8pwYL9/R7XeAnBk5eEAs0vxfsUoMKCZBUYsLBXW7acRbhI2LJsts7IY+ru+BiJtJhuUWB0spx0Dg+xlck+C7rPLToWo9cff/hwHTn/difOw8acdh/TgZasR4vrOCmRdbtgGhpg5HEa/J27Fc7v6MM8wjZAWK0TPeAoHHotBpQi8wXLUfoqObA7pLsd+5bNwyN+WQ2VYNYD7/eh/4FbM8+JzfgUcVNw23w8VrFhjshTdg24/xjf3ABgeI/D8+oc4l2nVAJjeThBsTycIu/1lkEFeER5gSsC9lcUAoUffhUj7ug/rWPIw3GONtSz2yRJsKi3a5ATQRBNCToMqERiq6BjM27caqlMwhQcMn4Kko8YGJBdd+wxUtE0tShXEvrvSwLjhKObtdOD1AEN/i8dCVSkcDtFfBYBF2N47l0VXz5uH+z+7AhL1sCLsV2UBfogONGL9q/fguaEB0IGJIcBRliXvaAZAWP14zvdPwz46uR33PI5GMzOnwMg7rAJAuGojVNnhVTBWegkES9YFxe9rTqGaqsWiISJqUHvlKLHXg4zP0jJHvgwAMABARgMADAA44jUIACwupZVyFA5IJDSx1vjjFhmPGxaXGSZ7sNCqiSDsKcfAKBPow0H0tMMduKcJIlGbDwTQkPBwwdhQO8tEO+n2qBwHN40tHQwwYThE9npW4fziCcN54CDkKgZUvL0dBO1jySWHBwdoYRLH7gMQCStZiuz0E2Dkem4FvCg2hnLaCDzzGEq8cXe9jGuWQESt3YV1T6jGfe/+BtJVvS7Mrz+Cv6eYF5w04bkJG4yHofdYiqsNgGZi229HFpOdqBptq2Va6kgYm2bMA4BZiBuMG9LCQagqnW+zGCpViN7duH9JFhj81XqMV6/E/Z+7He6ss08CgB9ohhvKlHxCxpbnsH8ZTKYx29nOmhErWxpA0Tvo5rzxYrh32Q9DaXQHLzOTzqORb2Kf1mIfM9k+vaEWDOXg/uXbcYO+TNDVr7cAsFcxOatuD+hfT+FzGbn4YVDJPUGWdhszF6HIZhaCGejGPuaxMMeoSjDapj2gR8ZpaUm693QWDOll5RWVjq4xzb2/E3TnZpn3SsZoZ6WwX207EJBUOgw/cDOrodq8tQzzT7FAzNgRoOvCHIybdm+VN9bXeuSX0mlH4Q+Trr3ACWziqAqB9Gr/5DIAwAAAGQ0AMADgiNchpcFUSLBqEip1qvsCScnrnHlMmljzrD6I8DYPFnzWqWh15O8D4TW2AgA62rGBqvRSXjVEn5v/BtHYzLRKLYH3j5mGZI+K4dioBdOwIeUUyXJzwfArt8HY5mUSyIZ9mE9DE0S0oBlAU1QIRg4GMJ+ZVfh7LkOMX9oE42AkwrLQpIBsL1ue0Qi0dydDcDsZ4unF5759zuMyzp2N/e8KovhjNADjoZUqSVgDQQZWIvDFMkDbDZuextku3GxlXFY3XnuPZz/yMraz7gInJd24T38zPh9dDVE6r4Slrg5gP8oLKmR8fB8Y5H/ux/ncd89TMn7pLJzHvnYwflkpSp7VPXM/zpfuSZ2t2FTBE4eG/UyOw76l5eP8oixNloqDoVXotiUNgBGKIr03uvQ3WG8B06/XA/grWIa8z4rvdzgAbNc+h3PTM0CeFhaP7WwAgHfUYT+jfiBQ4RgARulIiv4M1LGwff1HbQce5g+JlUVDkwkATYgFZNKpWhVxnadNgOpQwCSvHftx/h4WZmlpZlLQHBhbm8gvJjPmt2bDMvnl3NtRLKq2256UGmq6rqkkIJUGrEKAj9gSTF0GABgAIKMBAAYAHPE6JClIhQSLqD8IAGKN8QWS4g4cOzpdVINheehk4NKxcROPgZtv8bswmvmDLMigk8ADWHg5jRy/WQ5jywAbclRUgcEvv+RCGeceiwPU2bBBtXHuZX3pfnZ42LwboqSZxTh314PwTVxyBkXgkeW4/5gyBAypMs4vroLo2hfAc3KyAWiq/LOPraRCA2Ac3/4dJBSI6Hd+GYEjZ85CXEZX7DQZEyYAhSMdqkYgikCZwHYAXGILymfbSqH60BunBfZhnbFOAEfOmXSzjgZhRgMQJe3M121fRZ1gPQjIytJkdmWMZJvpm7cDAB5/Dc+78RYUSb3zBmVU/An2zY7s0salv8e57WWyUAGA158AoGazQYarGsZD0yg8P97NZJ4ky8aTmMwZ0CyD9TAC6k6G1O4H2UVXYZ/NZUyzbcDrfSxx9vlXkU5cMhLrLiiD6hlL4f0tS9CWPIOh46NnLMD7IexbfzeA1JMNlfLjtgN3OLAfMRr9UiweGuMPSH8zCqJcc1yFjGUFoLsEW44Fu7Ev5iQBhUBWx5ZiI8bjh2/Ra2+Im6+lq0h0M4ct+WeZnq4t45aqtuDCQB+WBKQuAwAMAJDRAAADAI54HRIQxBpccAcOAoBQ8EAIKkB+oUs4eM5Yq8hiid4OWYkrEyLikndAQLleEEJ3lDUKQxCRTpqCdM4n94BBdr6DUNwvfxMBH9+54XIcMMuCP7MYgPLKSoh4x08AAwQpqu+oA4DMnQIA8oeYZMNCDStrYDQ6ZiTcchMrIUJOYUGGu1/A/XccwAFMGwGj14bNkLDms4nj3k4c8JOPPSpjnhMi929uglHp+HFLQBAa7htOgoFtbhBkMAGG9zVfAYJZhCKl1gIyTAgEGKzHMcT7IErmnAPjlGsmm5h2g4BtuRSBV7G8OtNIAxRZHQEW2WRb9K+8CoJevQcE9m3Y4rRfXgdg8rGstS/M5phdmE90SwXun4H1JDOgMqTRKJawYf8cx+Ec4ix6Sv7SLKr5PFudRTuxPgsbo4TXIuQ1fmCfdugVbcO6trqwnqtehipQSgXV7sL6nPRLxljow+Ml+bJgh78NKl6YzTfz6I7+uO3Aw1Hcx8oWdRqL0rbWw41nDgCwr5kKejOzsUcnA9UqqcJ6WEKvtYPFZ9kyroJu0XfX7hF/YXebXQjIZtOEYAYBYBW3aGgA0BFDgNVlAIABADIaAGAAwD+9BoGA5SW1Mo4i8sfjKZGpgjFdVIILPpcjQNDVBJGnqQNGL5cLIs/+/SRcBoDMmsS2zjVgtP0hbMzWFmzsFZ+XDmTasbNhtBk3DKLm315BKO1qhhyfMANuq/4YDjjOllrTxkLEPHYcNn5rHTZWuY1ibN2VT2A6YSwo6TmqIo29OKAShhpHaAy66hQkgVz7BySXtB7AeqtoTPr2JQCMBcfXy2hKQSXx9YKgknYQdox1GwZ6rpEx+CYAwUoRMsLy42aW+oq1g3MyTsK6XVMJpD4AbcQMQu97FWMajaFROwg4lwFQHcwWOuNBEHqHGcba687EOd12NWxK8fBSGZnjoqWcAK74dgBG3AdVycUisLFOBsAEwfjOeTC+qaaf2gD2OZVi+fNMrM/NdvL9KQBJePHhkasxKwtnsJ36O9343lVLEdJbmMF0baZtWx1Yn4XuW9ViLhbBvloYEJVdCmPyJ20H3tmHc0jweWEfvtfZgP0ZnwOVahQLrLgdOK92JpWx9qhWRiSLkjW9uWD8SBLGwZXb4kJIZl0XRjeZNLHODk57PSdey1EYbxAAkto/uQwAMAAArw0AkNEAgA+5juAOZJnwlNS86uiOSYGQk09EPe/yDCy0ZR8Ifz9DSddswvzOPQEEdyJDa596BiJ/QSEY9m224U5jaS43Rbv58xAKupNAksGQ32GVEBlX7QfBpdiOPI3JO58/EQARJF01dg7w4DEGI5CUxpbiYPY3sMz3DATCrNgNgu4ZYJtspqn+/R3s+7SxVEEaITLb4mDQ229AiHNJEdbVHwYn+3qlfoMW66kHAaQhDdaHiFDN3I1AInMmGNfiwTmGG3AM6bPxHCvThHXaqvpaAZT+p7APDjcDibJAuPkJ7MvrteDIS15m71cL9jE/H39f9FsEpEwYDrdqQwsDmWwg/PAWMITGYqeWTBB+tJ6BThStnTPZMotltPUeAoJGhslQyIAr3gOGHHgE80zqdJuW4vv5dA8vPQBg+9r+s3EemZifKwv7fLTuPBvLy3/SduCBANuOE2C6O0AvSTavvfZEln5jqPG+VvwQxeJYx3vroFpWV4OOx4wEf4wcwfT2rYuFcbbuz5YFOu26+GsHAeAtbp1qBabcf0dsBjr0MgDAAAB80QAAzMsAgCNfhzQKYaFpTU5qUJISivMNJCS2cni1VyZ47DGIFW3bu1eeMb4aG/eP1xE4M34YNqSyCsaPLTtA0LkswfXmLojofWy6OLwcIuBACgzdQU7+0WULZRw7Agd//W8RsOJ04ODtNqYfu0Cgl58CwLGm2KihC8acTDZcKCuAO+yVVUyC6YHodf5cfG/xNhzsDBZyKEZNRu2JdxF40rgfgPfc0yhw8twvYJM5+3OqWOdVMvq7kCabCtSDcNJJqDtgFEvthTFQc2PfQq1grCCzinPOxHPTZmGfdAcItnMn3FzJxfAK6WxIQk1A81rw+t6tIPw7V4/hc2grasBzHv8jvn/xaRCNG5sBwPEECDjSDq9wqgX3MWeDsZNsKRJvZnnzcqzLORnnlfRhf3QbS4A5QofRWXjtfKx3+SrtSFcxRfTb92P/H29HoJA7H/fLKWY68FG682wsGvpJ24EnWCquIBMAX7Mfod6ZLMF25gScYxMLfWgmAMjGPSzl1gs6mzkV66mugpE5Pwfrem3pctEp2rvSxXpps+pPynJ0bR23RllL5SAGASCmHcVlAIABAHyOAQDyOQMAjnwd4g7M4FjBUSg2FkuJLDYQiwunXHR2lcgysQ6IwLOPYYMQdqxoQV8DrbIct1u7E4zlTsProA7RdwObi5bmg9AGGDJZ34MD+fL5IBgzy4P/4lEY0VSasS0DAT5mir6nTkfA0fzpMD6GqSrE2UFk4ggQ9i+eAAGuYGmwxffBP/bQm3BnxlgY4iQe7K2PwSjZyeKNbz6Pugy3XLFUxh9cxoISHqQZB8NQMZJRnFswRWNgDQKd4qvghtMZsNS3g4TLoppZC7H+jPn0r+V8XYau97Ae0/pHsW4ngM2ZYMERGre+9Q7m/VIjCM1O71WExaS//y2s/7avQWXrYKmxUAgqQDKEdNr4HlonvQjh1r1Mf64HeTjSGYg0vYX7BtHWRBXBlMkHOq6TwbcMf08sR0iyvfzIJPrjt2DUfXMPG8gwVa1iAgKDjtad56MI/i/bgYfxfiSk+OrwduDVbtC12w4AbGyH6jKFoeouJgENBPCDM30MNOm6A3hdlIsDcKThnDfUgO5TTH574U1YE51miwT6mM26JP8MAoAK/a3nKDccBICUdhSXAQAGAMhoAIABAEd1HZIeTOsRkoOSSRgD+/pjEho89/gCeb+ikCGsvdiQcB8OJkHjm5aBBW9hgZBMF0Tw/CKoCDs7sPFWtmOexNZhLrpj/FEcYLMPDFnfjo3OygOBJ1h6LMl24FWlbCziwjJGFgFwKgtxv0lVAIxXV0PWbmoHMH3vIpSoWrQe+3z7UxDhrzsdxsUdtRAJt+wDY7/8CoDj9EKI0n/8HpOext8gY28A1r5Igo0kzDjHSAsYpOdJZHXqSiQNMJmGrbwy5mO/shYASOOZABb/K1BdEjuYHcoQVU+SDVBCOPIzXwNANlkwel0g3P492MezTkRE6UM/hzGQFdS0fkrsyQAYMLKfjJx2OOOE92IfoxEApvdMEHowiYCvaBCh0N58lF7T3Zh//ztMkx4CADmQlLVmuu8ufh3zbstE0sz0ufgh+KjuvJ1toIuD7cAjoEuLme68AZavT+Lv+SUV+Dx/MOYOx/n5fQC6TVtgFIzRqDwmD/vR3oJ19bJRyIRKsk8f9tvMJDNHBvbRmslGJq24z9JlbXLgGV6rxDabTPq7XKAq/invf1gLsA+7DAAwAEBGAwAMADiq65CmocoYqFqGiTEwHElI1o7LY5L3zz5zssj+r/wdxrlIL9Mk2eKoPwECHjcWjL2vERt0/llInjl+Poo2Pvcm1ttEo90F85E888oSMOLynZCNsxh6rIw6qi23KQQCSMuC8ajPgunfdyPcSFlOMMDGWnzune0IFS1jabIfXwjjzDPLsN/3vQIGvWgujGiXnojx1r8i9PeR5+lGy4YIfccpUAkmXvCojC3NaIsdC4Mw6K3SgkGsu+8J2HaSnQCgaAyAZWJhjIy59TLmnAfRMxACA0XeRGMSkx+qRTKO+XsT2IfaHpY4W4T1OAvAqDYW0OhvwT6U5WKdb/wayTklPG1GPmtJHYwU3Y/7xTsRemth2/A4CTvcAxJLXwDGdI+nkbD1NhmzM74qY5f1Lhn9j6KsusnUdRjd5RCB1u2DUeziZaAXswMq26jpcA8frTuvmT9IbjdUAquZ6+gF0tisDHFmSbFkEDpQ5RgAzr4WfP/2q5Hm/exbUIFKckB/552MlnDL3kJA1d9fRKm44Uzy2r4DQOE1A4h8URYWIf2efj6KnL7w0kaZUNCfFOOew25WLcCU8U+F/irj3z8N/R16GQBgAICMBgAYAHBU1yHpwapYqAoNlqyMRCIlO+ILRGUHzluI2NqeHojG29cgXqGyDAvNpwi+biMINm4DIV3yhXNkvOiLp8t4zU9QMOL5x1Em+fIrL8D99uJ7NQfAuLksUGGxYaNdhQgscZgYomqC26ekEgx73UK43TI94MCnl2I/m7sATJ1UVf50A4Do9meR3tvYA5Hx8vkgxAvnwKj48KsQ/b/1e7gBJ5VhPXfN/62ME0+HyNvaKH0ctLAPhUN0GuviLsyn4yncN7Ud6awpO4xGSZbb9s4FsGRdCWNcsA4ttaJv/BL3M7EcehIiaHoMdPF2PV5fvlTquWieYhqf6Cfs7CD90F234QEAynjYCrXGTroDnSjjnWjH9619YNhkEKpJpBOAnOzBfttnAlDd4AttYCsA0Fb0uoyhjquxzvd+eUS6GwoAZz6O+edPwrkNHwuV4l+588LsuBJlGnd3az32M52l4pJ438RQZSeNh2EfACCPIeMhJv+Mr4ZR+dGHcU7nXgK6ffDWb8v4xJOgg8efAt1aolAVp00GXba3ADDrGjCOY0h7Fn+onntth/wCpKfZ5BfQbNbf4Jao0l9UjjRZ0IeV//6wywAAAwCwPwYAgG4MAPjn1yHuQNZhPhgarFqHycmEwnGhyOJiROIsmDNaZM3Fi2AUm1gJI1JRFRi1nUUvd9azhFQYG37BBWjf/LeXQShvPHEHHwfGypoAN5A9HUaTwipsYPkwhFR29SBwRY9hLC2EyOjOwBiL4qDPnIEDcdPY2E5r1y+eBUPfddVcGf/B8tBFeQAa1Ub6lInAwSeWAOBuf+glHGgFCPOu838t44zJmGc4ifmFg7i/mQweomrk24YAp8ircO8lktgvLQxG8EwBoHquADAObEIgTmLp3fgcS5/Zzbifg9U471iNdd9fA2NcVjkbdViVMYsFKnZCxP3HvQhIOuM47EtTM/bFnAEVLBLC+mJ7QOh2D4xzgRoYNYOIA9OcJ4Cxss6HcbfvLTb+mApjbaQWRtf4imeOSHcKAG5fAuPZPctQrjt/An6PRkwEIHyYOy85AIDq94HRBvqxvjjTdhU9JKL4/kA39lcnoJQXYp9aSU8h3qdnyxbOEIx9ykXflfHiM5DE9uyzKKlmcwC4xlSwkQ3btrfUQuXdXAd3+UkL0BJt0QpEwjU3Y4JOh0Wl/S7nA2s4tnKUgzla95+6DAAwAEBGAwAMAPhI1yGqALNCDm8dFoulRHZPmmIiPJ45DxU7tm2Heyk/Cxs+dnwlDwxTaWVrqwO78DkLRbAoRbhd68AwOxho4SplSal+bOSYOWitlJ0Ot0oywJZMFIwWnAERra8fIuDWAyCMWePAkJOqACwqjfbnf4Px8ZKTATQ2K0T1TCdEywQbXOxpAmC1dMDY9dQraHU2ZxwY5OwpMAqeOBJFNe0mHHQsDYRj1dgyTMP3fP0/wzwf+JOMcSabpAiUacdANcn9DlSL6GYkF0UYuGTJpGgfxv4l6Cb9/Cs4pk1xMFAO3VQKAKIUbbvXgBG+cx3ciT+8iq3CAhDtB0xMikmB0M374NY0W3GugRqI/AP7sS7XDNw/7xKoKs33g+Gzv4B9De+D8TSxUvW1IHGR8buYtv3lJzH/zQkUAikr5v1LkDRz0J3H5B8T+4+nVKMOGvViVAGUkdjtBaB3soBHoBPznzENRr8BlrBbzzLwLparDzbic2MZqDZ6GoDVxsIj8SgBZDRCyQu92F8Vor1jG4zA7WwfPn4cPvfSO1tkg0xJ6x6cj/4Kt0SJ/gwK14SAP6rory4DAAwAwPMNAJDRAICjvA5RBRgLqhVxlEiWVCoFVSCYEBm+ssotJzF1yjGyUytWwm0yim2ax0yAMaUrgdvt24n12QZwIKMnwtg1cRasSC2NMP7d/SeIWLlFcGe1dwEI9m6BsW7EGBTuSDlBmCedgjbSdSw62twLQvdmQkRTjFBdDPdQiEVMzXQTedwQ+ceV4f15EzF/2ti0miYwyJ2PgiEq2Mop34b5XjsXRj93DIzp9+D5ZhqrEg4YIZMOuMeafwcCS+yFChRjww/HSIjCxd8DQ2k7fydDeF8f5wsC9TBkNc4Jjr2fRsNsMExuFtyLugXri7B0WN8ejGccB5XnT9+GO0u3It24JwCGSLkBuAoAoo1LMZ8EziPeC1XEVgigdV6MQKgD9+O+5VfAfRd651asu/Hw9GAFAOqqfhiqR8wClSm3EueaWwgAVyG+OitsRBkAFmUor68fjJbDtuE2ppl3kZ7aDiA02UwGLWexWGcazjufbdU7W3DON34ZKmoRC4tsXoUfjF2bAWRRN4y5w8cAuHLMmMfOLSggs7sFov+c2VjX+g1b5ZetrnZAFuB0mYXAdV1Xoj9jpzVmFWlyw48q+qvLAAADAEAIBgDIaADAR7wOKRSiioaqNGGRfZPJlEQ0RLWY7MBpJ08Vmf3Nv6OXYSCAg7rshu/gAHphzNq4Dum111+OctGZ2dj4cePgvtNTOOgffPNHOJgyEMQjrwFYLDT6heyY1nEL0aY7zvTNOI07Ovtv6xbYNFt8MJZdOg/PcTGt+PmVIJApTBaqplFo1li4a97agIOcUAmNaNU2fP7FJVRlfACcJ38AET0jCYCLWCkC07ajs3y35kGAScezUHEi7/1BxtgACNZzHNt0LwQjJ3bADRVj2rAKZc2tAAPs3gfgOP5PKDziZBHUNC8ZlMBno/Gsbh9UrBIdEufKB16T0ZsFI2tnG0NmvRSRm6DKxTeimWfKBYI3M9nKlMa22Rc8gnO+F+efs5AFORoAjEMBIL8c328/gL+PvxX0kD8VPxTl4wkgDAFOsCSY14P1m6jSdHZj/60s2RYdwOeDfWBkN8+5qYHl5BlAZDKTRRKglysWIlmrvQH3+8VdCGhK6djf7dtBt70s833fozAGT54GeirIRETVX++5E/ufhn0/+XyUvX/1zfVI99WsUAFM+tCSXyrtV5X8imif4DIAwAAAGQ0AMADgY12HhAaroqH0V6Fo6KAqIBQXjSYECNLT0VFjTPUEkbmXr1wqHz7jAgSCNHfBKLb4Val3oJ06HweeiEC0LWS78CsvgzFv+lSoBAUlEIn3djDUuASME2cZ7hNOk+rlWkcNIigLivG+2QMGdrNJZHUJCPL8Y6GSvLQOATcvroax5jimcRZkQgQ+aVKFjDc9iHUsYJvyboaa3vkAAkDGDAOj3H0xQl1nsEBGJAWjUbAHxrZEAOs3FUBU7143V8bQywiVtXupqkwCI9rJIKkDSLqJ+8nIbEqZ7gEDPLIGIuyP34bx0TOSZaiZfp3L5BMb26RvWAsRNrkd9139GiTPY8aCsDuZHuwPIkLI6v2ejAPLkTYdBN5ruWasJ9oPiTU58jIZ29+FClA8B6J4snH1EelLqQBP7gXj3PQ3MKACgKpJWE93E7xiHgZUFeUCoJu78UOQjAIYA1312K84m8+yWGg0ABUlxDTlKAuIhFRjjyYEOI2g+7eNr9euh8j/8F9xzq2NAHazHZ97/S0AwEmnoRlpcQ7W+/KzoINjZ+N8d9ZskR31+RCTbrOZyfj6Ym6FavhxgKMs7KOG/g69DAAwAEBGAwAMAPhY1yGlwtwcVWCQWD8GVQE5oUFVQKxv8URYZLPjFnxOjIatdTgQkw344esHwRzYDUb15CDEduoEGFlWrkGhiis+j6SZzfvZmskKEfOtt6EC9HtpvNFBQBYn7j++AASeWwicOqBXyBhlQ5FzZ+LvlUwCuv91BHpUFYCBVPHQCRVQBW46D+6on/4F81qzh+dD49O2nSBMPY7P/+wiEMqFCyCidlGU1Cwg1Hgvvh8L4/NhB0JKLashatpYjDSmg8ESThCuzQbAsRSw37YPIq21C0f8s+XYj4d2goGyysHw6VkAgkwCS0cTJMzmGtLbbuzXYw/DPXnWBDyP9Vw0fwpGwKISqjK9S/FGOp7jZnNXPwu49LFp576XAKjVx3sOm38iW8WX4cpiaTEVAPRAE5KYvFlg3OpJeE6wA6L7KLZ627QPon2UzV9jdAtamPSkSoa57GzSylDfJEX9kAZVIUgg8PbjfvM/B2NdOIZ5ThwGRn/kGST7zJ4BlWT9FuyjvwvnXz4KxtN0LwGPjXEKK0F/7y16WxDSYkaNtEHRXyrbHNLyazdHFfgjOtjRlv76sMsAAB0HYACAAQDvXwYAHOV1hJBgUt7BJqKjOcoJpZIpyR6JRuOy4sJRhXIis489RYBg0Qtw5xWNRDJMzVJs6O4auMW+cxvaRgdCYKz2BmzwT777DRlffAtusl2bwLB53NjX10CE7amH22VsHgjnhAVIMkrkI/CilarDQBiEkVSBR00wFp07A0D08jocaGE28O6PX0PI7oOvotjpqh31eE4xCHvvPoiKr7yMeb1yBwjt1HkAus4uhMyG67Gu7nUsnpkHlSXtZKzP3AaR0V8PUbxlExgmnQRYWMKSYQ1gXGuS5dRZpPPny3As920Hgaaz/HlBMQDPxP7etdvhPk3RDRbfhfve/iO4AcdVn/C/On8PVZL/JwSYKsCocQCefdugsrgcON+ePpwn64doNof6fcL84iEAg073KHu/DorgOH9vGX5wTp0BN3IHf6hGT8LzzpqPAKhb70AgVj4/n+YEcNz5o5swv2qoSNVz8YPVsgf7teBsuA9XLn9DGL91d6tM3GazyIN0k/4OJ7ySoyr80cFRNf38WCHA6jIAwAAAGQ0AwLsGABzldQTjnwKCfI4SEGQymcSalUgkhPKS0WSFHIw5IQAw77x5YoUb8GH+r/8dQOCMs4UTN3T+5UgfzS/G7WdVAW98fZBFK0ahlNa6Fdi3Yjsko5t/i2SWESPgpvrH6yDkOfMgut7yExiv+lio5P5Xwah9AYiKlfkIqY3RiLS9EaKgL4z7Xz4PANLYCaDYRob/8qksI75KzlNb/hqSXBY/AtWmPBfralqHdYfacD+fC4TV3s3Q1B2M/IyCYaIBnHuIjVPcLEBRcQZEzLJ8iOj6NgTmZDhwxI/vAwB87w0wcPZoxG0V0Rja1wUjXU87VRh2GhnYgufd/l0UKT1noeP/ZP7PHMA8lREw53ioQKU5YGxfC34oupm+bbOxzbYVqpBK+vH3wc3sQdV6LY3G0vYaAPjZJ4Mu9u6FinLzNxi6HIGqMG0O0qDrdwPI0jNAH6tqcf/2ZtDHW48i+SvOH6wQ3cynng/Gd6djXe88945kHekJs0zYZDMJwZjNZtEpk8mkio1WAUAsC6upeuqfyBhoAIABAFivAQAyGgBwlNchAUDZHA8PCU6lRHYyWcxysol4YgoWBBUhFArIhLNL4mI0nHH8V7AhZJQpcyCqTp4Jo8u+RqRnutkc8pSZCP3s6aDbjCLssnfgltnOhgu7V8O99MUrpHOZ9gJLN7VZMc3vfhPlqPvYmKGmFUYrCwNApg+HTXNtTSv/DpG6uZvFSg9+Dgz28CswBo6mO3FvLQj9xs8h2eW62QgE6m/FtrUHABS1tWCgll0AomQ33EkmM9ZrIgHpTD7S2NjEYsK5R+N4nTsdbsVRJzBdeSeKa9a2gFFP/AdCoYtGQ0NL9+AY21vqZTSzi2cgjPuG92Ldv/mO/z9q/nMXoPx3cxsYuqMRqpnd6eB9AWAmHc9LsZXXQH/nYecb1+k2ZCmzs1lq7slHQIejZsLoOG4k3LvHzwOAJllsNouh3m+shrt4II7nDS+Fe3njatDbhhWgi3kLQYdrlv1Rxu4mi2yw04mqqoO3FRHfbDFLb7hBVRS/GLoOXXZICPD7t5D7f8yAIAMADADAPAwAkNEAgKO8BgFAWVWUyC8yVSqVEs6yWK2TedKyg3E2DInH8UyzBdaYshGdwmFtrdjIMeMgCu7bh3WfePYVMjb0sAkmjVPJNjTPHD0aQHDvXSiE8a1bEDDT0gNR8I5rYeybMQGBM7ZqHGhLBow7VXkgmDgDQOw0FnndLBLJMtFTRwIIdjQwEMaH/U6mADwLJ1fIeN8LOPCarQCmU6fivP52FUNMwyDAXXux3o1sBtrXyBJfXqwvjWW6md06uF8sbWUGYcfJQMkYRrOOefipEnmqYSybthDAZG/Hg858CYUzeh0INErFAXwDvWznnYbPd8Jbq411Y5/f/X7vf9T8Vz5xn4zjLkbocYLJPha2gAv3q37mABi3G5pqhwrUIZCbGQI9qgwMntqPiNs1W1DY5bsPIAu3KAt08eufItDpq9+8EfuwC+s2FWC+Kq29jElWS15A6PPw4aDrndsZiFYI+mjYmysbn4jDWmuxIHvLYrXQD6vLL1g8FhMdRdd1BQCdHEUlGAQA1tn/aJcBAAYAyGgAgAEAH+kaBABVFFSlAQuHJJNJsbaledMkGSgajkogUCwaE5koEoX7IivdJgu94WrUwrruVtg6rr3++zL6aJRqagFhFk5ACanuXjDe3rf/gs+xvXYaA1Hcboh0Z19wiYytu+H++/NdP5AxZwxEVtc4hJDamObrYnloi12F0mLMd4KCZ7H9dw2TYFRBkdpGGK2mjAAOpqVDdN20HG7JG0cjxLckAQB45w0QRk4GC6FE8PckA1RsTojgOhtb9PvBGCYGNLnIWDaNZbcTZCQ2/tBtdHMxrddmR0hsxRS40d51AjB/uAhuTVsUz1dNNHUL9q/LD4Jf8oVX/qPm/5oZbrU2DSrAy++BUdPSoHKF4rhvsZ2lvUI4rw6Wkw+HYKxzpLEQCtN8LZ2go66d4LurvvkL0N0ohIS/8CySlQYGWIa9Ccbi9KwKGUd87ksyZrNNeesWqHwlRfjhSM8BmzxwH4qe3v8TAPA9D0WEwHt8UdkIuw3udKvNKjqvzWGTQKBAf0CQyWQywTr5QUCQMMrRtgMfehkAYAAA1m0AANZtAMDRXYcAQOmh4yAAyI45XU6x4sUSMUkGSkQSQhmhqCYnm+6EKPirH6KH18/uhZFkWzMO5guXonDEzo1w6/X7IfHsW4fXY0ZBpM8bBsbv3g8bybCpSKPdX4vXk8dB1F/19nPYNR9DUtNhxCooxPRHjIEIV1GKA9t2AABUmg6RMocNG8IRELqVxq3lW8AA1cW43+dPxrySmx6TsfdNAFVGCe4fYEhqIgJVoq8HBT9SbNttZnJK2M8y1jTtuBx0t7E0lgv4qSWYLBMKgrGUbzbCQiBOtkc3JcBgHZkgxEfaqKENYF/tTIdNmsDgiQRUg1953/mPmH8/Q2+Xp8FI1x4HMDhYxNVixftZmWBoStSarw3nM3YsgGPXdgTiBPwAhO4+uCczGApcyPOe9TkEMm1kMtSwKtDR/vUoCZY9jAFC+wEEO3cDiIZPg5vQ64GbccxkvH7qsXtkHF8MYPrxV2Hk/vbPO4TQfKE414sYZLPdHAWdWRdjf0LCIIMAsJdb1HjoaACAAQAyGgBgAMBHuT5NABArSiqVkiQgi80q/pJB0U9OLBxCDawwVQCzDr/PnTehf3dXCCLnD9mKKnvUXBlPOw1pvzsWQwSra8KBnnkRkmQC3TCmxC0giFQSB9+wHwe99lUU1bzqRiTT9AxABHzgLw/ImF6BEM7jjsXzTDQO1e5nKS66r0pyIGJubQChfPcCGHW6/QCUXXVQBb50MgjjFrYX37QWRqJvfBWtnkJsD/3eekR27tzICE9lLWMAi0bjIiNhPxiZtKQl+L5qgmnlaGJuFo2ZJjJksoettsKgExcLUVj5vXgYbj5PNtxXjEvROvtoW2JRTY3ltDUG2GgswaXRmFbARigJptt2NpFO/Xx+FM9PT2Iff/w9GNX2alApuljENNvFZCa6CVesxn56PTDmZTN9eeLoChnf3YV5BQJYx9hKqGTrd2L/KytKuM3Y5/eWL5XRV89SbV+6VsYslnz7890oNDP9tC/LWDYMIeo624Fb4gDAtGys96UnUJ69sgTGxLEnQQV99VUkf3XvxvN+/i0UZMlxYl+/8xtUJEkQQR1UARxOqyw8mdLFqhyPxt7FcesqKUg1BDEAQDbIAAB+zgCA9y8DAI7u+iQAMLRNuABBKpmS2kcmq1lkH2+6S/Jl/f6QLMzvi8pC3R5YaS4/PQ6VgcaYxgAY8ObfI4Dn7AvgBhw3HKLre2x+mVsOkTQjDQQRZkMNM91Ldhfbh3chgKiJxR6/eC5CO2v3IS31rgcBECNnQbS0O8E47e1gVG8uCGnOaCwzzPvf/1W0CgtSdDv/NszrWH5u1Ta4m2qbIGLPGIn7ZHhAYLv2Y157W0G4drrJ3DbrYQcTpyhsZekyldyigMzlYEkzFhWll1TzurH+CBn0wF6EujqdxG0L240n8L4qGuqwY/1xMkqKbjQL3XeJBBjbYsU6Ugy0MbOVVjpFcjsZpc8Hhgz6sM6BToRKV2Tie+ddC6Pva9vBUCYbyMruUHFmyl2IeY4qhWjd0ENjHoEozJBbVTimM4iN6O9C7kx+PlS4CI2Ce1bBXfvNa8DgVcNRsuvJ5xE6XlKO0HJPDgAxEmQZcRozHWzm2UfA6TwAd+lxJ58r4/Z9UCFfeBZuwJu/BvdzaRr2JRSAm/LRVywi0g/4I6L7etJtsmCPxykL7PcFN2H9CdHFdJO+kxujVICP1RZcXQYAGACA5xgAIKMBAEd5DQLA0PRf4dBBAmVXy5T42VxpDuEs3YweVeEQKjGMG18lIsy5p5iEk3agE5KWWwZ32/OLwUCvPozkna/f9lPcth8i28Z9SFqZfDzae3d1gcCad6J+goV+ra4GhIi21EMUPP6My2WsLobotmYNCGFHJ91G5LCcPDDycVMh0vdEwGC3XA6jztQR+H6IHUdmfA2NOaaPBsGcPg2a0W+fBZANKwQB7toPguz347zSXCD0ARavdJgp6zOgJMgAJdVowkFR20frWmYaVJRoDCpBX0j9nUkyPjBW/Q6I0Oksf55eQDceESPQq0KqU/w760wwZDbFUGulmiQVYBC4HTQC6mTAaBT7kpsFwOlg+WuNqkVlGfa31wpgdDnwuTD330zgK87H/QfCZJwUAMal4fkDEahgVWwy20XjI3OVBlUtGPG6OgA8bqpMY3NhbJ4xA8Bf04z1L3v5URmLKuAuzSmDuzQe53zGwH2cQ5Vw4zK4eScPR1q17oVK+bsf3SLjaVfih+Lck0DXnQ2g67HolKc9/0ZSCHz7tlrRHRxOdK9NEWmDgTAIVNeXYThYGEQFBAlBDQKASg/+SJcBAAYAyGgAgAEAH+k6pBSYl2MuR1lpKpUSK9mgxCxWD5vFKjKVbraKNai8NE9k43NOc0h+pzUPBJmVjY35+x8R+vmH36OddtVsJInc9B20zNq66i0Ze3tA4OkjkCa6/T0ciO8A3DP5pRUyTp0O48uavdi33lrs67kXoFijIw0HtGUD3F67umG08ubCLRjhMn98JdJdlWg8thz498ZaGPNuewyls352NQKX2lkKq6ENIuSqPSDEABk1zwvC72MDEhtF2hjLlttVyCpzaFQDkQgLlliteCNMAAmyDHd+BtukE0+aGAIbUMkwDPixuWgsJPDEKSIPUqAMUYrWJqoAJgJRLIjP6fy7w4bvO3SWATcBmGwmzEul48bsIJNhBWDAliDdeCzZlmAptVAI++bJwf739ACg09PwfFcYgJ+kSqOStKIsz21Ht2ytvxPxMqOzUSpswhQAeDiA/Xj+WRSfzawCEMwYAVVz/VoYo9sb6/Hccribxx2HHxzfXtTpyMwCXRwza76Mv7nzxzLWrkTS1P987RoZz/8K0ox7uvFDF+tAPM8/Xg3LjQ40diCUPhGTiUbjMdFZBzUOmYiu64gh/qAlmAoFFgb4uKXBDAAwAEBGAwAMAPhI1yHNQVUhkKEtwmTHBoFAODOZTElNpGQKIo43zSETv+hCb4X83QsGNEVxm9celJqI2vBhIJBVbJ5otuBzZ30expt17+BzvTT6JCkituzEAU2cg/TNpl3Yv6LpKM3kIUEE6+AutLCJ5PEnosTX88+BMBa9+CJWMwYANGsijEWONBz8Dy/G/U+aCJG//BK06KoqgoowZTREw+21sNm0MxApyAIjehxAoFPkd9N4pzpimZgkE1IMTxFW59F5nCp9VxmlmEzjUiG7AIIE/YhdTHv2t8OLFGKrLJ0PTFC0TxCA4jQimq3YV7cHom8/Q7UjUQCB3QYgccOGpRXkYX+72mHs7GqqI7GAwYedCzdbkoFVCYrykQGoEAk28LAzwCdIwCzPwTm1NEClsFAlcqbjeWt3sG/GTjDggrPgfj33PAD9siVocBJPgV9clXDv+Qn4LWtRiq5kNNy8m1cgvbxozGyeB/Yl04V1TpuH9OQXn/kT9w38OYvNb/ftx+cXXoPPJW0AMlM/PvfE0/31sp+BsJfnLRtuMukykUHGVyXBVB/yoenAqiTY/1l3YAMANAMADAD4LwMAdR2iCiggOKxF2OAlWQ+DQCAyUCSSkCQhp9shlHr11RViNevsgwi49XWmS1pxQNd9DUaUiB1TPe8mtMDyx/H5a29AQNC+dTAWPvdnlGI64TwEdtQzKUM1wJh2KtyA8RQYLcjAnHY21rCz4EisXc5FK6oGIby8HCpDXwP3fyzcOtedNxfzOAevf/oIRMctB8CImQwt7WcgjlmJ3gz4ibFdtU7jl41uSBsDeFJkXNXyKs1OFYHGOq8bjJIkw/qY7BJPKmMaAESlvdrsLMxBN2DQB3dUgKXA2uvgLu3rhqqSlQ9gs1NE12kMbGlARGqKor2Xn0uh0puWm475m+g2bK4DY7pSAIzZX0DRzJYwAL+fyT8R7odGVcdkwfqqsvF7k+/FOmrrYbRrbce+9tRABbO4sb4zjoVI38JGMNb8CtyfBTvyy2HcdZEuLDrOa93rcAP6SRcVTEJ79zkEjp13FUrTDZ8GunzgHgQAeVjW/bnfXID9imD/7/896LIthnkfcyroKTcDn3/ooXpByNBAWAjSbjdL0s8g4zPRWlMlwQ5rCaZ9wPj/MX0BDADQDAAwAOC/DwBUkKq619AWYSJjDQLA3PfHcDAmMpnd4xCKveGns8Xq1/AWRNKWZRDdqqZAhCqbheSambPk61pdC0TKhVejueKwYqRrnvsFlPZa/drD2CUaqeaejBJMKRa5bG4GYcciYCjGsWguEvheVrho3YvkjmNPhMpQVoU04hVboTK8u4c5GWyrvXC24JrWzWKiO3bjvNLopvPkwO2lajdHegEkKm3WyqQXizLKcb4Ovk6S8ZxuMEyCKkGSpa5c6Zh/jKqArqyG/F4syRZibHWlGmBYGTLsYPHVeBTv71yFNOC+NuxXBktfJen2TPD7ZgKZy4HvO+14rlIdAj0wwpls2AcvjWkqWSdF4LMzSUkRkb+LxtIAAGHsKPyeZKcBABcthbvXFAVwTGVR2JOmQVVrqEVa7/IlEOkLR4CORkyGMS4YAgPS1qlZOe/iYpyTTiPv0jdRGiyL5zBz4ZUyPv/U/TLubwYdvPYQmttWFsENvHrVUsxjFeiodgNUraLjMb+y+QgZvueWlWIVjPgRA+1wWVVLsKXciq0cD2sJpkhpEADon/14lwEABgDgOQYAyGgAwCe8BgFB9XdWxkA5mcGDlgoOA8GYxEq60hwSkXLPL+aLyrD+bwhUyWZpJmclRMqGPhDA1NkoBZVrxoZv2YJ22vc8j7gID91446fC2FK3BftXsx4qQPWJaA+emQk34/ZlIIxiBh411qB8dU8rgKhi4lwZm/YhhJb9JD4oUbYfoZ8rd4LR++1QKVxkZHME52QmheWPQOiyKxNurV42wFAH4MoCg/k7cM5KBfAWIiAlyeSaRIxtthmKG/JDIrQ6AQw2MrLZqspiM16LgT3hIOYVHYD7NM5SWirGOLtk1KHL1Xa+hzTqiB+fdzGN2urAff39qjWbneeAvydpVE3SiKdZMS9PHn4Xgj0Q4RUgZpYBYIMsTda+F/ubIEIn7AC4oFI5IhDZZ48BMJQNw/6qElzEF61kONKe6zeDHrIKQV+l1Wjp1szAnHHHA+h7e+Gmq1mCYqTVU6ECVE4APWxbD6Ozn27EG87Ffk2YAPrsTOAHaf1K0GdZBtYfqoMRuJvtx6dejHTgG37wlhxgMBAW66zbZZWY8kEAeI9bo8qBq8IfUe1TvAwAMAAA7xsAgHMxAOCTXYe0DFNNQqX+9CAAiFVmIBiV/F6Xw1bx/vjUr78gVpiVbwIANIpao06G+2bYGBCMvx+iXt0WiH7FHhBuAduAv7EeG/vU0wzQKIVRrqEW+7dtFYwxGXkUNcmYZhMkqM5mHGhXO3Itjl3wVRlzKiGyDvTCjbWHgUIDfrjTrvj+nzE/Mta7DC3evZMNMZi2m1ECoFEhxjYGsKgAmyQZNNCG5yhA8GQX8qCwrYkQG2zQbWZhSbMIjVYWAoedgKCMjhrdickkA4zotlMts/o6QaARriuTqpWFyTn1W+AOC/TB6BajiB8ewLoLRoCBc8vgJk3x/oEeMJRi+DSGIJuYtqxUkWgIDK1CdvuaGO/CAKVRY8CwJzB01+MCIDzyy6tkdHsATCMZ6OPOZHpxHbxnyxfdi/3Px/xyi9lclaXIVFJTH+pzaONnwchXVgXVopfty79wIdyBp0wFkLQx3bnZj/2unMD2617s2/6dAPTdb9KdTNV09skAgC986yk5uGA4Wi/zdtkkf3gQAEBIH7QEE2T8uC3APuwyAMAAABkNADAA4FO5/hUABAJhAQCbCSHDf/rFNcIJLb0grIwcBNg0xUEguUVg2OnVFTLu2QmRf9bkUYctoK4NxsEHH8NG17A9s60Mbhc/Sz9tWoL3e5tZzjkCgi+pgpEoboYIW1aN14XVeI7NrkJOIYHVbgCgNLbh+2OPQaixl4EwNUw/7mKb6dpWiLapBEVthrjaXSxOqdx0ZDhHGp4X6gFBJiMAwMwC7AP7UhwscBEjA+lkcD8ZzmpTojeeZ+YXzQQeO91gCRYk6Wsl4zHtOTO/kvcDY7YzuUo1+igYzhJoNEX1ttXjfQbyOLNwfmEGKEVptIvFAHiRIIC8uwv7ozP5qKoQ881h4FA103P7kU2u7dgKd2tpARi/agoYNo7Kc4MAiee11oBeGmpgjLMw/bmpFq+TdrZHL4aqNelE/PB4MuDNjjbAjVjN9vTXXIr3Kwtg7FPcuGojnjNyDOhlbQ32obMF51diwXr7uqBKFWUicOnLP3hQJhpNIsQ3Lc1hAIAckAEAMhoAYAAAx88MAKgQ4QKOcnKDhAoA8A1IpER2GU7u7mfvEn/f7k1gyLF5GcJhA339clJr9xwQGdbjRQ+r008AwfU0geFXht2yIXde/h3ZaVsSWTFfPO8kDw4oKt/bN2ATTlNpuDvXQpTPy4FRcMIMlJlOUVTWYmwskY7klQMHIMomExC9MxjQsmYlCNHixn066kgwo2F8OuXS78roY6jpuo2I69haA4BI2ZVbD+63NA8Iw8qAnf6OehlzSiow33yInv1tEC3tLGHlpXFRFc5IUMUJ9iJnxMxQYyXSK8BxsmGGj4FKkRBUCVWgRRXbNNPdGaMRboAFPiIs6+0tgKrWwRDjribM25uHeceosgT8hwdE6REAwDHVYPBpk1EuO52h2m88doeMNbtgjM2rBKDHB3AeM2YDePt0ldSE+ZaXs1+NjzkzVqxHTwEAt6yBja2jC/cZM10V88T+DHdHZWK6ZpODefK5xaLrRE2o2PKdR+8UZJvtGJANyCoBILzyLoDF3++X700fWS6jO8MrB7Wjo08QatQkAM6NF3xT/IPdDfglSUt3P4t1mBUAKCOgIPrHDfn9sMsAAAMAMD8DADBfAwA+2XVI23AWCEkRAJJiHQkOBEUFOOnKL8jJ3HDlAvGfPPcWNu54tuAaX4QD+8szS2QD/rpkregGl1xytljRRoyqkPcXv75WrHYv/vEvIrMN0rmc8OWXnikUccZ5C2V87uU3hXLfWbNFDiInC4wUaMb+hiIg6F4GuuQzDbhyBAizfjcIcMMqGBmDvQjsmLnwfBndJjBw5QQQ0t4NMJrt3g2jYk4u21kXQeTcxwIdo2aj6GlrO+63nyJjez1F8SBERo2Mq1GE1WjsSyuDaJqTDwJU6cLONHxeZ4iwUiFMDCXuaMH9VdKPl8k06UzHDrD4Z3czjZI0usUZuNTDpKJoH+cX5ryoQmkU9TUXVLr8Cqx/GFW6wnwEeu1eiaKZw8fCKNbYgvt2dWJ+o0bBaDdiCpKu6rbQCJvE+le/9nc8JhP3mzILRrqKUQDgur0433amBWcyfdpph4ifVozz7eoBcM2bMUEWct4ZJ8tCXn7uNUH6Rx97ScZkCrHVZ33lS7JBJ506XSa4d3e9fP/xx18QXemyE6fLxnzp8yfKA7a14Adl2R7M47z5+CG75+FF4i9c/PBT8kvjcrtkQ0xmEwuA6EPdgB+rDfiHXQYAGAAgowEABgB8KtchACAUeRAA4gk5wVA4IoFAF/3qFqGsy6cUSyWFV9cgMOa4YTjI6opS2egffv12EcUe3tMlMuRZ584XCg1b7bLR6+57SCjaokN219mv2+FEn+grr79M5nPFF2cJxTzy9Nvy+uXnUVBk4RlnyljXDHfOiveYPERGcVnBUK50EHLDXthkkhpE4hRLUzVtgSpwyjU/l9GSDg1ox1q4LSMDUBna9zG3gyJx2UgEsBQPAyPbGIq7fiVE1KrZKEDS2gFRtXE3IkODDqgODsWwJPB4A1QpLSub81C5WUw/ptkqdmAP58FAoGKUvkoj8AUYEKMFmZzjYECPCgGmEdLmAlA7w1hf6Sik1xbmYV61K9EibepsqFhRhg4374eRtmEPAn40qjz5w6EC2N0Q6cdOh1st7oNR840HfyhjyYSTuB4WKtFgZCsbgbbnQZZCC7JUmp9px3OOY2BPMdzHr738koxnnIuCHldc+DlZ4CNPrpKDePi+v8rrcAhZVqkYrLjxFHSJaddfLTd2xCLyw/Ti82/Jxl05MkcW9PPffU8Oqqa+UT7/HkvCnTYDbtNHNzQLIT7x7Z+KtdXpsEsgkMliVmXAFQCIzmsAgAEAMhoAYADAp3H9OwFAuQGVEVBOMkAVoGjKJFEBfnnL14QyMmw4oEwbolAHwqi88IPv3yMnuOSVJXIAaW5XmBMXinfnZNa/P1rtDhyQlhJZtqO1UyjBzpZer618RGTSUXZNekT99R9I+lm/p0Xu3x6AIysjO1/m38eQ4FUsQ26JgcCPnwlRtS+BZb7+NFqAlVVDVJ3ABiN9fojEa19Bemn1NBDesIkQZf0sqLF9CUTglnowtkr2yc2EKD1nweUyllSAQVvb8L19DDQaNpZJSG0grDYW3vAFaQxkgIzOAiYxH9xjkVbZNi1J95w9C8ZOnU0s09g8s5cFQ2weuCVLWbCkvASM7yPw5OSCoQoL8P2mergLVyx6VMbOXswnNADAKaoAUIw7ESqQh8/dvxmqU806APH005G+rcqpb2FDj4YaqFanXngp3jeDL5axgUjcCgCZxTLdGQwB7utulw/mp8EfOnVkkYyXnYMkod0RTZBx4ewrRIeK9MIomleYuwt0p4sVMxYJy4QGunorQHeg90H6lr+fePqJMv7ilzfI/d0OVKrpjSJIuS+KH5jv//T3gvQtGzblkr6pApjxy/GBEVC5AQ0A4MQNANAMADAA4JNd/xtuQOGMVDIpsbnhgaDI3EmLRU7kqrt/JjJ/iRWiWrbXIyLW6y+/Jxz3+ANgoNwMh4hAdrsDMqNJV2mSQqGDopLIloMqh1BiKDggnDEQTYms9e2bbxCZ8KvnTZNIjX6WUbjvnd1SCeSBm++QCeTY4wIQx8ydL/czOyFCt2zDeXS1gMEa9oAA42xfXVQCN9iUGTBC+QdgTHzr6ftkdHoARDbKziNmLJDRyiSXHrrPoqgIpaWxRFftVhgdu1mwo3osVAZ/G0R9B4t05lZC9K1gAZNeFp8MsaBIKVUNVda7m9+v34NQ2cnHohlm6GCyENx1TfUolBLuBhCowiomFgFV6cchlhKr2YHjyc7HflQdg/0IsCmoDRXhtCy6M2NMmtq7ZhGey9DpEJt3zr/wejzXjXVuWIP9aGliSTA2KS0bCQDOKULgUtF4qA4qdHrr0rdEpO+KWITBr735u7KA6+eNksogrDOi3fvcOono+dXN98jBum266KZOl1sV6mgknbHtKcviJ1OCaJFIWDa6sy8sKvAl1wLATj3jOEGk7n6/bERTDPv35xt/LBtriseFABxul+gkusm0mvdXjUA+M25AAwA0AwAMADAAQDUMqeKGSSWEaCgs/buTFqtYe0755tdlo3PcMA7lp0N0e/oPj4msuH3FcqHUgrIi2RCTycz83IMlklSBBDdH8TclolG5f3dPQKxFJ531OQGkW3/5ZRhldiGQ6OEXV4hVbvU/FgsFJzpqZb7uggy5X+nIETKxinEzhES62JDjwEbEaXTV4XwObIfRzku3V3YRjGAtzSDUcZ+7WsZwHxhJNdTwsvVUkskoQRY/DXTBDeZvRohpZxuMlBPnQmTOYFLRvq2Yh50ir5VA096IeVkcADCXG88zW2DUszJgKBVjiK6jkN8DMGTnQaTPyOL3aETsbqf7jypRMRkuxcCizUuh0uQW4PueYoTGpuXADehisUwTA5X62botzFZZjgy8v/3th2QsKgaQdLcA0PrpFi0fB6NiTiUYv3wykoRy2FKsfvsagfjGPXvlwAba0OXUnFclC5x5zkkikl951hyhk2o2dPnJ9/8kdLf4xbeF4bKz0sS6a7bZVGkuVZab9dMPFsARK24ymRD/Y1tDi/zgjZtzrNDThf9zqdBduw9f6xoAHb1x1+9kQaZ4TO5vczqk//gg0KzhfWnVPdgAxAAA3tcAAM0AAAMAPtn170wGUv4nBQAiikeDIQn8Mdlskr3x1YfvFevPhHy6hxgwcff375YFt+zdKZ0+vLk5SgSj/+pge+TwkZ6XTCRFBejq6BbrTsWksQJAv73vJ8JpZjLA9350r9xn+7L1MA7l5QpnRSMhkW1DwW4hFIvLggCiKqTJllYhPTVFN9qetZDYtq1EspE5CdHz2FMRKBRKgcHb2QxUhaQqwreng/DNLDttouieTIBg4izYEacoXcrAmVgE73fsgVHQRvegPRNGPVU4RGfasL8VKkz5OKgE5dVYz+q3wbhhGjfTLDBS2ZxsChqGSN7LpCtVsMRiAfD0UxWwUHWxMGDIZGZJMwJIgmXbI77DgVCFYOcX4hidOuh8+esI9EmY8Pfxs5GMM3I60r11hlI31mL9XbUoGBMPop+505Udx3xRP729A91Jxx0/VSZy+21fFV0kwX36xvW3yoPrN+0QBszJy34b6zCtJ30phlTFOVWLPLnPIJ2LCtnf2SX0VzRijHQSufGXN8oBFzPAbUs7AODeK78qVt1kNCrZZTaXUwKDBul825Ge91lIBjIAQDMAwACA/1IAUNcgEKiWYSogSPxY8WhUYiDjSU046PO3/1Qo8cqTyuVzi16FUeo3P7pHai+ZTHGJJHG5XGB8Xa/jfRmpoqmyyNkcRRRLJVNy//aWNpENZ544W4yPf3/oO3JgqsLiFy/9hYxtqzeImyWzIFdEP5NuFopPqVZc/t503DcKgkn4hMPyKivk/dIJotlotjQwWsMuBuy0wB3WUAOJrvkAi4my6JaiHlUE1JMPUTm3EqGiqmhmkopVzUo0thgxB6rACAbKNGzG/VtqNvA+YOyBVqgQmUUINDIzcCZGoIkn2FKsG0kzTi8INI2ieH8r6DARhuoQYwENtxehwx6OqlDKsGlwp7E7+MGip511TJJphwSdZNHNDzpasihnOeZdVo3ima4iuD/LRsNtGA1gvo1bRFLWOurq8W1zuixAN9kE0O2eTNFtdNXMNJUQ3ai3rVNUwYKZU0TnefKxH8j7qoLt+VffKVNavWSlGOPyiwpW4L46K7wcVD27Oaqy+Pk8MNGJgsGgAEEyaZFIrptuu0Fq1S04DQVmHl58QJD0me/dIgdmMWlyf4vNtpn7VsP7qgCgfu3fcBkAYAAA5mkAgFwGAHxK1yAAMHvloGgujJNMJIQSQwNBeZ1ZVimy3KXXXyZVGfetWiYb8uRfXvqD7GpxvjC62Wyu531UQETvkOdl8r+lOIeU+MX8Pb1ilCkdN0Yo6Mb7fioHsvxd2BKf+/UDQrn2ELpiOtJc4BhdJ8DowoGDBCCy7CCwCIcOit5y/2gkKOuJx7pknXnD5Nw1WzqMaiE/RPQEGS3FZJ42lirzswFJYgChrlGWBjPTKJjNkmSOPLjNyllcNMVy4B31WEc3m38qILE4YJuKstmnaiJaMgmtz3ydEOV9LcDVeBDbaWbxzgiTh7IY0puei/TVpu0IoIoREBwZwN2xn0NAzj625Ap3QEPrZkkulZ5sYykws5slz9iwo4Clt3QmE5mpsjg9UCGiPgQcdezHfC3WHBGJbXaXMKTV7t7Fc9rPc1JdTtnfPIUQ8kBQrJIRJzqwnPetayV769gTkDx09/W3yA9O4/adguCerMyNIAddFeZo/Bf0V4jzTsjC2pvb5blf/NKZ//P+OHzW8XKAj933V6lK29tQJ7qj0+2SDTOZzQpglIqrRP+g9m+4DAAwAEBGAwAMAPhUr0Nahik3SQ7OAQcRDatmiDaRnc/68iVShdMW80ns7R9//dAt7495dKeZTCbVDtnHDRkY8ry0Q5+jpbQKHoQwaCwWF8bVbVakKUfZIyqVFM6z220y6mZTM++jnqdCLymt6yL66yYTODKpVJuw3D+eiAoChPwdtOrBOGZ1g1GyS0ccNoZ7QUfxGIxCvp56Gf0NoLcWuhmzKsH4Ti80q9rVfz9scsoyZOaRpuWwnDiLUHqKoFoEO3F/M41xGRVgvL5WqCYxlgm3udnG+xi425p2g7H7OimZ0oga4QQKqLJYHJhfTx1UkSK66TxlCFRKz6rA51hG3JEJvulu3HvYGBughM0SX05PnlgNLWabIIDF5lCIV4NjTJJhUurclHahQtPZfjspqmYkEgUC6aYC0AV6wqWiMTHKWa0Wub9ZMaSu1fM+XaQ/1ZxT0Z9yQ4uqmEwm5XkddF9+5VtX//T9MWpNl9jkF//0+L0gn6joMjYHmuXqB3948ByNbu5P2gLswy4DAAwAkNEAAAMAPtXrEHegsnOBQVMpoZBBVUCsSbrFKpRTOmWaWGPifZ23vj/u37xNAiOcaW6dG+PjfYJH2pDB56nnHBFwBglEDjoRS3hwP/CM2WoZ4P1Bcbrewe+r56lGDCrAKYNbl8vXICDdhEgSLUV3EO1KqYQYhcL9HTL6+g8g75WhtGa60WIxPCbC8Zg5SFPOZCON+h0Igd38NtqWZzF918uQWzO8XloXS4X1UAQ3schmIqEggq3DyBcpRQImFg9lSTKLHfg94CMj0t1WUIHAHoeHyUAsdmpjKHcuS5dVjEUIcC8bnWxdgbRbuxUMbeWYiBPH2S493VsuuoXDmwdjr26u43nRbqs3YH+TCqjbuO+K8fs4qoAZ1agGWUypVB7pIhv0EHfzvHTQg1kYbhDg20gXH8aQH9gvtcN+8Fy8vzwvFBiQjR82cbwEHFkycn/y/ti4YZ1YnwdVuc04JzPztXVl7FMAE+bzPlX3n7oMADAAAH82AMAAgE/zOqRpqBLBFAM5uEHy90FRSeaQUt0mNfiNTBazLHhQ9FeMrsY4NyQ+5HnqOeyEoSmVgO5I9gNPHXw/xccpBlcMr0KLlYoxFADU9xXQ0PijExggag6ugqHQOjt76EXYcLO8HgSkivfHsL9DOHigr14I1de1X/YtGo/hbFzAmcJi4MvcuXD7nXTBl2SsrIaoH2VI7UP3oIjmhv1YxrBquM98rfUy1rO9uQo0WjgP6cSjRkAlqWMrtqWrkFa7/uXHsYwkVJX8UhjLstgEM8MFuh8/E+nOS19B+/bWZvJnEHxps1hlv9NzhgmhuzMqUEjDkyeMPchw9TiUBOunp9iHPdWKl5oCZjJ6SjG6Msapc1NJOkMBQIno6twUIKj3df7L7x/8wRnKkPL+P6E/NcrGDNI3xjirp7IHm8667IP0jde6ru6ngEXNX9H7J2oC+mGXAQAGAMhoAIABAP+W6xBVQDHQYe3EVaDLIVfy0Pd1XdXpPmjnSnJDUkOeYxryHNu/GNWlgEUxemTI32OHPu+Q5yggcA4Z0zkSePQsrOMgUNAtSmOi2SKj2WThawBELOIXd6a/u0lkcn8XSkp50qA7lA6vEsJSbroFp8G9V1QBlcBGETvdC+Pjjt1wny1fjFJorz2JJprf/ebXZJw6CUbGp/+BdtgjR9Ht1wY+W7kaRr2R48bLPiw8Yx5EZiYb3fGT2+Xv+3bsERXNk1OK+WaXiOhstXuQRpsAgyeS8U68jiuGVmMP6EIxdkqF3CpGVIwZGjIqxkzynBTdWYeM6txsQ/6urui/GBOHPkddhzxvKH2r16kh7+ND+kEWPIy+D3nOv0X0P/j8f+fNh2yMAQCHvDYAwAAA0MX/zwFg6KU26mgX9jE+bxryJ9OHjOpKDhlTh44fJnodcuBqHAowQ4HBc/ioK2OkAgplXBQA0U1mAQyTbpb3Uzpex6Ix4biejjbh/PzCTFEtSoeVyvuJOBxz1151tqhap54wSdarLGQBslHtJjB0Y0u7iJw799bK50tGIL33KxedLqPilkayWcwJQHzrH1uFce76ya+EwS12lzCmx5sufjw9lRD3WTKVkCemkgnF0GRgiPCDjM4ZpZQIP3QcyuhDGVKd0xHp4xB6GHpeR0sPh53/0Yri/246/7QuAwAMADAA4J/TgwEAxnX01xFET/XaPmRURqnD3aQae1zpB9938yZ0L2FMJpMCILFEUmT+7NxsCalO92ZIINLEEYhzuehLC4Rhw54sAZiGOnjN5hxTIoS8afVewYaf/+l5YciACaGs3790gQBRSR6bopaWCQO++tQ7Amj333mfiPJer0dqhjlcDgmdtVhMYtRLHXTP0ZiaUkZVFaJ7uJtL+8DoGhkyKoY4TBUzrk/nMgDgU74MADAA4LN0GQDwv3QdQWUYapxSqsNQoFB/dx36OpVKCWBEo1FhWLPZLP6+E89YcOH7Y393vwCDvTJPSlpNHFYgpdECAUjSF18gdVm0JW8jWefnN90lsb6pscPlvjd962qJEc4rRrnuR+74o4j2K55fJPPNzEqXz7tcLklj1U06RH9db+U8VaCOcmcp0VkxthLhh7p5/6lIb1yf7mUAwP/SZQCAAQD/iZcBAP8h1z9xl6rAksMDVqgyDAKBcGg4FBLR3+cLCGdfdNWlX5YvjRkuJaaOz3XJ3wuyoXHs8iM/+YFnloh7bsd9j4hKkT9nhjyvfFy1GBXjukWMfLtff1MCcxxmXdJjHW63jCZdV+nTDNz5wN7I8TDG1v6X3FvGdXSXAQD/IZcBAMb1f3EZAPAZvQYBQwGCAEAikQAA9PVLtdCJ06dKR43rvnGpGBFPnFAgKkSM7PjdPy8SI93L76CWmGXTOknLtrvShEGDwQBCb1OapNu6M72StGKx24XhB0V9VR5bRP1EPCpZQ5tXPawCdf4toavG9eleBgB8Ri8DAIzr07gMAPiMX4NAgEIXLEcdCUYk7dThcYox8IrrLpNeYWecMVPOOuyHEfCHv31CGHbbys1Sm8zu75f8XYvbpZpRqsYUbIrJ8tQfpEsrUV8CfKKRgLjxtq19PKoZ12fmMgDgM34ZAGBcn+QyAOAzfh0CAJK9E4vFJF/X3++X+tynXXSudNK46pqzxKjY2oj4nMeeXyxGuFXPvymMnZWRLu45k826mLfezFGVYVeBPSpEVxWplECe0ECPfH/nxmcM0f8zdBkA8Bm/DAAwrk9yGQDwGb8OKUfNhiUJCeDx+wLSWePUs06R/tR33fYlyQtesgfpvfc9hcYaO/6/9s4eN2EgiML4B0VCCYgmFqLhLJEocokcgDPkCrlDqtDSJW3q0IBoKC2BRBMpiowLdtkNfptRHFpXg97XjNzYlZ9md37e8xTlvP4w+6hiFMeS+v8zpmj9WWFJY4+pPxffO/z468WM5T1FUACUQwEgTaAAKKe2Dh3TP845rEEvixL7uLPBLXaIvb8+4SjwlocMfvLw+FLFztcnfuSr7nUQgCha/b5PjCnksm9/9mkZX2XKrxgKgHIoAKQJFADlnARAhoYw7uu9h725NXZUxYMxuBwc399BCDb5FnXA5XyBhp6bfg9lvSRNJOUX31RZh40zA1t3LxMKgHIoAKQJFADl1AwpRAiwMsy7YHxhrEX0R4fLQt/yGDZqt9NQ9kuCDXrNAENSfin3obGHqf5lQgFQDgWANOEHCHNPj4nmJVcAAAAASUVORK5CYIIoAAAAMAAAAGAAAAABACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZzwyF2tBOGKDXU+SZjoxS2c8Mg0AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZjsxMoplWMHQuZv6XzMrr2c8MkVnPDIUXjcuAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZzwyAWc8MgNnPDIJYTYsTa+Oet7fzrv5aj0q329EM8djOC9pWzUsG1YyKgNnPDIBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8MgFnPDICZzwyAQAAAAAAAAAAZzwyAmc8MgpoPDIZaD0zMmo+M05nOjBsdUw/usGpme/o28X/nn9s6N3KsPqffWrmZTgukGo+M05oPTMyaDwyGWc8MgpnPDICAAAAAAAAAABnPDIBZzwyAmc8MgEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8MgNnPDINaj8zGmc8MgxnPDICZzwyA2c8MhhmOzItZzwyH2c8MgtoPDIQaD0zMWg9M2JkOjGYVDErykosJehiSkP1pI+B/Z6Jev9sVkv/jn58/2xgWv9sXVL/alFH+UosJehUMSvKZDoxmGg9M2JoPTMxaDwyEGc8MgtnPDIfZjsyLWc8MhhnPDIDZzwyAmc8MgxqPzMaZzwyDWc8MgMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8Mg9jOC9DmnFcumU7MUJnPDIMZzwyDWU6MFaKY0yrZDguf2g9M09nPDJwXjgvwmE9MO9fPy7+Qysi/z4pIv9KMST/JhkU/yMSEP80Hhj/KhcT/zghG/8rGhf/Qisg/z4pIv9DKyL/Xz8u/mE9MO9eOC/CZzwycGg9M09kOC5/imNMq2U6MFZnPDINZzwyDGU7MUKacVy6YzgvQ2c8Mg8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8MiZiNi2h6s+j+3RIPLVnPDI9ZzwyLGI2LaDdzLf9bkIx4WI6MeNzTjv3ZUY2/0UzKv86Jx7/Pigh/0cvJv9LMyb/WT0t/0wxJP9XOy7/Ujss/043K/86KSP/QCwk/0cvJv8+KCH/Oice/0UzKv9lRjb/c04792I6MeNuQjHh3cy3/WI2LaBnPDIsZzwyPXRIPLXqz6P7YjYtoWc8MiYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZzwyAWc8MjVsQTG+6dO0/559cPFjNyy6ZDgvj3FIO9Li18r3lXNV639gSP5hSz7/STMp/1pAMv9mRzX/Vjkt/0w4Mv9RPDX/WUE5/1s/Lv9mRjH/VTgp/1s/Kf9WPjD/WEI5/0w4Mv9WOS3/ZkY1/1pAMv9JMyn/YUs+/39gSP6Vc1Xr4tfK93FIO9JkOC+PYzcsup59cPHp07T/bEExvmc8MjVnPDIBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZzwyAWc8Mjd5Tz3A59W4/sq0qfLKsI/4fVE+56SEfPOSb1r+g2JQ/4ZoUv9fRDT/V0Ez/3hZRf9eQC//bEcq/1QvFP9VMBL/bEUd/21HIf9kQh//YUAf/2I/Hv9bOhj/VTAS/1QvFP9sRyr/XkAv/3hZRf9XQTP/X0Q0/4ZoUv+DYlD/km9a/qSEfPN9UT7nyrCP+Mq0qfLn1bj+eU89wGc8MjdnPDIBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZzwyAWc8MjVjNizIpqKz/9HGuv/P1dL/sayh/4VhTf9dOyv/PCYh/3RQPv9uUUD/hlw9/2I8GP96Sxn/hlUj/41cKv+RYTD/iVwv/4tfMf+TZzf/kGU3/4pfMv9cPBn/cEkh/4NWJ/+GVSP/eksZ/2I8GP+GXD3/blFA/3RQPv88JiH/XTsr/4VhTf+xrKH/z9XS/9HGuv+morP/YzYsyGc8MjVnPDIBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZzwyC2c8MlhnOi/biYuJ/4WGlv+Hfm//jGdP/3NUQv+eclf/jWVP/2pLQP9xRiT/oH9Z/4paJv+RXSb/i1ol/5pmL/+hbDT/pG85/6RvN/+gbTb/jF4t/1g3Ef9UNBD/UTIQ/1A3HP9gQSH/j1wm/4JSHf+DXDH/bkcp/2pLQP+NZU//nnJX/3NUQv+MZ0//h35v/4WGlv+Ji4n/Zzov22c8MlhnPDILAAAAAAAAAAAAAAAAAAAAAAAAAABnPDICZzwyK2k+NKB2TEHXmq2i/2dQSP+UdV7/mHBT/2FJOv+CYk3/jGpV/4BaNv/FqIr/zbKU/7qVbv+fbTn/mWUv/5tmMP+bZzL/m2cx/5lmMf97Tx7/dkwc/2lCF/9mQRf/ZUIc/2JGKP9kSSv/j2Ex/5JkMv+SZTb/kmg6/4BaNv+MalX/gmJN/2FJOv+YcFP/lHVe/2dQSP+araL/dkxB12k+NKBnPDIrZzwyAgAAAAAAAAAAAAAAAAAAAABnPDIFZzwyRWtCN8JnOC7maoOD/4lkR/98Xkr/p3lg/49mUP+IZE3/h14v/5tsN/+9mG//v5x4/45uU/+Od2T/X0Ms/2JGLv9hRC3/YUUr/2lJLf9fPBr/ZDwP/2JBH/9ZQC7/UT4t/0w+MP8pKCr/f3Jl/4huVv+NaUL/oXRE/5ZoNv+AWSv/iGRN/49mUP+neWD/fF5K/4lkR/9qg4P/Zzgu5mtCN8JnPDJFZzwyBQAAAAAAAAAAAAAAAAAAAABnPDIEZzwyOmtBNqdnOjHnb2hZ/596Yf+fd1n/f2VU/4NkVP9oRir/qHpH/7SKW/+6kmf/sodc/2lvaP8zicX/KlOe/yJOnv8kUqH/JVCe/zVvsf9iYlf/ckUT/1tYRv8zicX/KlOe/yJOnv8kUqH/JVCe/zVvsP93g4H/e08g/3JNJf9ePRj/Vzsk/4NkVP9/ZVT/n3dZ/596Yf9vaFn/Zzox52tBNqdnPDI6ZzwyBAAAAAAAAAAAAAAAAAAAAABnPDIBZzwyHGg9M3lnPTHhjWtU/2tLPf+8nIP/xrSm/3pmWf9mUD7/yqiC/7OFVf+qeUX/vJZx/5tzUf84qLb/KKDP/1WCsf8uaKb/N4K2/yCOz/9cQin/gVEd/1cxFf8ruc3/KKDP/1WCsf8uaKb/N4K2/yGO0P9gQS//eFAj/2hBF/9fPBT/WT8n/3tmWf/GtKb/vJyD/2tLPf+Na1T/Zz0x4Wg9M3lnPDIcZzwyAQAAAAAAAAAAAAAAAAAAAAAAAAAAZzwyFWc7MYJxUEXygl9R/3VXSv+tmY//X0Y5/1w6Ff+LakT/sIFQ/8emg/+/mG//0raa/5dqQv9Lpqj/Jcvg/0Gw0/8edsz/IaHV/xmS0v9cQib/j1wj/1I4H/8Lyt7/T8PZ/zaq2P9Al8n/JKHU/xeU0/9bQC7/m2s2/5BjNP91TiX/YEMk/1U2E/9fRjn/rZmP/3VXSv+CX1H/cVBF8mc7MYJnPDIVAAAAAAAAAAAAAAAAAAAAAAAAAABnPDIBZzwyMWg/Nbt2YFz8lIB9/4ZsZf+Db2j/X0Mn/2lNLP+jgFn/sYlc/7+cdf/LrYz/28av/5t2Uv9EvM3/KNXh/0aezf8YXsH/S7/Y/xeS2v9JSkT/fU0V/0xXRP8d1OT/RbvY/xyL0P9YvdP/TMHX/xaS2v9HSkn/kWEr/5VjLv9/VCT/cUkd/1Y6Gv9eRCn/g29o/4ZsZf+UgH3/dmBc/Gg/NbtnPDIxZzwyAQAAAAAAAAAAAAAAAAAAAABnPDIIZzsxY3JUSuhTRU3/WVFU/6SUj/9sWUr/Z0ss/4NdNP+VbkH/3Mav/8Ked//HqYb/28q2/3tmR/9k1uf/JdXf/zN/yP8Ybsf/UMva/xiJ1f83VXP/cD8M/y13bv8W1+P/O7HX/xyP0f8619v/Tszb/xeQ1f84VXj/ilsq/51qNP+KXCj/e1Ag/2lKJv9nTS7/bFlK/6SUj/9ZUVT/U0VN/3JUSuhnOzFjZzwyCAAAAAAAAAAAAAAAAAAAAABnPDIZZzkum3VwcftrbYH/ZWd0/3BdUf+GbVP/rpN2/6F0Qv/Gp4T/49PB/8evlP/VvqT/vaKF/0dgVf9a3vD/Pc/f/yGAzf8fccb/Qdfb/yGDz/8lZaD/XCMD/xmdpf8Ryt//IqnX/yWl1f8t1tn/Qtja/yCC0P8iZaH/gU8h/5lpN/+ccUT/m2oz/5hnMf+SZzf/hWxR/29bUP9hY2//YWJx/3hwb/tlOS+bZzwyGQAAAAAAAAAAAAAAAGc8MgFnPDIva0Q6yV5haP5EPEP/XVdk/2dNOP+ok3z/qotq/7WSa//QtJX/zKuI/8GhfP/Bo4H/kWpB/2ipqv9Q4Oz/Mb/Y/x6Fz/8bi9D/Edne/y2Pz/83hc7/WTEX/x3H0/8Yv9r/JKXX/xK02P8J1t7/Ftrd/ymM0P83gcX/f1Ae/5NkMP+RYjH/n2w4/5doNf+ifVX/fVUq/14+G/9TUl3/RTxF/3Fkav1mQzrRZzwyO2c8MgMAAAAAAAAAAGc8MgVnPDJLakxG6HB4hP9bXmn/YVRV/1M3H//Brpr/z7uk/7qce/+shVv/zLOV/7qTZv+wh1v/fFU0/y63xP9G2uj/LrfZ/xyT1P8ZjdL/E9jg/zCh0P8zhNj/S0ZH/1LZ3/8lrdf/Mp/S/xHK3v8C0d3/Os7b/zCX0/88iMf/f08e/3VNG/+KXCf/lmUv/5lpOP+RZDT/g1Mg/3BIHP9vamv/bm59/3t0ff9qUkvmZzwyXGc8MggAAAAAAAAAAGc8MgtoOzBsYU5Q7Wduf/9ndIn/W0xB/107Gf+hdUb/tpNs/8aoh//Gonz/vphu/5l8XP+8po3/a1pE/ynO3/8g1uT/I6bW/xuU1/8meJz/AdPi/xWtzv8rdtP/NW6B/yPc5f8imtD/H5HL/xeoqv8I0t//OMbY/0+l0f9Qq9r/ZEQh/188D/9dOQ//nms0/6iDW/+ieEn/kGIv/3ZKG/9VRTr/TU5a/1NVXv9pVlPvZzsxgGc8Mg8AAAAAAAAAAGc8MhBoOS2EYFpk9FJZaf9TWmn/XkYy/29KI/+Raj//rYNW/76deP/MrIr/s41j/21VOv94YEP/X2ta/23l8v8j3OX/HJLQ/xuO2v88SGH/CcPS/wi+1v8sYMP/IpfO/wjX4P8zlcz/LYyw/yeBd/8I1+T/JNDc/3Gw1P9GsuX/VEgx/5JhKf9cOQ7/mWw6/7SUcv+YcEj/oXlN/3VKHP9SOCP/aml0/19XYP9waGXyaDkvm2c8MhcAAAAAAAAAAGc8MhZoOCyRUlFf/05Vav9PTF3/YD4j/4pgMv+XbkP/qH5Q/7eMXf/Vup3/pIZn/4dxWP93Wjr/VIqA/zHX6v8Gyt3/G5bV/xid3/9COjr/Gpec/wPW4f8wZb7/HZnT/w3Q2/8tktT/NG6E/zdhVP8g19//d9zk/3eqyP92vOj/QVNQ/49iL/+GWSL/nWov/5lnMf+qiGP/kmg5/3tRIv9QMRT/goaQ/4SOov97goT6ZjYqp2c8Mh4AAAAAAAAAAGc8MhlpOSyZUU9i/0pGWP9LR1T/akEW/4heMf+hdkj/sYZW/7eMXP+mg17/bVM0/5R2Vf+DWzn/Kq23/wLS5P8Mvdv/GpfX/xia1/9aPiX/OWlj/wHU6f8scLr/HJLS/xO30P8ulNz/Vl5V/1FZQv8h2eP/Qtjh/xKUzf9Xp9f/aJCh/5VqPf+ndUD/kWQz/5tpMf+YZzD/kWY3/3hRJ/9MLAv/XFVc/0E/Rf9hYmP/ZTUqrGc8MiIAAAAAAAAAAGg9MxlpOSyaWllo/0lDUP9XTV3/bkQX/5hqOf+qfU3/r4ZY/4tqR/+tiGP/upBi/7SLX/+EVzH/BMra/wHU5P8SrNL/GJ7Z/x6Mv/94UCf/XVY9/wLb5/8fjbz/IorR/x2Svf8ei9v/aUkl/2dRM/8C0d7/AtLg/xWg0P87kcn/S46w/7eYef+6lW7/pnQ//55sN/+WaTf/nXhS/3ZRKv9OKwn/bWp6/3SAlv93d3z/ZTUprWc8MiEAAAAAAAAAAGg9MxZoOCyTWltm/2Bmev9uZm7/cEYZ/5BlNf+lekv/tIpb/7yTaP+6kmf/v5lz/66IYP9nVzz/AN/w/wHU5P8akcr/GJ7c/y9yk/+QZTj/gFYy/wrJ0v8Qt8v/K3zF/ytvsf8nc7L/hV00/35WNP8MxM7/B9Hg/w+11P8ZldX/L4m6/4VeNv+idUX/qHtM/51rNf+ZaTj/il0u/4tpRv+TfWf/Y2ls/1BRVf9ub3H6ZjYrqGc8Mh4AAAAAAAAAAGg9MxFnOC2FZmls/UxPVv9hWFn/bUYg/5JmN/+bckb/sIdX/7iQZP+4kGT/u5Nn/6J7VP9DeW7/Adfq/wPX4v8fe8T/GZLc/0VgZv+Xbj//l2tE/yOcnv8D2eH/JnGt/zRauv88ZH3/mXNN/4pdNP8XqrT/C87g/xnI2/8jhsz/HJjV/2lOLf+abj//onNA/6J4T/+TZTX/hVsw/3lOIv9mSSr/VFpp/05TYf9aVVXsaTkvn2c8MhgAAAAAAAAAAGg9MwtoOzFvYltd8FVhcv9saG3/ck4r/5JmN/+pfU7/s4tf/7SMYP+kf1b/gWM//5ZrQ/8lnpz/AdTl/wfE1f8ib8T/GYvb/1lUQ/+lflT/pYFd/0Nyaf8A3u7/KG+m/zRRwf9aW1r/p4Rh/551VP8skZX/B8zi/x3O2v8shMT/GZvf/19bRv+Uaz//mGk3/6SAXf+ohWD/h1wx/3ZPJv9ROyb/TVhp/1tgbv9lWFPqaDowhWc8MhAAAAAAAAAAAGg9MwZoPDJRYE1M7EJJW/9LSlP/fGJI/5JlNP+nfE3/tYxi/7iRaP9tUTH/gmNC/4ReOv8Qwcj/ANrm/w+hwP8ib8r/HI3Q/3NUMf+4mHf/up2A/2tlUP8B2u3/JXao/zZEvv90XEL/p4ho/5JsRv87eHP/A83p/wXT4/8qcbP/IY/e/0ZgX/+FXDH/lWs9/4hjP/+8qZf/polt/3NNIf9NQj3/RFJg/0xQUv9iS0XoaDwyYmg+NAkAAAAAAAAAAGg9MwJoPTMyZUE5y0FMYP9KSFn/ZlNQ/4JXKv+ieUv/f186/4lpRf98Xjr/hGZC/2xZPP8C0Oj/AN3p/xuIwP8ia8z/JXmx/4VgOf+4mHf/r41n/4puVv8OvM3/Hom9/z87ov98Xjn/k29G/5VzTf9PW0z/BM7u/wfJ5P8gc6f/JHfU/zdjfv97VS3/gVw2/3tYM/+HaEr/kHVa/2RDG/8zMDb/SlNo/1RUXP1kQzvTaD40QHBIPwQAAAAAAAAAAAAAAABoPTMbaTouoUFPX/tPXXj/XVdk/1w8IP9oSCb/jWtC/5NwR/+QbkT/lndX/01vYf8C1+7/A9Pn/yh4vv8nc9P/NHCP/5JuSP+xjGT/u5t8/5p4XP8lm6X/HYDB/0Y2c/+GZT3/m3hP/5l5Vv9fSC7/CMTr/wvA4v8chLP/KVXA/zFgmv9kQx7/bEwq/3tXMf9lRCL/VzkZ/1I5IP81PEb/NDY8/05IS/VnPTOwbEI4JXFJQAEAAAAAAAAAAAAAAABoPTMKaTwxbVtRUu07SVr/P0ZV/1lKRv9hPx7/mHJG/5h0SP+eeUv/jGZA/zGMk/8KxOj/CcHd/y1nt/8rdNT/SF1p/6CDZv+3mHj/t5l8/558XP9Fe3f/IHjR/1M4QP+TcUr/rY1s/5Z0Tf9zRCX/DrPg/xKy3/8ToMb/KjCd/y1JqP9XOxf/YUUm/3lWL/9cPBr/VDUQ/0k6Mv87PU7/RUhM/1BCP+ZoPDGBaT81DwAAAAAAAAAAAAAAAAAAAABoPTMBaDwyNmlCOMNIYHT9VXOK/1Zeav9OMhf/mnNE/6iBU/+sjGf/iWJD/xemxP8Mweb/EKvM/zFexP8pddr/YldI/6ySdv++po3/uZ6C/6qNb/9vaFD/H3HG/3BQNP+WcUb/y7eh/6KCXf99VC//HJC3/xWr3v8UsN3/Ki2O/ydMvf9NPCz/cFEw/3JPKf9jQBj/RyoV/zMrMf8xLjf/PTs/+mRBOMtoPDJEZzwyAwAAAAAAAAAAAAAAAAAAAAAAAAAAaD0zE2g7MH5aWlzyP1Fc/0NQYP9WUUv/fFkr/7SVc/+ymoL/b2JO/wu94v8Lvub/HIrC/ytvz/8pedX/eV9E/7mkjv/CrJX/y7ah/7WdhP+XeVv/N3if/49qQv+jf1f/wKaL/6+RcP+KaUf/KnSO/xem3/8VreX/IjqO/yJVxf80SnT/ZEQh/29MJv9XMw7/Sjgs/yosN/8xMjn/S0A88Gk9MpJoPTMbAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaD0zA2g8Mj1nPzXLRVdo/VVrff9ggZD/bFEs/66MXf+pk37/Q256/xaV3P9Hqdj/nMjW/z9suP8ha9H/gmlR/8Gxn//n4Nj/1ce5/8Wxnv+9pY//iId6/7KVdv+wkG3/uJt8/76kif+WeFf/OV5p/xKd3v9Gqdr/obfN/0hcs/8ZT8H/UDwn/187F/87IhL/Miw3/yMdKP8uKjD9YTwx1mg9Mk1nPDIGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8MhtoOzChW1JS+Ft3hv9ET1z/QkxW/3VHF/+GgGr/GZ7Y/zfQ5f9D4O3/Sd3t/33h4/9KlMj/joV8/8vAtf/Sxbn/z8Cy/9TFuP/CqY//wamQ/8GpkP+5nYD/ybOe/8Cmiv+niWz/NnGO/0fM6v865O//Nt7w/3Hp8v9qt97/Omik/0IiDv8yKzT/Ly86/yslKv9LPjb8azwys2c8MiUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8MhNnOS6NYmFi+01scv9Sa3r/Sm+G/0tOTv93Zjv/h497/3eAdv9yfXP/cn90/3GAdf+KnJH/wLqy/9nTzf/d1M3/2tLJ/9/TyP/c0MT/1MS0/8y4o//Uxbj/xa6Y/8Kojv+wkHH/c3Zc/19lTP9SWEL/UlhD/1NZRP9JUDv/QUc5/0g5Ov8uKzT/Pj9I/zgyMf9aYWf/aTcqoWc8MhwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8MhNlNyuMkJqp/Fxka/9UZW7/R2mF/zRMYf9GSVL/ilsq/864m//Uzsr/1dDL/9bRzP/g3Nn/5uLf/+rm5P/m4d3/49zV/+DWzf/n3tj/39TK/9nLvf/ez8P/4dTI/9G9q/+9n4H/poFZ/554Uf+OaD7/imI6/3tOG/9RKwv/TkVG/z8/TP89OD3/RT48/0dITf9IaZH/azYooWc8MhwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8MhNmOC2Lbm5//HmEqP+Ljob/Y25v/12hsv9CeJj/TVhg/41iLv/Sr4L/7OPc/+7r6f/w7uz/7ern/+vn5f/q5eD/7efj/+rj3v/08e//4tjP/+/o5P/u5uD/5djN/8epj/+9mnr/uJJw/6yEWf+XbTX/dksE/0crEv86M0P/LSo2/09NUP9gVlb/e3Zw/2tzlP9lb5P/aDYnoGc8MhwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8Mg9lOCx0k4+Y+qvP2P+s2Nz/cHx3/359df9ien7/UqfI/1aKmv91WD7/rXxF/97Gpf/18ez/8u7r//Dt6v/y7er/8ezp/+ri2//z7un/7+fh/+PTxv/cyLb/38u7/9a8qf/MrJP/p3hI/4pkNf9cQxz/TE4+/05WX/9jVFn/cFRI/1lMTP57g3v/vOPn/7TU2v+GhqH+ZTUnh2c8MhcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8MglnOzE+bUQ6omxEPMtsRDvQZkA52mlDNu6jlYX8j62y/0t/j/9Idor/Zmpo/3xcOv+liFz/w62D/+DQtf/x6Nv/8OXb/+/k2//s39T/7d/T/+bSwf/bv6j/wph2/7KJaf+FVyz/akYZ/01ALv9AUFz/Z2Zv/1JDQf+QdGH/k3pp+2hCOexrRTvYakM6z2tEO8xrQzurZzswSGc8MgwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGc8MgFnPDINZzwyJGc8MjBnPDI0ZzwyPGc8MmFkOC6umnVf86CHdf+DoLH/ZpCv/1BleP9rg47/Z11U/2BMMf9+ZDn/mXtL/6yQYv+xkWb/qIJY/5pvRf9+USj/akIl/15ELv9iWFD/R0xe/2Zxgv9TVVv/eWZf/6uPfv+KbWD0ZTsxtGc8MmJnPDI5ZzwyM2c8MjFnPDImZzwyEGc8MgIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZzwyAWc8MgFnPDIBZzwyAmc8MgpnPDIrZTkvd3tSQ86YiYP4i4+W/3eFkf9ldoT/UVRi/1pkev9XYXL/WV9q/0hJUf9fXF//ZV1h/19TVf96c3f/eHh4/2x0e/+EgYz/QTtB/3Fpbf9zZGH/eV5W+GtEOtRlOjCCZzwyMWc8MgtnPDICZzwyAWc8MgFnPDIBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABnPDICZzwyFGc7MUFkNyyJdVFH1Il1b/iQiYn/i4uS/4yQmf9gXmH/goeU/2RncP9laW7/hYuc/0xITv9iZHD/d3Z+/3lxdP9yZWf/gHBs/35lXfdxTUPaZTkvkmc8MklnPDIYZzwyBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGg9MwRoPTIUZzwyO2U4LnJiNiuseFZN2YlwafGRgHv6hnVx/4qAf/+GfXn/iYGA/42Fgv+GeXf/inp2+XxiW/JqRjzcZzwxsmU5L3tnPDJBZzwyGGc8MgUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaD0zA2g9Mw9nPDIjZzsyQWU5LmJlOC6BZzsxm2k/NKppQDWyZj40smU7MatmOjCdZjkvhGY5L2ZnPDJFZzwyJmc8MhFnPDIEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaD0zA2g9MwhoPTMQaD0zF2g9Mx5nPDIhZzwyImc8Mh5nPDIYZzwyEWc8MglnPDIDZzwyAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA///4P///AAf///gP//8AB///wAP//wAH/8YAAGP/AAfwAAAAAA8AB/AAAAAADwAH8AAAAAAPAAfgAAAAAAcAB+AAAAAABwAH4AAAAAAHAAfgAAAAAAcAB8AAAAAAAwAHwAAAAAADAAfAAAAAAAMAB8AAAAAAAwAH4AAAAAAHAAfAAAAAAAMAB8AAAAAAAwAHwAAAAAADAAeAAAAAAAEAB4AAAAAAAQAHgAAAAAABAAeAAAAAAAEAB4AAAAAAAQAHgAAAAAABAAeAAAAAAAEAB4AAAAAAAQAHgAAAAAABAAeAAAAAAAEAB4AAAAAAAQAHgAAAAAABAAfAAAAAAAEAB8AAAAAAAwAHwAAAAAADAAfgAAAAAAcAB+AAAAAABwAH8AAAAAAPAAfwAAAAAA8AB/AAAAAADwAH8AAAAAAPAAfwAAAAAA8AB/AAAAAADwAH8AAAAAAPAAf8AAAAAD8AB//gAAAH/wAH//gAAB//AAf//gAAf/8AB///wAH//wAHKAAAACAAAABAAAAAAQAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZTowMpZ0Y61lOTFOaD0zBQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaD0zAWg9MwVpPTNv2MKr92k8Lc9nPDFlWzUsDmg9MwEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABoPTMBZzwyAmg9MwFoPTMBaD0zCGg9MwVoPTMBaD0zDGg9MytqPjReXzcvkJNyZt7TxbL6qZWG9LCaifNnQDeiaj40XWg9MytoPTMMaD0zAWg9MwVoPTMIaD0zAWg9MwFnPDICaD0zAQAAAAAAAAAAAAAAAAAAAAAAAAAAaD0zAWY6MSl+VEVzZzwyEmc8Mhd1TDx6ZjowWGc8MkpjOzGoXzwv5zslIP5TOy//SDgw/zojG/9ELij/MR0X/0oyJ/87JSD+Xzwv52M7MahnPDJKZjowWHVMPHpnPDIXZzwyEn5URXNmOjEpaD0zAQAAAAAAAAAAAAAAAAAAAABoPTMGYzguic6uivZhNi1zZjsxVbigj+5ySjjicE489lk/Mf9BLST/Uzcr/z8rI/9TOzD/X0M1/1pBM/9CMSr/PCkj/1M3K/9BLST/WT8x/3BOPPZySjjiuKCP7mY7MVVhNi1zzq6K9mM4LoloPTMGAAAAAAAAAAAAAAAAAAAAAGg9MwhySDic7N3K/aKBbPB0Sj7erZKB+YpqVP9pTz//X0c4/2dINv9SNSL/YD4m/2hEJP9gPR3/Wzoc/108Hf9hPyf/UjUi/2dINv9fRzj/aU8//4pqVP+tkoH5dEo+3qKBbPDs3cr9ckg4nGg9MwgAAAAAAAAAAAAAAAAAAAAAaD0zCmU5L6afmqb/xMW9/5qFdP97VUD/WDov/3pXQ/95UCv/eEoZ/4VWJP+VZDD/kGIx/5VnNv+QYzT/Xz4a/2xGIP96TyH/eEoZ/3hQLP94VkL/WDov/3tVQP+ahXT/xMW9/5+apv9lOS+maD0zCgAAAAAAAAAAAAAAAGg9MwFnPDI5b0Q5z4yQiP98ZVf/gl9I/3tcSf+GY0z/l3NT/8Okgv+jcz//mmUu/55pMv+fajT/kF8r/3FIG/9iPhX/Xj4b/1tCKP+OXyz/lGc4/4BYMf+GY0z/e1xJ/4JfSP98ZVf/jJCI/29EOc9nPDI5aD0zAQAAAAAAAAAAaD0zA2k+M2BpPTLmcnNo/4pmTv+Zb1b/fFlE/5RoNf+3kGT/s5Ft/2psdv9LSVX/TEhT/05KUv9dTT7/aj8P/0tPWf9CSFf/LDhR/2Jmdf97bV7/l2s7/3xVKf96WEP/mW9W/4pmTv9yc2j/aT0y5mk+M2BoPTMDAAAAAAAAAABoPTMBaD0zNmc8MtF8XUr/rYpw/6+bjP9gRzX/u5Nn/7CCU/+vhl7/TZSb/zJ/t/81ZqX/M3m1/0phaP93SBT/OI2c/zJ/t/81ZqX/M3m1/1Jref9xSh3/YDwV/1Q8Kf+vm4z/rYpw/3xdSv9nPDLRaD0zNmg9MwEAAAAAAAAAAAAAAABnPDIxb0xC5H9gU/+olIv/WkEs/4NgOv+2jWD/v5lw/8yxlv9ejob/Kc7e/zB1x/8ko9b/Q15l/4FMF/8goq3/QrbW/z6g0P8lo9T/QV1r/5lpNP99Uyf/XT4c/15ELv+olIv/f2BT/29MQuRnPDIxAAAAAAAAAAAAAAAAaD0zBGY6MHxoVlf7c2Vl/3hkWv9sTSr/k29F/9C1l//FpYH/vZ+A/2Sytv86ydr/FmjF/z611/8xZI3/bTkM/xHM2f8zq9b/NrfV/z+32P8vZ5D/kGAt/49gK/9ySx//Y0co/3hkWv9zZWX/aFZX+2Y6MHxoPTMEAAAAAAAAAABoPTMUbUxDw2Ficf9nYWn/f2VK/6mIZP/Bnnf/1r6l/8qylf+de1v/TMva/zCz2P8efcv/LrzW/yJyuP9LPCb/DNDl/yCj1v8gzNr/MLzW/yByuf+LWin/mGs8/51qNP+Wajr/eFw//2FeZP9dW2P/bUxExGg9MxYAAAAAAAAAAGg8MjBoVFLqXF5o/1NAO/+pl4T/vqOG/7mZdP/KrIv/tI1h/3JpUP8+3e3/Ka3X/xuK0P8czdv/OIjV/0d0cf8zwN3/K6XW/wPW3v8uxdr/PIfK/4JTIP+BViT/mWg0/5dsPv+AUiD/YlNJ/2lldf9vWVXraDwyPAAAAAAAAAAAaDsxVF1TWvNkb4L/XEUy/45mOv+6mXP/w6F7/6eGYf+agmb/VIN7/zTb6P8fmNP/Jnin/wLU4f8ndsj/K52z/yWu1f8ofZr/Btrm/0XA1/9YsNv/Zkch/2Q/Ev+jeEj/poBY/49iMf9eRS3/VFNe/2JVVfVoOzFlAAAAAGg9MwFoOi5sUlRj/lJUZv9pRiX/jWY8/6yCVP/Nro3/n4Ji/3tgQv9Mnp3/JNPj/xuX1f80XXr/D7W+/yKGyP8Vstn/Ip/S/z9ZYf8Wy9P/aM3d/1uq2v9bUjz/glci/5pqM/+je1D/jmM0/1o4GP98gIz/en6F+2c5Ln5oPTMCaD0zAmk6LnZQT2D/TERS/3RLHf+dckT/rIJU/5x5VP+Nbkv/kWlE/xa9yv8Jw93/GJzc/0tbWf8si4v/HJbI/xSw2f8piM7/Yk44/yG1uP8fzN3/RZTM/3aLjf+meEf/mWk1/5lnMf+PZjv/VTQS/2JgbP9dXWP/Zjcthmg9MwNoPTMBaDoucVlaa/9kX2v/ek8h/6R3R/+zi2D/vZVp/7uTaf+BZEP/ANjq/xCs1P8Wnd//clw+/1V3Yv8NvtT/I4nD/ypquf+EWzP/KJyY/wbU4f8bjc//VYGU/6eAVv+mdkL/mGo5/4pgNP+DZ0r/XmFq/21wc/1mOC2DaD0zAwAAAABnOi9gXF5i+19aXf97Uin/nHJF/7GIWv+6kWX/rYhd/1h5Zv8B2ef/GJTK/xyLzP+NYDP/g2NC/wLa5/8sZaf/PWGV/5x3Uf8+iIH/EtHh/yeazf8ug6j/kGM0/59wP/+heVD/glgu/2lJJ/9XYHP/XVlc8Wg6MHRoPTMBAAAAAGg8MkBZVVzyUFJe/3hWNP+ofEv/to5j/4xsSf+HZ0T/NJOL/wDd6P8gbbr/LXWf/6WAWv+nhGX/ErfC/y5dq/9YXXT/poVj/1V1Z/8Dzeb/HZTE/yCKxv+BWC3/kmY4/6qQdv+Pa0b/WEIt/0dSXP9ZSUbxaD0yTgAAAAAAAAAAaD0zH1lEQ9VITmT/aVFF/4xlOv+IZ0H/gmI+/4llQf8XrLj/B8ne/yZox/9DbID/rYtm/7CQcP80lJj/JmnE/2pUQ/+XdEz/Z19H/wbI6f8Xkb7/InjX/2hLKf99WjT/fFs5/3dZOP9ANzH/S1Be/15EP9lqQDYoAAAAAAAAAABoPTMJZjwynUNWaf9QUFr/Wjgb/5ZxRv+adkr/g18//wfI5/8To8j/LHfV/1tkY/+yknH/spNz/1p9cv8oXbL/hGU7/6aEYP94UC//Dbbh/xOlzP8rQrT/TUE5/2lLKf9oRiL/UjUU/zw7R/8+QEX9ZD82qG1DOg4AAAAAAAAAAGg9MwFoPDFMVlZd8U1ldv9SRDn/mXNF/66Pa/9icWX/C8Lq/x6JxP8qctb/fGpV/76ljP+5noH/h3Ra/zlkj/+UcUf/vKKF/5BuTP8dkb3/Fa/f/yg6nf88RWf/b08t/2ZCG/9FMSb/Ly01/0s/Pu9oPDJcaD0zAQAAAAAAAAAAAAAAAGg9MxFmQzqzQlJj/lx0gP+CYTT/sZqC/zl/lf8orN3/ZJ7K/yVuzf+RemH/1sm7/9HAsP+3nof/g4J1/6yMaf+8oIT/m31c/yp6mP8qpdz/aYC6/yJPs/9aPiH/Ti8T/y4mLP8uLTX+YT0zwGg9MxgAAAAAAAAAAAAAAAAAAAAAaD0zAWg7MXZbX2D7TGBt/0hLUP9/cUv/MKHA/0G9w/9OvsX/WaK1/6ihmP/TyL7/08a6/9C+q//GsJn/v6aN/8iynP+sjGz/P4qc/zq9xf8/vcX/W62+/z9WZv82Ky//MzI8/0Y8N/5pOzGHaD0zBAAAAAAAAAAAAAAAAAAAAAAAAAAAZjkuaXeAjf1RZm//QWB4/1FPUP+mfFL/xbOp/8a3r//Qw7z/4dzY/+bh3f/f18//4tnQ/9nKvf/d0MT/18a3/8CjiP+gdE3/ilwz/4JULP9fMQv/TD0+/zczOv9AOjj/SmB6/2k4K3toPTMCAAAAAAAAAAAAAAAAAAAAAAAAAABnOi9lcXSL/Zeprf9qe3j/TH2V/1ZrcP+pfk//6NjH//Hv7f/w7er/6+bj/+vl4P/z7+z/593W/+zi2v/axrb/xKSI/7KJYP+TbDr/Wz0M/0E5RP81LDH/ZV5c/5Odof9ud5f/ZzgreGg9MwIAAAAAAAAAAAAAAAAAAAAAAAAAAGY7MTqGbmjHgXZy32pVTumNg3b8cqu7/010hP94Ykf/t516/9fHrf/v59v/8Off/+3h1//r3dH/3cSv/8ejhv+rhGT/c1Ak/0dGP/9kaG7/cVpQ/4VpXfpyXFPog3hz331nZ81nOi9EaD0zAQAAAAAAAAAAAAAAAAAAAAAAAAAAaD0zB2g9MxtoPTMjaD0zL2Y6MHiNZlLjlJmb/mB5j/9rh5b/XVhU/2lbSP+IdFb/mH5e/49uT/+FYkT/bFVD/2VcV/9NUmH/X2Bm/4FqYP6GZVjnZjsyfmg9My1oPTMjaD0zHGg9MwgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaD0zBmc7MjRsRTubhG1o6oJ9gf57fYf/aW12/212g/9WW2X/bnKA/1paZf9wb3T/gnl+/3FiYP54XVXsbEM6omc8MjtoPTMIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGg9MwtnPDIzZDgue3VRSLqAZF3efGRe8n9tZ/eAbmr3e2Vg8npeWN9tSD69ZjsxgWc8MjloPTMMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABoPTMDaD0zD2c8MiJnPDIzZzsxPmc7MT9oPDI0aDwyI2g9MxBoPTMEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD//D////AP/+AAAAfAAAADwAAAA8AAAAPAAAADgAAAAYAAAAGAAAABwAAAA4AAAAGAAAABgAAAAYAAAAEAAAAAAAAAAAAAAACAAAAAgAAAAYAAAAGAAAABgAAAAcAAAAPAAAAD4AAAA+AAAAPgAAAD4AAAB/4AAH//gAH//+AH/ygAAAAQAAAAIAAAAAEAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABoPTMBj2tckWc7MGJdNi0EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGY7MgtxRzoibUI2Jmc8MipkPDFyVjUtu3pkWfVzX1T5VjUsv2Q8MXJnPDIqbUI2JnFHOiJmOzILAAAAAAAAAABqPzNNr5B71ZBuYMZ1VEL1WD8x/1E1Jf9fQCn/VTom/1E1Jv9YPzH/dVRC9ZBuYMavkHvVaj8zTQAAAAAAAAAAaT0zbpuVkf+FZVH/fFpE/5VsQf+VYi3/lWUx/3BKH/9oRSH/hFgq/3ZTPP+FZVH/m5WR/2k9M24AAAAAaD0zAWg9MpOJcFz/iWpX/66DVf+GhXf/QF6B/0pca/9ZWUb/NVmB/1lugP95USX/hmdU/4lwXP9oPTKTaD0zAWg9MwFpRj+jhW9n/3dXNf/CoHr/k6SU/yqd0f81hqj/SH1q/zqu1P81h6r/jV8t/2RFJP+Fb2f/aUY/o2g9MwFoPDIRZVhb63lnXP+4mHX/x6qJ/2ajnf8lmtP/KaHQ/zSQlv8butn/Lp/N/4pbKv+Zajj/b1hD/2lZXOtoPDIVaDswMFlbafx4VjP/vpp0/5d6W/8+tLn/JYGy/xahzP8ip83/IZ+t/1i62v9qTCT/ondJ/3VRKv9ranH7ZzowOmg6LzpWU2L/jGEy/66HXP+Xc0//DMHZ/zt8lf8qlaL/I4vJ/0x+b/8hsNb/hoFv/5xsOP98WDP/Y2Nr/mY5LkRoOzEoWVhe+45mO/+rhVv/cH9l/w6u1f9feH7/T56U/zxgl/91fmf/FrPW/1hydP+feE//dVMy/1VVXPhoPDExaD0zClNJUdxoTz3/j2xE/0qOiP8bk9D/f3tv/3yNe/9PYH3/h2pJ/w+t1f9AUXv/clEu/1FAMf9TRUbfa0E4DQAAAABiRUCAT1xk/55/Wf80l7D/NILM/6iUf/+ynIT/f3lt/6mLbP8hmMT/PFSc/19AH/80LC//Xj02iQAAAAAAAAAAZzowOFxpcv1WW1n/d6Og/4+2uf/RycP/2c3B/8+8qv/DqpL/aYZ4/198bv8+PEP/QUJJ/2k6L0IAAAAAAAAAAGc7MCiEgITpa3R0+W+CgP/Csp3/6ODV/+/n4f/n2Mz/xKSK/4BjP/9cTkP/ZFRP+IB8hetnOi4wAAAAAAAAAABoPTMCaD0zD2c8Mit9YFesdHuD+WpnZv95cWf/d2de/3BmY/9mXF/6dlRJsGc8Mi1oPTMQaD0zAgAAAAAAAAAAAAAAAAAAAAAAAAAAaD0zA2Y6MCxzTkVyc1NLlnNTTJdvSkF0ZzwyL2g9MwMAAAAAAAAAAAAAAAAAAAAA/D+sQYABrEGAAaxBgAGsQQAArEEAAKxBAACsQQAArEEAAKxBAACsQQAArEGAAaxBgAGsQYABrEGAAaxB8A+sQQ=='
            [System.IO.File]::WriteAllBytes($IcoPath, [System.Convert]::FromBase64String($IcoB64))
            Write-Diag "Icon written: $IcoPath"

    Write-Step "Compiling DML Launcher (system tray app)..."

    $CscPath = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $CscPath)) {
        Write-Warn "csc.exe not found at $CscPath -- skipping launcher (DML environment still fully works)."
    } else {
            $LauncherCs  = "$LauncherDir\DML-Launcher.cs"
            $LauncherExe = "$LauncherDir\DML-Launcher.exe"

            [System.IO.File]::WriteAllText($LauncherCs, @'
// DML-Launcher.cs -- Dad's MMO Lab system tray launcher
// Compiled at install time: csc.exe /target:winexe /r:System.Windows.Forms.dll /r:System.Drawing.dll

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

class DmlLauncherEntry
{
    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new TrayApp());
    }
}

class TrayApp : ApplicationContext
{
    const string DISTRO = "dml-arch";

    // Prevents Windows from sleeping while a server is running.
    // ES_CONTINUOUS makes the state persist until explicitly released.
    // ES_SYSTEM_REQUIRED blocks sleep without requiring the display to stay on.
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint esFlags);
    const uint ES_CONTINUOUS      = 0x80000000;
    const uint ES_SYSTEM_REQUIRED = 0x00000001;

    // --- WSL keepalive (lazy) -----------------------------------------------
    // WSL2 tears down the distro after the last Windows-side wsl.exe session
    // exits -- measured at ~13s on Windows 11 (docs suggest up to a minute).
    // Processes INSIDE the distro (dockerd, game containers) do NOT hold it
    // open. While a server is RUNNING we keep one hidden
    // "wsl --exec sleep infinity" process alive so servers survive after
    // installer/terminal windows close.
    // Lazy on purpose: the tray must never boot the distro on its own --
    // at logon the user may not want yesterday's server eating RAM. All
    // polling is gated on "wsl --list --running", which never boots WSL.
    // The keepalive lives in a Job Object with KILL_ON_JOB_CLOSE so it can
    // never outlive the tray, even if the tray process is killed forcibly.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
    [DllImport("kernel32.dll")]
    static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpInfo, uint cbInfoLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    const int  JobObjectExtendedLimitInformation  = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long    PerProcessUserTimeLimit;
        public long    PerJobUserTimeLimit;
        public uint    LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint    ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint    PriorityClass;
        public uint    SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    NotifyIcon _tray;
    IntPtr     _job = IntPtr.Zero;
    Process    _keepalive;
    bool       _serversRunning;
    object     _kaLock = new object();  // keepalive touched from UI + poller threads
    int        _idleChecks;             // consecutive "distro up, no servers" polls
    bool       _dormant;                // stop touching the distro so it can idle out
    int        _dormantTicks;

    public TrayApp()
    {
        _tray = new NotifyIcon();
        string icoPath = System.IO.Path.Combine(
            System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location),
            "dml.ico");
        _tray.Icon = System.IO.File.Exists(icoPath) ? new Icon(icoPath) : SystemIcons.Application;
        _tray.Text    = "DML Launcher";
        _tray.Visible = true;

        var menu = new ContextMenuStrip();
        menu.Opening += OnMenuOpening;
        _tray.ContextMenuStrip = menu;

        // Watch for running servers and hold WSL open while any exist.
        // Replaces the old startup 'dml status' check, which booted the
        // distro at every logon.
        InitKeepalive();
    }

    void InitKeepalive()
    {
        _job = CreateJobObject(IntPtr.Zero, null);
        if (_job != IntPtr.Zero)
        {
            var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int    size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr mem  = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, mem, false);
                SetInformationJobObject(_job, JobObjectExtendedLimitInformation, mem, (uint)size);
            }
            finally { Marshal.FreeHGlobal(mem); }
        }

        // Poller: first tick 3s after launch (catch a server already running
        // when the tray starts), then every 10s -- must beat the ~13s
        // teardown fuse when a server was started outside the tray. The
        // inside-the-distro check ('dml status') only runs while the distro
        // is already up; each such check resets WSL's idle countdown, so
        // after ~3 zero-server checks we go dormant and stop touching the
        // distro, letting it idle out. Dormancy re-checks every ~5 min in
        // case a server was started from a terminal we don't know about;
        // it resets when the distro goes down.
        bool[] busy    = { false };
        int[]  pending = { -1 };
        var poll = new System.Windows.Forms.Timer { Interval = 3000 };
        poll.Tick += delegate {
            poll.Interval = 10000;
            if (pending[0] >= 0) { UpdateSleepLock(pending[0]); pending[0] = -1; }
            if (busy[0]) return;   // previous check still in flight
            busy[0] = true;
            System.Threading.ThreadPool.QueueUserWorkItem(_ => {
                try
                {
                    if (!IsDistroRunning())
                    {
                        _idleChecks = 0; _dormant = false; _dormantTicks = 0;
                        pending[0] = 0;
                    }
                    else if (_dormant)
                    {
                        if (++_dormantTicks >= 30) { _dormant = false; _dormantTicks = 0; }
                    }
                    else
                    {
                        int c = CountRunning(WslRun("dml status"));
                        if (c > 0) { _idleChecks = 0; EnsureKeepalive(); }
                        else if (++_idleChecks >= 3) { _dormant = true; _dormantTicks = 0; }
                        pending[0] = c;
                    }
                }
                catch { }
                busy[0] = false;
            });
        };
        poll.Start();
    }

    // True if dml-arch is currently booted. 'wsl --list' never boots a
    // distro, and (unlike commands run inside a distro) prints UTF-16.
    static bool IsDistroRunning()
    {
        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName               = "wsl.exe";
            psi.Arguments              = "--list --running --quiet";
            psi.UseShellExecute        = false;
            psi.RedirectStandardOutput = true;
            psi.CreateNoWindow         = true;
            psi.StandardOutputEncoding = Encoding.Unicode;
            using (var p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(10000);
                foreach (var line in output.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
                    if (line.Trim().Equals(DISTRO, StringComparison.OrdinalIgnoreCase))
                        return true;
            }
        }
        catch { }
        return false;
    }

    void EnsureKeepalive()
    {
        lock (_kaLock)
        {
            bool dead = true;
            try { dead = (_keepalive == null || _keepalive.HasExited); } catch { }
            if (!dead) return;
            try
            {
                if (_keepalive != null) _keepalive.Dispose();
                var psi = new ProcessStartInfo();
                psi.FileName        = "wsl.exe";
                psi.Arguments       = "-d " + DISTRO + " --exec /usr/bin/sleep infinity";
                psi.UseShellExecute = false;
                psi.CreateNoWindow  = true;
                _keepalive = Process.Start(psi);
                if (_job != IntPtr.Zero && _keepalive != null)
                    AssignProcessToJobObject(_job, _keepalive.Handle);
            }
            catch { _keepalive = null; }  // next poll retries
        }
    }

    void StopKeepalive()
    {
        lock (_kaLock)
        {
            try { if (_keepalive != null && !_keepalive.HasExited) _keepalive.Kill(); } catch { }
            try { if (_keepalive != null) { _keepalive.Dispose(); _keepalive = null; } } catch { }
        }
    }

    // Blocks or releases Windows sleep, and holds or releases the WSL
    // keepalive, based on how many servers are running.
    void UpdateSleepLock(int runningCount)
    {
        _serversRunning = runningCount > 0;
        if (runningCount > 0)
        {
            EnsureKeepalive();
            SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
            _tray.Text = "DML Launcher — Server Active (sleep blocked)";
        }
        else
        {
            StopKeepalive();
            SetThreadExecutionState(ES_CONTINUOUS);  // release
            _tray.Text = "DML Launcher";
        }
    }

    static int CountRunning(string statusOut)
    {
        int count = 0;
        foreach (var line in statusOut.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            int colon = line.Trim().IndexOf(':');
            if (colon > 0 && line.Trim().Substring(colon + 1).Trim()
                    .Equals("running", StringComparison.OrdinalIgnoreCase))
                count++;
        }
        return count;
    }

    void OnMenuOpening(object sender, System.ComponentModel.CancelEventArgs e)
    {
        var menu = (ContextMenuStrip)sender;
        menu.Items.Clear();

        var header = new ToolStripMenuItem("DML Launcher");
        header.Enabled = false;
        header.Font = new Font(SystemFonts.MenuFont, FontStyle.Bold);
        menu.Items.Add(header);
        menu.Items.Add(new ToolStripSeparator());

        // Placeholder shown immediately — menu pops up with no delay
        var placeholder = new ToolStripMenuItem("Checking servers...");
        placeholder.Enabled = false;
        placeholder.Tag = "placeholder";
        menu.Items.Add(placeholder);

        menu.Items.Add(new ToolStripSeparator());
        AddStaticItems(menu);

        // Shared slot for background result
        string[] result = new string[1];

        // Timer fires on the UI thread — no Invoke/handle needed
        var timer = new System.Windows.Forms.Timer();
        timer.Interval = 150;
        timer.Tick += delegate
        {
            if (result[0] == null) return;   // not ready yet
            timer.Stop();
            timer.Dispose();
            if (menu.IsDisposed) return;

            int idx = -1;
            for (int i = 0; i < menu.Items.Count; i++)
                if ("placeholder".Equals(menu.Items[i].Tag as string)) { idx = i; break; }
            if (idx < 0) return;

            menu.Items.RemoveAt(idx);
            var items = BuildTitleItems(result[0]);
            for (int i = items.Count - 1; i >= 0; i--)
                menu.Items.Insert(idx, items[i]);
        };

        // Clean up timer if the menu closes before the result arrives
        menu.Closed += delegate { timer.Stop(); timer.Dispose(); };

        timer.Start();

        // Background thread does the WSL call
        System.Threading.ThreadPool.QueueUserWorkItem(delegate
        {
            try   { result[0] = WslRun("dml status"); }
            catch { result[0] = ""; }
        });
    }

    System.Collections.Generic.List<ToolStripItem> BuildTitleItems(string statusOut)
    {
        var items     = new System.Collections.Generic.List<ToolStripItem>();
        var statusMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        int runningCount = 0;

        foreach (var line in statusOut.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string trimmed = line.Trim();
            int colon = trimmed.IndexOf(':');
            if (colon > 0)
                statusMap[trimmed.Substring(0, colon)] = trimmed.Substring(colon + 1);
        }

        if (statusMap.Count == 0)
        {
            var empty = new ToolStripMenuItem("No titles installed");
            empty.Enabled = false;
            items.Add(empty);
            UpdateSleepLock(0);
            return items;
        }

        foreach (var kv in statusMap)
        {
            string title   = kv.Key;
            bool   running = string.Equals(kv.Value, "running", StringComparison.OrdinalIgnoreCase);
            if (running) runningCount++;

            var gameMenu  = new ToolStripMenuItem(title);
            var statusLbl = new ToolStripMenuItem(running ? "● Running" : "○ Stopped");
            statusLbl.Enabled = false;
            gameMenu.DropDownItems.Add(statusLbl);
            gameMenu.DropDownItems.Add(new ToolStripSeparator());

            var startItem = new ToolStripMenuItem("Start");
            var stopItem  = new ToolStripMenuItem("Stop");
            startItem.Enabled = !running;
            stopItem.Enabled  =  running;

            string captured = title;
            startItem.Click += delegate { RunAndReport("start", captured); };
            stopItem.Click  += delegate { RunAndReport("stop",  captured); };

            var attachItem = new ToolStripMenuItem("Attach to Console");
            attachItem.Enabled = running;
            attachItem.Click += delegate { AttachToConsole(captured); };

            // LAN play: realm settings live in the title's database, so the
            // server must be running before they can be read or changed.
            var lanMenu    = new ToolStripMenuItem("LAN Play");
            var lanEnable  = new ToolStripMenuItem("Enable LAN Play...");
            var lanDisable = new ToolStripMenuItem("Disable LAN Play");
            var lanStatus  = new ToolStripMenuItem("Status");
            lanEnable.Enabled  = running;
            lanDisable.Enabled = running;
            lanStatus.Enabled  = running;
            lanEnable.Click  += delegate { LanEnable(captured); };
            lanDisable.Click += delegate { LanRun("off", captured); };
            lanStatus.Click  += delegate { LanRun("status", captured); };
            lanMenu.DropDownItems.Add(lanEnable);
            lanMenu.DropDownItems.Add(lanDisable);
            lanMenu.DropDownItems.Add(lanStatus);

            gameMenu.DropDownItems.Add(startItem);
            gameMenu.DropDownItems.Add(stopItem);
            gameMenu.DropDownItems.Add(new ToolStripSeparator());
            gameMenu.DropDownItems.Add(attachItem);
            gameMenu.DropDownItems.Add(lanMenu);
            items.Add(gameMenu);
        }

        UpdateSleepLock(runningCount);
        return items;
    }

    void AddStaticItems(ContextMenuStrip menu)
    {
        var installItem = new ToolStripMenuItem("Install New Title...");
        installItem.Click += delegate { ShowInstallDialog(); };
        menu.Items.Add(installItem);

        var shellItem = new ToolStripMenuItem("Open DML Shell");
        shellItem.Click += delegate { OpenTerminal("-d " + DISTRO); };
        menu.Items.Add(shellItem);

        var doctorItem = new ToolStripMenuItem("Run dml doctor");
        doctorItem.Click += delegate
        {
            string result = WslRun("dml doctor");
            MessageBoxIcon icon = result.Contains("[WARN]") ? MessageBoxIcon.Warning : MessageBoxIcon.Information;
            MessageBox.Show(result, "DML Doctor", MessageBoxButtons.OK, icon);
        };
        menu.Items.Add(doctorItem);

        menu.Items.Add(new ToolStripSeparator());

        var exitItem = new ToolStripMenuItem("Exit");
        exitItem.Click += delegate {
            if (_serversRunning)
            {
                var choice = MessageBox.Show(
                    "A game server is still running.\n\n" +
                    "Closing DML Launcher releases the WSL keepalive -- running " +
                    "servers will shut down within seconds of exiting.\n\n" +
                    "Exit anyway?",
                    "DML Launcher", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (choice != DialogResult.Yes) return;
            }
            StopKeepalive();
            SetThreadExecutionState(ES_CONTINUOUS);  // always release before exit
            _tray.Visible = false;
            _tray.Dispose();
            Application.Exit();
        };
        menu.Items.Add(exitItem);
    }

    void RunAndReport(string cmd, string title)
    {
        // Arm the keepalive BEFORE starting: the ~13s teardown fuse is
        // shorter than "user reads the result MessageBox", so waiting for
        // the post-start status refresh loses the race. If the start fails,
        // the refresh below sees zero running servers and releases it.
        if (cmd == "start") EnsureKeepalive();
        string result  = WslRun("dml " + cmd + " " + title);

        // If LAN play is enabled for this title, re-point the realm at the
        // host's current LAN IP -- DHCP can hand out a new address between
        // sessions. 'dml lan refresh' is a no-op when LAN play is off, and
        // waits internally for the realm database to come up.
        if (cmd == "start")
        {
            string lanIp = GetLanIp();
            if (lanIp != null)
                System.Threading.ThreadPool.QueueUserWorkItem(_ => {
                    try { WslRun("dml lan " + title + " refresh " + lanIp); } catch { }
                });
        }

        string caption = (cmd == "start" ? "Start " : "Stop ") + title;
        MessageBoxIcon icon = (result.Contains("[error]") || result.ToLower().Contains("error"))
            ? MessageBoxIcon.Warning : MessageBoxIcon.Information;
        MessageBox.Show(result, caption, MessageBoxButtons.OK, icon);

        // Re-check server state after start/stop so the sleep lock updates
        // without requiring the user to reopen the menu.
        string[] r = { null };
        var pollTimer = new System.Windows.Forms.Timer { Interval = 150 };
        pollTimer.Tick += delegate {
            if (r[0] == null) return;
            pollTimer.Stop(); pollTimer.Dispose();
            UpdateSleepLock(CountRunning(r[0]));
        };
        pollTimer.Start();
        System.Threading.ThreadPool.QueueUserWorkItem(_ => {
            try { r[0] = WslRun("dml status"); } catch { r[0] = ""; }
        });
    }

    void AttachToConsole(string title)
    {
        string[] result = { null };

        var timer = new System.Windows.Forms.Timer { Interval = 150 };
        timer.Tick += delegate {
            if (result[0] == null) return;
            timer.Stop(); timer.Dispose();

            string container = result[0].Trim();
            if (string.IsNullOrEmpty(container)) {
                MessageBox.Show(
                    "No worldserver container found for '" + title + "'.\nIs the server running?",
                    "Attach to Console", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string wslArgs = "-d " + DISTRO + " -u dml -- bash -c \"printf '\\n"
                + "  === WoW Server Console ==================================\\n"
                + "  Title:   " + title + "\\n"
                + "  Exit:    Ctrl+P then Ctrl+Q  (detach safely)\\n"
                + "  WARNING: Ctrl+C will STOP the server!\\n"
                + "\\n' && docker attach " + container + "\"";
            OpenTerminal(wslArgs);
        };
        timer.Start();

        System.Threading.ThreadPool.QueueUserWorkItem(_ => {
            try {
                string raw = WslRun("docker ps --format {{.Names}}");
                string found = "";
                foreach (var line in raw.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)) {
                    if (line.Trim().IndexOf("worldserver", StringComparison.OrdinalIgnoreCase) >= 0) {
                        found = line.Trim();
                        break;
                    }
                }
                result[0] = found;
            } catch {
                result[0] = "";
            }
        });
    }

    // --- LAN play -----------------------------------------------------------
    // The realm's advertised address lives in the title's database; the
    // Windows plumbing (portproxy + firewall) is set up once by the
    // installer. These just drive 'dml lan' inside the distro.

    void LanEnable(string title)
    {
        string ip = GetLanIp();
        if (ip == null)
        {
            MessageBox.Show(
                "Could not detect this PC's LAN IP address.\n\n" +
                "Are you connected to your home network? If yes, run\n" +
                "'ipconfig' in a terminal, find your IPv4 address, and enable\n" +
                "LAN play from a DML shell instead:\n\n" +
                "    dml lan " + title + " on <your-ip>",
                "Enable LAN Play", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        // The installer pins the Windows port proxy to the LAN IP it saw at
        // install time (it must be specific -- see Install-DML.ps1 Step 12).
        // If DHCP has moved this PC since then, or the rules are missing,
        // say so HERE -- otherwise the realm advertises an address nothing
        // is listening on and LAN clients fail with no clue why.
        string plumbingNote = "";
        var proxyListeners = GetLanProxyListeners();
        if (proxyListeners.Count == 0)
            plumbingNote = "\n\nWARNING: Windows LAN forwarding rules were not found.\n" +
                           "Re-run Install-DML.ps1 once, or other PCs cannot reach the server.";
        else if (!proxyListeners.Contains(ip))
            plumbingNote = "\n\nWARNING: Windows is forwarding LAN traffic for " + string.Join(", ", proxyListeners.ToArray()) + ",\n" +
                           "but this PC's address is now " + ip + ".\n" +
                           "Re-run Install-DML.ps1 once to refresh the rules.";

        var choice = MessageBox.Show(
            "This lets other PCs on your home network play on '" + title + "'.\n\n" +
            "This PC's LAN address:  " + ip + "\n\n" +
            "On each other PC, open realmlist.wtf in the WoW client folder\n" +
            "and set:\n\n" +
            "    set realmlist " + ip + "\n\n" +
            "(This PC keeps working with 127.0.0.1 -- no change needed here.)" +
            plumbingNote + "\n\n" +
            "Enable LAN play now?",
            "Enable LAN Play -- " + title, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (choice != DialogResult.Yes) return;

        LanRun("on " + ip, title);
    }

    // Runs 'dml lan <title> <action>' off the UI thread and reports the
    // result. 'dml lan' may wait up to ~90s for the realm database right
    // after a start, so the AttachToConsole timer pattern is used rather
    // than RunAndReport's synchronous call.
    void LanRun(string action, string title)
    {
        string[] result = { null };

        var timer = new System.Windows.Forms.Timer { Interval = 150 };
        timer.Tick += delegate {
            if (result[0] == null) return;
            timer.Stop(); timer.Dispose();
            string text = result[0].Trim();
            if (text.Length == 0) text = "[error] No response from dml -- is the server running?";
            MessageBoxIcon icon = (text.Contains("ERROR") || text.Contains("[error]") || text.Contains("not supported"))
                ? MessageBoxIcon.Warning : MessageBoxIcon.Information;
            MessageBox.Show(text, "LAN Play -- " + title, MessageBoxButtons.OK, icon);
        };
        timer.Start();

        System.Threading.ThreadPool.QueueUserWorkItem(_ => {
            try   { result[0] = WslRun("dml lan " + title + " " + action); }
            catch { result[0] = "[error] Could not run dml lan."; }
        });
    }

    // Listen addresses of Windows portproxy rules that forward the WoW auth
    // port to 127.0.0.1 -- i.e., the addresses LAN clients can actually
    // reach. Reading rules needs no elevation (only changing them does).
    static System.Collections.Generic.List<string> GetLanProxyListeners()
    {
        var found = new System.Collections.Generic.List<string>();
        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName               = "netsh.exe";
            psi.Arguments              = "interface portproxy show v4tov4";
            psi.UseShellExecute        = false;
            psi.RedirectStandardOutput = true;
            psi.CreateNoWindow         = true;
            using (var p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(10000);
                foreach (var line in output.Split(new char[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    var tok = line.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                    // listenAddr listenPort connectAddr connectPort
                    if (tok.Length == 4 && tok[1] == "3724" && tok[2] == "127.0.0.1" && !found.Contains(tok[0]))
                        found.Add(tok[0]);
                }
            }
        }
        catch { }
        return found;
    }

    // Best-guess LAN IPv4: an up, non-loopback adapter that has an IPv4
    // default gateway (WSL/Hyper-V virtual switches never do). Prefers
    // private-range addresses so a VPN adapter's address doesn't win.
    static string GetLanIp()
    {
        string fallback = null;
        try
        {
            foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;

                var props = nic.GetIPProperties();
                bool hasV4Gateway = false;
                foreach (var gw in props.GatewayAddresses)
                    // Disconnected adapters can report a 0.0.0.0 "gateway" --
                    // that's not a route to the LAN, don't let it qualify.
                    if (gw.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
                        && gw.Address.ToString() != "0.0.0.0")
                        hasV4Gateway = true;
                if (!hasV4Gateway) continue;

                foreach (var ua in props.UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) continue;
                    string ip = ua.Address.ToString();
                    if (IsPrivateIp(ip)) return ip;
                    if (fallback == null) fallback = ip;
                }
            }
        }
        catch { }
        return fallback;
    }

    static bool IsPrivateIp(string ip)
    {
        if (ip.StartsWith("192.168.") || ip.StartsWith("10.")) return true;
        if (ip.StartsWith("172."))
        {
            var parts = ip.Split('.');
            int second;
            if (parts.Length == 4 && int.TryParse(parts[1], out second))
                return second >= 16 && second <= 31;
        }
        return false;
    }

    string WslRun(string wslCmd)
    {
        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName               = "wsl.exe";
            psi.Arguments              = "-d " + DISTRO + " -- " + wslCmd;
            psi.UseShellExecute        = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError  = true;
            psi.CreateNoWindow         = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            using (var p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(15000);
                return output.Trim();
            }
        }
        catch (Exception ex)
        {
            return "[error] Could not run WSL: " + ex.Message;
        }
    }

    void OpenTerminal(string wslArgs)
    {
        try
        {
            var psi = new ProcessStartInfo("wt.exe", "wsl " + wslArgs);
            psi.UseShellExecute = true;
            Process.Start(psi);
        }
        catch
        {
            try
            {
                var psi = new ProcessStartInfo("powershell.exe",
                    "-NoExit -Command \"wsl " + wslArgs + "\"");
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch { }
        }
    }

    void ShowInstallDialog()
    {
        using (var form = new Form())
        {
            form.Text            = "Install New DML Title";
            form.Size            = new Size(520, 210);
            form.StartPosition   = FormStartPosition.CenterScreen;
            form.FormBorderStyle = FormBorderStyle.FixedDialog;
            form.MaximizeBox     = false;
            form.MinimizeBox     = false;

            var lbl = new Label();
            lbl.Text   = "GitHub URL, local .sh installer, or folder:";
            lbl.Left   = 10; lbl.Top = 15; lbl.Width = 490; lbl.Height = 20;

            var box = new TextBox();
            box.Left = 10; box.Top = 42; box.Width = 380;

            var btnBrowse = new Button();
            btnBrowse.Text  = "Browse...";
            btnBrowse.Left  = 398; btnBrowse.Top = 40;
            btnBrowse.Width = 100;
            btnBrowse.Click += delegate {
                using (var ofd = new OpenFileDialog())
                {
                    ofd.Title       = "Select a DML installer script";
                    ofd.Filter      = "Shell scripts (*.sh)|*.sh|All files (*.*)|*.*";
                    ofd.FilterIndex = 1;
                    if (ofd.ShowDialog() == DialogResult.OK)
                        box.Text = ofd.FileName;
                }
            };

            var btnOk = new Button();
            btnOk.Text   = "Install"; btnOk.Left = 320; btnOk.Top = 100;
            btnOk.Width  = 85; btnOk.DialogResult = DialogResult.OK;

            var btnCancel = new Button();
            btnCancel.Text   = "Cancel"; btnCancel.Left = 415; btnCancel.Top = 100;
            btnCancel.Width  = 85; btnCancel.DialogResult = DialogResult.Cancel;

            form.Controls.Add(lbl);
            form.Controls.Add(box);
            form.Controls.Add(btnBrowse);
            form.Controls.Add(btnOk);
            form.Controls.Add(btnCancel);
            form.AcceptButton = btnOk;
            form.CancelButton = btnCancel;

            if (form.ShowDialog() == DialogResult.OK)
            {
                string input = box.Text.Trim();
                if (string.IsNullOrEmpty(input)) return;
                string wslPath = ToWslPath(input);
                // .sh file -> run directly with bash; directory or URL -> dml run
                string wslArgs = wslPath.EndsWith(".sh")
                    ? "-d " + DISTRO + " -- bash \"" + wslPath + "\""
                    : "-d " + DISTRO + " -- dml run \"" + wslPath + "\"";
                OpenTerminal(wslArgs);
            }
        }
    }

    static string ToWslPath(string input)
    {
        // Convert C:\path\to\folder -> /mnt/c/path/to/folder
        if (input.Length >= 3 && input[1] == ':' && (input[2] == '\\' || input[2] == '/'))
            return "/mnt/" + input.Substring(0, 1).ToLower() + "/" + input.Substring(3).Replace('\\', '/');
        return input;
    }
}

'@, [System.Text.Encoding]::UTF8)

            # A running tray holds a write lock on DML-Launcher.exe and csc
            # would fail with CS0016 -- stop it first, relaunch after compile.
            $trayWasRunning = $false
            $trayProc = Get-Process -Name 'DML-Launcher' -ErrorAction SilentlyContinue
            if ($trayProc) {
                $trayWasRunning = $true
                Write-Diag "Stopping running DML Launcher (PID $(@($trayProc)[0].Id)) to allow recompile..."
                $trayProc | Stop-Process -Force
                Start-Sleep -Milliseconds 500
            }

            Write-Diag "Compiling DML-Launcher.cs -> DML-Launcher.exe..."
            $IcoPath = Join-Path $LauncherDir "dml.ico"
            $iconFlag = if (Test-Path $IcoPath) { "/win32icon:`"$IcoPath`"" } else { "" }
            & $CscPath /target:winexe /optimize+ /nologo `
                /r:System.Windows.Forms.dll /r:System.Drawing.dll `
                $iconFlag /out:"$LauncherExe" "$LauncherCs"
            $cscExit = $LASTEXITCODE
            Write-Diag "csc.exe exit code: $cscExit"

            if ($cscExit -ne 0) {
                Write-Warn "Launcher compilation failed (exit $cscExit) -- DML environment still works without it."
                Write-Warn "Try running Windows Update to repair .NET Framework, then re-run this installer."
            } else {
                Write-Ok "DML-Launcher.exe compiled to $LauncherDir"

                try {
                    $wshShell = New-Object -ComObject WScript.Shell

                    $desktopLnk = $wshShell.CreateShortcut("$env:USERPROFILE\Desktop\DML Launcher.lnk")
                    $desktopLnk.TargetPath = $LauncherExe
                    $desktopLnk.Save()
                    Write-Ok "Desktop shortcut created"

                    $startupDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
                    $startupLnk = $wshShell.CreateShortcut("$startupDir\DML Launcher.lnk")
                    $startupLnk.TargetPath = $LauncherExe
                    $startupLnk.Save()
                    Write-Ok "Added DML Launcher to Windows startup"
                } catch {
                    Write-Warn "Shortcut creation failed: $($_.Exception.Message)"
                }

                if ($trayWasRunning) {
                    # Launch via explorer so the tray runs unelevated (this
                    # script is elevated; the startup shortcut is not).
                    Write-Diag "Relaunching DML Launcher..."
                    Start-Process -FilePath explorer.exe -ArgumentList "`"$LauncherExe`""
                    Write-Ok "DML Launcher restarted with the new build"
                }

        Mark-StepDone 'launcher-v2-icons'
        }
    }

    # -------------------------------------------------------------------------
    # Step 12: LAN play plumbing
    #
    # On Windows 11 22H2+ (build 22621+) with networkingMode=mirrored, WSL2
    # shares the host network stack — Docker ports are reachable on the
    # Windows LAN IP directly. No portproxy or IP Helper needed. A Hyper-V
    # firewall rule opens the WSL2 VM to inbound LAN traffic.
    #
    # On older Windows we fall back to the classic portproxy approach.
    # -------------------------------------------------------------------------
    Write-Step "Configuring LAN play plumbing..."

    $osBuild  = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    $wslCfgRaw = Get-Content "$env:USERPROFILE\.wslconfig" -Raw -ErrorAction SilentlyContinue
    $isMirror = ($osBuild -ge 22621) -and ($wslCfgRaw -match 'networkingMode\s*=\s*mirrored')
    $LanPorts = @(3724, 8085)
    $dmlProxyPorts = @('3306', '3724', '8085')

    # Always sweep legacy portproxy rules (clean up previous installs)
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $proxyRules = netsh interface portproxy show v4tov4
    $ErrorActionPreference = $prevEap
    foreach ($line in @($proxyRules)) {
        if ("$line" -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$') {
            $lAddr = $Matches[1]; $lPort = $Matches[2]; $cAddr = $Matches[3]; $cPort = $Matches[4]
            if ($cAddr -eq '127.0.0.1' -and $dmlProxyPorts -contains $cPort) {
                $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                netsh interface portproxy delete v4tov4 listenaddress=$lAddr listenport=$lPort 2>$null | Out-Null
                $ErrorActionPreference = $prevEap
                Write-Diag "Removed legacy portproxy rule: ${lAddr}:${lPort} -> 127.0.0.1:$cPort"
            }
        }
    }

    if ($isMirror) {
        Write-Diag "Windows 11 22H2+ mirror mode — using Hyper-V firewall (no portproxy needed)"

        foreach ($port in $LanPorts) {
            # Standard Windows Firewall rule
            $ruleName = "DML LAN Play (TCP $port)"
            try {
                if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
                        -Protocol TCP -LocalPort $port -Profile Domain,Private | Out-Null
                    Write-Ok "Firewall: allow inbound TCP $port"
                } else { Write-Diag "Firewall rule already present: $ruleName" }
            } catch { Write-Warn "Firewall rule TCP $port failed: $($_.Exception.Message)" }

            # Hyper-V firewall rule — needed for mirror mode inbound into WSL2 VM
            $hvRule = "DML LAN Play Hyper-V (TCP $port)"
            $wslVmId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
            try {
                if (-not (Get-NetFirewallHyperVRule -DisplayName $hvRule -ErrorAction SilentlyContinue)) {
                    New-NetFirewallHyperVRule -DisplayName $hvRule -Direction Inbound -Action Allow `
                        -Protocol TCP -LocalPorts $port -VMCreatorId $wslVmId | Out-Null
                    Write-Ok "Hyper-V firewall: allow inbound TCP $port for WSL2"
                } else { Write-Diag "Hyper-V firewall rule already present: $hvRule" }
            } catch { Write-Warn "Hyper-V firewall rule TCP $port failed: $($_.Exception.Message)" }
        }
        Write-Ok "LAN play ready (mirror mode) — other PCs connect to this PC's IP, no extra config needed"

    } else {
        Write-Diag "Classic portproxy mode (Windows pre-22H2 or mirror mode not active)"

        try {
            Set-Service -Name iphlpsvc -StartupType Automatic -ErrorAction Stop
            Start-Service -Name iphlpsvc -ErrorAction Stop
            Write-Diag "IP Helper service running"
        } catch { Write-Warn "Could not start IP Helper: $($_.Exception.Message)" }

        $lanIp = $null
        try {
            $nic = Get-NetIPConfiguration |
                Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } |
                Select-Object -First 1
            if ($nic) { $lanIp = ($nic.IPv4Address | Select-Object -First 1).IPAddress }
        } catch { }
        if (-not $lanIp) {
            Write-Warn "Could not detect LAN IP — connect to network and re-run installer for LAN play."
        }

        foreach ($port in $LanPorts) {
            $ruleName = "DML LAN Play (TCP $port)"
            try {
                if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
                        -Protocol TCP -LocalPort $port -Profile Domain,Private | Out-Null
                    Write-Ok "Firewall: allow inbound TCP $port"
                } else { Write-Diag "Firewall rule already present: $ruleName" }
            } catch { Write-Warn "Firewall rule TCP $port failed: $($_.Exception.Message)" }

            if ($lanIp) {
                $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                netsh interface portproxy add v4tov4 listenaddress=$lanIp listenport=$port connectaddress=127.0.0.1 connectport=$port | Out-Null
                $ok = ($LASTEXITCODE -eq 0)
                $ErrorActionPreference = $prevEap
                if ($ok) { Write-Ok "Port proxy: ${lanIp}:$port -> 127.0.0.1:$port" }
                else { Write-Warn "Port proxy for $port failed — see HOWTO LAN section." }
            }
        }
    }

    # -------------------------------------------------------------------------
    # Step 13: WSL resource management scripts
    # -------------------------------------------------------------------------
    Write-Step "Installing WSL resource management scripts..."

    $KeepalivePs1 = @'
# Holds dml-arch open while a game server is running (started by dml start).
$Distro = 'dml-arch'
while ($true) {
    try {
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList @('-d', $Distro, '-e', 'sleep', 'infinity') -WindowStyle Hidden -PassThru
        $p.WaitForExit()
    } catch {}
    Start-Sleep -Seconds 3
}
'@
    Set-Content -Path "$InstallRoot\WSL-Keepalive.ps1" -Value $KeepalivePs1 -Encoding UTF8

    $EnsureKeepalivePs1 = @'
$InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $InstallRoot 'WSL-Keepalive.ps1'
if (-not (Test-Path $script)) { exit 0 }
$running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$script*" }
if (-not $running) {
    Start-Process pwsh -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-File', $script -WindowStyle Hidden
}
Remove-Item (Join-Path $InstallRoot '.dml-servers-stopped') -Force -ErrorAction SilentlyContinue
'@
    Set-Content -Path "$InstallRoot\DML-Ensure-Keepalive.ps1" -Value $EnsureKeepalivePs1 -Encoding UTF8

    $ReleaseWslPs1 = @'
# Returns WSL RAM to Windows when all game servers are stopped.
# Spawned detached from Windows (or via async Start-Process from dml stop).
param([int]$DelaySeconds = 3)
$Distro = 'dml-arch'
$InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Start-Sleep -Seconds $DelaySeconds

# Kill Windows-side keepalive loops
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'WSL-Keepalive\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Stop Linux services that pin RAM (auto-start again on next dml start / WSL boot)
wsl.exe -d $Distro -u root -- systemctl stop dml-keepalive.service 2>$null | Out-Null
wsl.exe -d $Distro -u root -- systemctl stop docker 2>$null | Out-Null

Set-Content -Path "$InstallRoot\.dml-servers-stopped" -Value (Get-Date -Format o) -Encoding UTF8

wsl.exe --terminate $Distro 2>$null | Out-Null
Start-Sleep -Milliseconds 500

# --terminate stops the distro; --shutdown kills the WSL VM (VmmemWSL).
# Without --shutdown, Vmmem keeps ~1 GB even when all distros show Stopped.
wsl.exe --shutdown 2>$null | Out-Null

Write-Host "[dml] WSL released - memory returned to Windows" 
'@
    Set-Content -Path "$InstallRoot\DML-Release-WSL.ps1" -Value $ReleaseWslPs1 -Encoding UTF8

    # Remove legacy always-on keepalive (now started only by dml start)
    Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\DML-WSL-Keepalive.vbs" -Force -ErrorAction SilentlyContinue
    schtasks /Delete /TN 'DML-WSL-Keepalive' /F 2>$null | Out-Null

    Write-Ok "WSL scripts installed (keepalive on start, release RAM on stop)"

    # -------------------------------------------------------------------------
    # Done
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Your DML environment is ready!" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Installed inside WSL2 (dml-arch):" -ForegroundColor White
    Write-Host "    Arch Linux  +  systemd  +  Docker Engine  +  dml CLI v2.2.1" -ForegroundColor Green
    Write-Host "  Install location: $InstallRoot" -ForegroundColor DarkGray
    Write-Host ""
    if (Test-Path "$env:USERPROFILE\Desktop\DML Launcher.lnk") {
        Write-Host "  DML Launcher is on your Desktop and starts with Windows." -ForegroundColor White
        Write-Host "  Right-click the tray icon to start/stop titles and install new ones." -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  To run a DML title from the command line:" -ForegroundColor White
    Write-Host "    wsl -d dml-arch" -ForegroundColor Cyan
    Write-Host "    dml run https://github.com/DadsMmoLab/<title>" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Check the Dad's MMO Lab channel for which title to install" -ForegroundColor White
    Write-Host "  first -- some titles have prerequisites." -ForegroundColor White
    Write-Host ""
    Write-Host "  To check your environment at any time:" -ForegroundColor White
    Write-Host "    dml doctor" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Full install log: $LogFile" -ForegroundColor DarkGray
    Write-Host ""
    $null = Read-Host "  Press Enter to close"
}

# =============================================================================
# Entry
# =============================================================================
try {
    if ($ResumePhase2) {
        Invoke-Phase2 -AfterReboot
    } else {
        Invoke-Phase1
    }
} catch {
    if (-not $Script:FailReported) {
        Write-Host ""
        Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Installation stopped. Share this log if you need help:" -ForegroundColor Yellow
    Write-Host "  $LogFile" -ForegroundColor Yellow
    exit 1
}
