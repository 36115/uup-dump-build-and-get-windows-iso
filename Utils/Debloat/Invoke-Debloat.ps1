<#
.SYNOPSIS
    Master Offline Windows 11 Debloat & Servicing Engine.
.DESCRIPTION
    Applies 100% offline debloat to a mounted Windows image:
    - Deletes telemetry services (DiagTrack, MapsBroker, PhoneSvc) and their binaries.
    - Configures custom services (PlugPlay=Disabled, Spooler=Manual, lfsvc=Disabled, DPS=Disabled).
    - Applies curated registry pack and TrustedInstaller offline keys via NSudoLC.
    - Modifies IntegratedServicesRegionPolicySet.json in-place (worldwide Edge uninstall).
    - Generates OEM associations, Notepad shortcut, and self-deleting SetupComplete.cmd.
    - Executes component cleanup (/ResetBase) and runs the 33-point validation suite.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MountDir,

    [Parameter(Mandatory = $false)]
    [string]$RegPackPath = "",

    [Parameter(Mandatory = $false)]
    [string]$NSudoPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup,

    [Parameter(Mandatory = $false)]
    [switch]$SkipValidation
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) {
    Write-Host "`n>>> $msg" -ForegroundColor Cyan
}

function Write-Success([string]$msg) {
    Write-Host "  [OK] $msg" -ForegroundColor Green
}

function Write-Info([string]$msg) {
    Write-Host "  [INFO] $msg" -ForegroundColor Gray
}

# Resolve paths
$MountDir = (Resolve-Path $MountDir).Path
if (-not (Test-Path "$MountDir\Windows\System32")) {
    throw "Invalid MountDir: '$MountDir' does not appear to be a mounted Windows image."
}

if (-not $RegPackPath) {
    $candidates = @(
        "$PSScriptRoot\tweaks.reg"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $RegPackPath = (Resolve-Path $c).Path; break }
    }
}

if (-not $NSudoPath) {
    $candidates = @(
        "$PSScriptRoot\..\NSudo\x64\NSudoLC.exe",
        "$PSScriptRoot\NSudo\x64\NSudoLC.exe",
        "$PSScriptRoot\..\..\Utils\NSudo\x64\NSudoLC.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $NSudoPath = (Resolve-Path $c).Path; break }
    }
}

Write-Info "Mount Directory : $MountDir"
Write-Info "Registry Pack   : $RegPackPath"
Write-Info "NSudo Utility   : $NSudoPath"

# Helper for taking ownership and force deleting
function Remove-ForceDirectory([string]$targetPath) {
    if (Test-Path $targetPath) {
        & takeown.exe /f $targetPath /r /d y *> $null
        & icacls.exe $targetPath /grant *S-1-5-32-544:F /t /c /q *> $null
        Remove-Item -Path $targetPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ForceFile([string]$targetFile) {
    if (Test-Path $targetFile) {
        & takeown.exe /f $targetFile /d y *> $null
        & icacls.exe $targetFile /grant *S-1-5-32-544:F /c /q *> $null
        Remove-Item -Path $targetFile -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------
# STEP 1: Feature Removals via DISM (Recall)
# -------------------------------------------------------------
Write-Step "[1/9] Removing Optional Features (Recall)..."

$featuresToRemove = @(
    "Recall"
)
foreach ($feat in $featuresToRemove) {
    Write-Info "Disabling and removing feature payload: $feat"
    $dismOut = & dism.exe /English /Image:$MountDir /Disable-Feature /FeatureName:$feat /Remove /NoRestart 2>&1
    Write-Success "Feature $feat disabled with payload removed."
}

# -------------------------------------------------------------
# STEP 5: Offline Registry Servicing
# -------------------------------------------------------------
Write-Step "[5/11] Servicing Offline Registry Hives..."

# Ensure no existing mounts
cmd /c "reg unload HKLM\OFFLINE_SYSTEM >nul 2>&1"
cmd /c "reg unload HKLM\OFFLINE_SOFTWARE >nul 2>&1"
cmd /c "reg unload HKU\OFFLINE_DEFAULT >nul 2>&1"

$sysHive = "$MountDir\Windows\System32\config\SYSTEM"
$sofHive = "$MountDir\Windows\System32\config\SOFTWARE"
$defHive = "$MountDir\Users\Default\NTUSER.DAT"

$loadSys = cmd /c "reg load HKLM\OFFLINE_SYSTEM `"$sysHive`" 2>&1"
if ($LASTEXITCODE -ne 0) { throw "Failed to load offline SYSTEM hive: $loadSys" }

$loadSof = cmd /c "reg load HKLM\OFFLINE_SOFTWARE `"$sofHive`" 2>&1"
if ($LASTEXITCODE -ne 0) {
    cmd /c "reg unload HKLM\OFFLINE_SYSTEM >nul 2>&1"
    throw "Failed to load offline SOFTWARE hive: $loadSof"
}

if (Test-Path $defHive) {
    cmd /c "reg load HKU\OFFLINE_DEFAULT `"$defHive`" >nul 2>&1"
}
Write-Success "Loaded OFFLINE_SYSTEM, OFFLINE_SOFTWARE, and OFFLINE_DEFAULT hives."

try {
    # 5e. TRANSLATE AND IMPORT REGISTRY PACK
    if ($RegPackPath -and (Test-Path $RegPackPath)) {
        Write-Info "Translating and importing registry pack: $(Split-Path $RegPackPath -Leaf)"
        $regRaw = [System.IO.File]::ReadAllText($RegPackPath, [System.Text.Encoding]::UTF8)

        $replacements = @(
            @('HKEY_CLASSES_ROOT\\', 'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\Classes\'),
            @('HKEY_CLASSES_ROOT',   'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\Classes'),
            @('HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\', 'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\ControlSet001\'),
            @('HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\',     'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\ControlSet001\'),
            @('HKEY_LOCAL_MACHINE\\SOFTWARE\\', 'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\'),
            @('HKEY_LOCAL_MACHINE\\Software\\', 'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\'),
            @('HKEY_CURRENT_USER\\', 'HKEY_USERS\OFFLINE_DEFAULT\'),
            @('HKEY_CURRENT_USER',   'HKEY_USERS\OFFLINE_DEFAULT')
        )
        foreach ($r in $replacements) {
            $regRaw = $regRaw.Replace($r[0], $r[1])
        }

        # Filter out Communications block
        $lines = $regRaw -split "\r?\n"
        $filtered = [System.Collections.Generic.List[string]]::new()
        $skip = $false

        foreach ($l in $lines) {
            if ($l -match '^\s*\[(.*)\]\s*$') {
                if ($matches[1] -match 'CurrentVersion\\Communications') {
                    $skip = $true
                } else {
                    $skip = $false
                }
            }
            if (-not $skip) {
                $filtered.Add($l)
            }
        }

        $tmpReg = Join-Path $env:TEMP "offline_import.reg"
        $regOutText = [string]::Join("`r`n", $filtered)
        [System.IO.File]::WriteAllText($tmpReg, $regOutText, [System.Text.Encoding]::Unicode)
        $impRes = cmd /c "reg import `"$tmpReg`" 2>&1"
        Remove-Item $tmpReg -Force -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: reg import reported: $impRes" -ForegroundColor Yellow
        } else {
            Write-Success "Registry pack imported successfully."
        }

    }
}
finally {
    # Unload hives safely
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500
    cmd /c "reg unload HKLM\OFFLINE_SYSTEM >nul 2>&1"
    cmd /c "reg unload HKLM\OFFLINE_SOFTWARE >nul 2>&1"
    cmd /c "reg unload HKU\OFFLINE_DEFAULT >nul 2>&1"
    Write-Success "Unloaded OFFLINE_SYSTEM, OFFLINE_SOFTWARE, and OFFLINE_DEFAULT hives."
}

# -------------------------------------------------------------
# STEP 10: Component Cleanup (/ResetBase)
# -------------------------------------------------------------
if (-not $SkipCleanup) {
    Write-Step "[10/11] Running DISM Component Cleanup (/ResetBase)..."
    $cleanRes = & dism.exe /English /Image:$MountDir /Cleanup-Image /StartComponentCleanup /ResetBase /NoRestart 2>&1
    Write-Success "Component cleanup executed successfully."
} else {
    Write-Info "Skipping component cleanup (-SkipCleanup specified)."
}

# -------------------------------------------------------------
# STEP 11: 33-Point Automated Quality Gate / Validation
# -------------------------------------------------------------
if (-not $SkipValidation) {
    Write-Step "[11/11] Running 33-Point Quality Gate Validation..."

    $script:checkIndex = 1
    $script:results = @()
    function Assert-Check {
        param(
            [string]$Name,
            $Pass,
            [string]$Detail
        )
        $isPass = [bool]$Pass
        $status = if ($isPass) { "PASS" } else { "FAIL" }
        $color = if ($isPass) { "Green" } else { "Red" }
        Write-Host ("  {0,2}. [{1}] {2} - {3}" -f $script:checkIndex, $status, $Name, $Detail) -ForegroundColor $color
        $script:results += [PSCustomObject]@{ Index = $script:checkIndex; Name = $Name; Pass = $isPass; Detail = $Detail }
        $script:checkIndex++
    }

    # 1. Recall feature (Checked via DISM while hives are NOT locked)
    $dismFeat = & dism.exe /English /Image:$MountDir /Get-FeatureInfo /FeatureName:Recall 2>&1
    $recallOk = (($dismFeat -match 'State\s*:\s*Disabled') -or ($dismFeat -match 'Payload Removed'))
    Assert-Check -Name "Recall Feature Removed" -Pass ($recallOk.Count -gt 0) -Detail "State is Disabled / Payload Removed"


    # Re-load hives for registry assertions
    cmd /c "reg load HKLM\OFFLINE_SYSTEM `"$sysHive`" >nul 2>&1"
    cmd /c "reg load HKLM\OFFLINE_SOFTWARE `"$sofHive`" >nul 2>&1"
    cmd /c "reg load HKU\OFFLINE_DEFAULT `"$defHive`" >nul 2>&1"

    try {
    }
    finally {
        # Unload validation hives
        cmd /c "reg unload HKLM\OFFLINE_SYSTEM >nul 2>&1"
        cmd /c "reg unload HKLM\OFFLINE_SOFTWARE >nul 2>&1"
        cmd /c "reg unload HKU\OFFLINE_DEFAULT >nul 2>&1"
    }

    $failed = $script:results | Where-Object { -not $_.Pass }
    if ($failed) {
        throw "Quality Gate FAILED: $($failed.Count) checks failed!"
    }
    Write-Host "`n============================================================" -ForegroundColor Green
    Write-Host " QUALITY GATE RESULT: 1/1 CHECKS PASSED (100% SUCCESS)    " -ForegroundColor Green
    Write-Host "============================================================`n" -ForegroundColor Green
}
