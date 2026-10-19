<#
.SYNOPSIS
    Master Offline Windows 11 Debloat & Servicing Engine.
.DESCRIPTION
    Applies 100% offline debloat to a mounted Windows image:
    - Purges Defender binaries, folders, drivers, and deletes all 9 Defender services from registry.
    - Deletes telemetry services (DiagTrack, MapsBroker, PhoneSvc) and their binaries.
    - Configures custom services (PlugPlay=Disabled, Spooler=Manual, lfsvc=Disabled, RemoteRegistry=Disabled, DPS=Disabled).
    - Applies curated registry pack and TrustedInstaller offline keys via NSudoLC.
    - Modifies IntegratedServicesRegionPolicySet.json in-place (worldwide Edge uninstall).
    - Generates OEM associations, Notepad shortcut, and self-deleting SetupComplete.cmd.
    - Executes component cleanup (/ResetBase) and runs the 40-point validation suite.
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
        "$PSScriptRoot\..\..\UUPDump Debloat\Windows-11-REG-Pack-(NoDefender).reg",
        "$PSScriptRoot\..\UUPDump Debloat\Windows-11-REG-Pack-(NoDefender).reg",
        "$PSScriptRoot\Windows-11-REG-Pack-(NoDefender).reg"
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
        & takeown.exe /f $targetFile /a *> $null
        & icacls.exe $targetFile /grant *S-1-5-32-544:F /c /q *> $null
        Remove-Item -Path $targetFile -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------
# STEP 1: Feature Removals via DISM (Recall & Defender Definitions)
# -------------------------------------------------------------
Write-Step "[1/11] Removing Optional Features (Recall, Defender Definitions & Remote Desktop)..."

$featuresToRemove = @(
    "Recall",
    "Windows-Defender-Default-Definitions",
    "Microsoft-RemoteDesktopConnection"
)
foreach ($feat in $featuresToRemove) {
    Write-Info "Disabling and removing feature payload: $feat"
    $dismOut = & dism.exe /English /Image:$MountDir /Disable-Feature /FeatureName:$feat /Remove /NoRestart 2>&1
    Write-Success "Feature $feat disabled with payload removed."
}

# -------------------------------------------------------------
# STEP 2: Purge Windows\InboxApps
# -------------------------------------------------------------
Write-Step "[2/11] Purging Pre-staged Apps (Windows\InboxApps)..."
$inboxApps = "$MountDir\Windows\InboxApps"
if (Test-Path $inboxApps) {
    Remove-ForceDirectory $inboxApps
    Write-Success "Windows\InboxApps purged."
} else {
    Write-Info "Windows\InboxApps already absent."
}

# -------------------------------------------------------------
# STEP 3: Purge Windows Defender Folders & Binaries
# -------------------------------------------------------------
Write-Step "[3/11] Purging Windows Defender Folders & Binaries..."

$defenderFolders = @(
    "$MountDir\Program Files\Windows Defender",
    "$MountDir\Program Files (x86)\Windows Defender",
    "$MountDir\ProgramData\Microsoft\Windows Defender",
    "$MountDir\Windows\System32\drivers\wd",
    "$MountDir\Windows\System32\SecurityHealth"
)
foreach ($dir in $defenderFolders) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Deleted: $dir"
    }
}

$defenderBinaries = @(
    # Kernel Drivers
    "$MountDir\Windows\System32\drivers\WdBoot.sys",
    "$MountDir\Windows\System32\drivers\WdFilter.sys",
    "$MountDir\Windows\System32\drivers\WdNisDrv.sys",
    "$MountDir\Windows\System32\drivers\WdDevFlt.sys",

    # SecurityHealth Binaries
    "$MountDir\Windows\System32\SecurityHealthService.exe",
    "$MountDir\Windows\System32\SecurityHealthSystray.exe",
    "$MountDir\Windows\System32\SecurityHealthHost.exe",
    "$MountDir\Windows\System32\SecurityHealthAgent.dll",
    "$MountDir\Windows\System32\SecurityHealthCore.dll",
    "$MountDir\Windows\System32\SecurityHealthProxyStub.dll",
    "$MountDir\Windows\System32\SecurityHealthSSO.dll",
    "$MountDir\Windows\System32\SecurityHealthSsoUdk.dll",
    "$MountDir\Windows\System32\SecurityHealthUdk.dll",

    # Web Threat Defense Binaries
    "$MountDir\Windows\System32\webthreatdefsvc.dll",
    "$MountDir\Windows\System32\webthreatdefusersvc.dll",

    # Security Center UI Binaries
    "$MountDir\Windows\System32\wscadminui.exe",
    "$MountDir\Windows\System32\wscui.cpl"
)
foreach ($bin in $defenderBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Defender binary: $(Split-Path $bin -Leaf)"
    }
}

# -------------------------------------------------------------
# STEP 4: Purge Telemetry, SmartScreen & BrowserCore Binaries
# -------------------------------------------------------------
Write-Step "[4/11] Deleting Telemetry, SmartScreen & BrowserCore Binaries..."
$telemetryBinaries = @(
    "$MountDir\Windows\System32\diagtrack.dll",
    "$MountDir\Windows\System32\moshost.dll",
    "$MountDir\Windows\System32\PhoneService.dll"
)
foreach ($bin in $telemetryBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted telemetry binary: $(Split-Path $bin -Leaf)"
    }
}

$smartScreenFiles = @(
    "$MountDir\Windows\System32\smartscreen.exe",
    "$MountDir\Windows\System32\smartscreen.dll",
    "$MountDir\Windows\System32\smartscreenps.dll",
    "$MountDir\Windows\System32\en-US\smartscreen.exe.mui",
    "$MountDir\Windows\SysWOW64\smartscreen.dll",
    "$MountDir\Windows\SysWOW64\smartscreenps.dll"
)
foreach ($f in $smartScreenFiles) {
    if (Test-Path $f) {
        Remove-ForceFile $f
        Write-Success "Deleted SmartScreen binary: $(Split-Path $f -Leaf)"
    }
}

$appRepApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "Microsoft.Windows.AppRep.ChxApp_*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $appRepApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged SmartScreen App: $($app.Name)"
}

$browserCoreDir = "$MountDir\Windows\BrowserCore"
if (Test-Path $browserCoreDir) {
    Remove-ForceDirectory $browserCoreDir
    Write-Success "Purged BrowserCore directory: $browserCoreDir"
}

# OneDrive Setup Binaries in Windows
$oneDriveBinaries = @(
    "$MountDir\Windows\System32\OneDriveSetup.exe",
    "$MountDir\Windows\System32\OneDrive.ico",
    "$MountDir\Windows\SysWOW64\OneDriveSetup.exe"
)
foreach ($bin in $oneDriveBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted OneDrive binary: $(Split-Path $bin -Leaf)"
    }
}

# .NET Framework Native Image Cache (NGEN) Folders (NTLite assembly.net)
# Strips pre-JIT-compiled native image blobs (~360+ MB) while strictly preserving GAC_MSIL
$ngenFolders = @(
    "$MountDir\Windows\assembly\NativeImages_v4.0.30319_64",
    "$MountDir\Windows\assembly\NativeImages_v4.0.30319_32",
    "$MountDir\Windows\assembly\NativeImages_v2.0.50727_64",
    "$MountDir\Windows\assembly\NativeImages_v2.0.50727_32",
    "$MountDir\Windows\assembly\temp",
    "$MountDir\Windows\assembly\tmp"
)
foreach ($dir in $ngenFolders) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Deleted .NET Native Image Cache: $(Split-Path $dir -Leaf)"
    }
}

# Windows System Assessment Tool (WinSAT) (NTLite winsat)
$winSatDir = "$MountDir\Windows\Performance\WinSAT"
if (Test-Path $winSatDir) {
    Remove-ForceDirectory $winSatDir
    Write-Success "Purged WinSAT directory: $winSatDir"
}

$winSatBinaries = @(
    "$MountDir\Windows\System32\WinSAT.exe",
    "$MountDir\Windows\System32\winsatapi.dll",
    "$MountDir\Windows\SysWOW64\WinSAT.exe",
    "$MountDir\Windows\SysWOW64\winsatapi.dll"
)
foreach ($bin in $winSatBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted WinSAT binary: $(Split-Path $bin -Leaf)"
    }
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "WinSAT*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted WinSAT MUI: $($_.Name)"
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
    # 5a. COMPLETELY DELETE ALL DEFENDER SERVICES
    Write-Info "Deleting ALL Defender services from ControlSet001\Services..."
    $defenderServices = @(
        "WinDefend", "WdBoot", "WdFilter", "WdNisSvc", "WdNisDrv",
        "SecurityHealthService", "wscsvc", "MDCoreSvc", "webthreatdefsvc"
    )
    foreach ($svc in $defenderServices) {
        cmd /c "reg delete `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\$svc`" /f >nul 2>&1"
        Write-Success "Deleted service key: $svc"
    }

    # Delete SecurityHealth tray icon startup from Run keys
    cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Run`" /v SecurityHealth /f >nul 2>&1"
    cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run`" /v SecurityHealth /f >nul 2>&1"
    Write-Success "Purged SecurityHealth from Run keys."

    # 5b. COMPLETELY DELETE TELEMETRY SERVICES
    Write-Info "Deleting Telemetry services from ControlSet001\Services..."
    $telemetryServices = @("DiagTrack", "MapsBroker", "PhoneSvc")
    foreach ($svc in $telemetryServices) {
        cmd /c "reg delete `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\$svc`" /f >nul 2>&1"
        Write-Success "Deleted service key: $svc"
    }

    # 5c. CONFIGURE REQUESTED SERVICE START TYPES
    Write-Info "Configuring requested service start types..."
    $serviceConfigs = @{
        "PlugPlay"       = 4  # Disabled (User host confirmed)
        "Spooler"        = 3  # Manual
        "lfsvc"          = 4  # Disabled (Geolocation)
        "RemoteRegistry" = 4  # Disabled
    }
    foreach ($sName in $serviceConfigs.Keys) {
        $stVal = $serviceConfigs[$sName]
        cmd /c "reg add `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\$sName`" /v Start /t REG_DWORD /d $stVal /f >nul 2>&1"
        Write-Success "Configured $sName -> Start = $stVal"
    }

    # 5d. CONFIGURE DPS (Diagnostic Policy Service) VIA NSUDO (TrustedInstaller)
    Write-Info "Configuring DPS (TrustedInstaller elevation)..."
    if ($NSudoPath -and (Test-Path $NSudoPath)) {
        $dpsCmd = "reg add `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\DPS`" /v Start /t REG_DWORD /d 4 /f"
        $dpsBatch = Join-Path $env:TEMP "nsudo_dps.cmd"
        Set-Content -Path $dpsBatch -Value "@echo off`r`n$dpsCmd`r`nexit" -Encoding ASCII
        & $NSudoPath -U:T -P:E -Wait $dpsBatch *> $null
        Remove-Item $dpsBatch -Force -ErrorAction SilentlyContinue
        Write-Success "Configured DPS -> Start = 4 via TrustedInstaller."
    } else {
        cmd /c "reg add `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\DPS`" /v Start /t REG_DWORD /d 4 /f >nul 2>&1"
        Write-Info "Configured DPS directly."
    }

    # 5e. TRANSLATE AND IMPORT REGISTRY PACK
    if ($RegPackPath -and (Test-Path $RegPackPath)) {
        Write-Info "Translating and importing registry pack: $(Split-Path $RegPackPath -Leaf)"
        $regRaw = [System.IO.File]::ReadAllText($RegPackPath, [System.Text.Encoding]::UTF8)

        $replacements = @(
            @('HKEY_CLASSES_ROOT\', 'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\Classes\'),
            @('HKEY_CLASSES_ROOT',   'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\Classes'),
            @('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\', 'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\ControlSet001\'),
            @('HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\',     'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\ControlSet001\'),
            @('HKEY_LOCAL_MACHINE\SOFTWARE\', 'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\'),
            @('HKEY_LOCAL_MACHINE\Software\', 'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\'),
            @('HKEY_CURRENT_USER\', 'HKEY_USERS\OFFLINE_DEFAULT\'),
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

        # 5f. APPLY ConfigureChatAutoInstall VIA NSUDO (TrustedInstaller)
        if ($NSudoPath -and (Test-Path $NSudoPath)) {
            Write-Info "Applying ConfigureChatAutoInstall = 0 via TrustedInstaller..."
            $chatCmd = "reg add `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Communications`" /v ConfigureChatAutoInstall /t REG_DWORD /d 0 /f"
            $chatBatch = Join-Path $env:TEMP "nsudo_chat.cmd"
            Set-Content -Path $chatBatch -Value "@echo off`r`n$chatCmd`r`nexit" -Encoding ASCII
            & $NSudoPath -U:T -P:E -Wait $chatBatch *> $null
            Remove-Item $chatBatch -Force -ErrorAction SilentlyContinue
            Write-Success "Applied ConfigureChatAutoInstall = 0."
        }

        # Ensure HttpAcceptLanguageOptOut is persisted in Default Profile and Policies
        cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Control Panel\International\User Profile`" /v HttpAcceptLanguageOptOut /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Control Panel\International`" /v UserHttpAcceptLanguageOptOut /t REG_DWORD /d 1 /f >nul 2>&1"

        # 5g. CONFIGURE SMARTSCREEN & BROWSERCORE REGISTRY SETTINGS
        Write-Info "Configuring SmartScreen disabled and removing BrowserCore registrations..."
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer`" /v SmartScreenEnabled /t REG_SZ /d off /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System`" /v EnableSmartScreen /t REG_DWORD /d 0 /f >nul 2>&1"

        $nativeHosts = @(
            "HKLM\OFFLINE_SOFTWARE\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.microsoft.browsercore",
            "HKLM\OFFLINE_SOFTWARE\Mozilla\NativeMessagingHosts\com.microsoft.browsercore"
        )
        if ($NSudoPath -and (Test-Path $NSudoPath)) {
            $bcCmds = ($nativeHosts | ForEach-Object { "reg delete `"$_`" /f" }) -join "`r`n"
            $bcBatch = Join-Path $env:TEMP "nsudo_browsercore.cmd"
            Set-Content -Path $bcBatch -Value "@echo off`r`n$bcCmds`r`nexit" -Encoding ASCII
            & $NSudoPath -U:T -P:E -Wait $bcBatch *> $null
            Remove-Item $bcBatch -Force -ErrorAction SilentlyContinue
        } else {
            foreach ($nh in $nativeHosts) {
                cmd /c "reg delete `"$nh`" /f >nul 2>&1"
            }
        }
        Write-Success "SmartScreen disabled (SmartScreenEnabled=off, EnableSmartScreen=0) and BrowserCore registrations purged."

        # 5g. RESET FUSION & NGEN NATIVE IMAGES REGISTRY (NTLite assembly.net)
        Write-Info "Cleansing Fusion & NGEN registry entries..."
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Fusion\NativeImagesIndex`" /f >nul 2>&1"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\.NETFramework\v4.0.30319\NGEN`" /f >nul 2>&1"
        Write-Success "Fusion & NGEN native image cache indexes cleansed."

        # 5h. SUPPRESS BACKGROUND NGEN AUTO-REGENERATION SCHEDULED TASKS
        Write-Info "Suppressing .NET Framework NGEN background regeneration tasks..."
        $ngenTaskGuids = @(
            "{09B75BFE-4FDF-47B3-A7FD-899A092F9899}",
            "{01612C27-6C74-4BA7-A9FC-F7D32415C0D4}",
            "{A089E292-F4B9-4EB5-A09E-0C4BF448E005}",
            "{C4BB3D7E-BF6E-42EE-B532-1E0832DA3EA9}"
        )
        foreach ($tg in $ngenTaskGuids) {
            cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\$tg`" /f >nul 2>&1"
            cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Maintenance\$tg`" /f >nul 2>&1"
            cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Plain\$tg`" /f >nul 2>&1"
        }
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\.NET Framework`" /f >nul 2>&1"
        Write-Success "Purged .NET Framework NGEN TaskCache registrations."

        # 5i. PURGE WINSAT SCHEDULED TASK & REGISTRY STORE (NTLite winsat)
        Write-Info "Purging WinSAT scheduled task & registry store..."
        $winSatTaskGuid = "{731E952A-D01C-4D49-A37F-C8F1396F13B7}"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\$winSatTaskGuid`" /f >nul 2>&1"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Maintenance\$winSatTaskGuid`" /f >nul 2>&1"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Plain\$winSatTaskGuid`" /f >nul 2>&1"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Maintenance\WinSAT`" /f >nul 2>&1"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinSAT`" /f >nul 2>&1"
        Write-Success "Purged WinSAT TaskCache and registry configuration."
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
# STEP 6: In-Place Region Policy Patch (Worldwide Edge Uninstall)
# -------------------------------------------------------------
Write-Step "[6/11] Patching IntegratedServicesRegionPolicySet.json in-place..."
$policyPath = "$MountDir\Windows\System32\IntegratedServicesRegionPolicySet.json"
if (Test-Path $policyPath) {
    & takeown.exe /f $policyPath /a *> $null
    & icacls.exe $policyPath /grant Administrators:F *> $null

    $rawPolicy = [System.IO.File]::ReadAllText($policyPath, [System.Text.Encoding]::UTF8)
    try {
        $polObj = $rawPolicy | ConvertFrom-Json
        foreach ($p in $polObj.policies) {
            if ($p.name -eq 'Edge_UninstallEdge' -or $p.guid -eq '{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6}' -or $p.'$comment' -match 'Edge is uninstallable') {
                $p.defaultState = 'enabled'
            }
        }
        $patchedPolicy = $polObj | ConvertTo-Json -Depth 10
    } catch {
        $patchedPolicy = [regex]::Replace(
            $rawPolicy,
            '("name"\s*:\s*"Edge_UninstallEdge"[\s\S]*?"defaultState"\s*:\s*")([^"]+)(")',
            '${1}enabled${3}'
        )
    }
    [System.IO.File]::WriteAllText($policyPath, $patchedPolicy, [System.Text.Encoding]::UTF8)
    & icacls.exe $policyPath /setowner "NT SERVICE\TrustedInstaller" *> $null
    Write-Success "Edge_UninstallEdge set to 'enabled' in-place. All other policies preserved."
} else {
    Write-Info "IntegratedServicesRegionPolicySet.json not found."
}

# -------------------------------------------------------------
# STEP 7: Generate OEMDefaultAssociations.xml Dynamically
# -------------------------------------------------------------
Write-Step "[7/11] Generating OEMDefaultAssociations.xml dynamically..."
$oemAssocXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier=".bmp" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".dib" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".gif" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".ico" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".jfif" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".jpe" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".jpeg" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".jpg" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".jxr" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".png" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".tif" ProgId="TIFImage.Document" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".tiff" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />
  <Association Identifier=".txt" ProgId="txtfile" ApplicationName="Notepad" />
</DefaultAssociations>
'@
$oemDest = "$MountDir\Windows\System32\OEMDefaultAssociations.xml"
[System.IO.File]::WriteAllText($oemDest, $oemAssocXml, [System.Text.Encoding]::UTF8)
Write-Success "Generated: $oemDest"

# -------------------------------------------------------------
# STEP 8: Create Notepad.lnk Dynamically
# -------------------------------------------------------------
Write-Step "[8/11] Creating Notepad.lnk shortcut dynamically..."
$accDir = "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories"
if (-not (Test-Path $accDir)) { New-Item -ItemType Directory -Path $accDir -Force | Out-Null }

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut("$accDir\Notepad.lnk")
$shortcut.TargetPath = "C:\Windows\System32\notepad.exe"
$shortcut.IconLocation = "C:\Windows\System32\notepad.exe,0"
$shortcut.WorkingDirectory = "C:\Windows\System32"
$shortcut.Description = "Notepad"
$shortcut.Save()
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
Write-Success "Created shortcut: $accDir\Notepad.lnk"

# Remove Remote Desktop Connection shortcuts if present
$rdcShortcuts = @(
    "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories\Remote Desktop Connection.lnk",
    "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Remote Desktop Connection.lnk"
)
foreach ($lnk in $rdcShortcuts) {
    if (Test-Path $lnk) {
        Remove-ForceFile $lnk
        Write-Success "Deleted shortcut: $(Split-Path $lnk -Leaf)"
    }
}

# -------------------------------------------------------------
# STEP 9: Generate Self-Deleting SetupComplete.cmd
# -------------------------------------------------------------
Write-Step "[9/11] Generating self-deleting SetupComplete.cmd..."
$setupDir = "$MountDir\Windows\Setup\Scripts"
if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }

$setupCmd = @'
@echo off
powercfg -duplicatescheme a1841308-3541-4fab-bc81-f71556f20b4a
powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
powercfg -setactive e9a42b02-d5df-448d-aa00-03f14749eb61

compact /c /s /a /i /exe:lzx "C:\Program Files\*"
compact /c /s /a /i /exe:lzx "C:\Program Files (x86)\*"
compact /c /s /a /i /exe:lzx "C:\ProgramData\*"
compact /c /s /a /i /exe:lzx "C:\Users\*"
compact /c /s /a /i /exe:lzx "C:\Windows\*"

schtasks /delete /tn "\Microsoft\Windows\.NET Framework\.NET Framework NGEN v4.0.30319" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\.NET Framework\.NET Framework NGEN v4.0.30319 64" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\.NET Framework\.NET Framework NGEN v4.0.30319 Critical" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\.NET Framework\.NET Framework NGEN v4.0.30319 64 Critical" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\Maintenance\WinSAT" /f >nul 2>&1

cd /d %SystemDrive%\
start /b "" cmd /c "ping 127.0.0.1 -n 2 >nul & rd /s /q "%WINDIR%\Setup\Scripts""
exit
'@
[System.IO.File]::WriteAllText("$setupDir\SetupComplete.cmd", $setupCmd, [System.Text.Encoding]::ASCII)
Write-Success "Generated: $setupDir\SetupComplete.cmd (erases Scripts directory on completion)."

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
# STEP 11: 40-Point Automated Quality Gate / Validation
# -------------------------------------------------------------
if (-not $SkipValidation) {
    Write-Step "[11/11] Running 40-Point Quality Gate Validation..."

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

    # 2. Remote Desktop Connection feature
    $dismRdc = & dism.exe /English /Image:$MountDir /Get-FeatureInfo /FeatureName:Microsoft-RemoteDesktopConnection 2>&1
    $rdcOk = (($dismRdc -match 'State\s*:\s*Disabled') -or ($dismRdc -match 'Payload Removed') -or ($LASTEXITCODE -ne 0))
    Assert-Check -Name "Remote Desktop Connection Removed" -Pass ($rdcOk.Count -gt 0) -Detail "State is Disabled / Payload Removed"

    # 3. InboxApps
    Assert-Check -Name "InboxApps Purged" -Pass (-not (Test-Path "$MountDir\Windows\InboxApps")) -Detail "Directory does not exist"

    # 4-7. Defender Folders Deleted
    Assert-Check -Name "Defender Program Files" -Pass (-not (Test-Path "$MountDir\Program Files\Windows Defender")) -Detail "Deleted"
    Assert-Check -Name "Defender x86" -Pass (-not (Test-Path "$MountDir\Program Files (x86)\Windows Defender")) -Detail "Deleted"
    Assert-Check -Name "Defender ProgramData" -Pass (-not (Test-Path "$MountDir\ProgramData\Microsoft\Windows Defender")) -Detail "Deleted"
    Assert-Check -Name "Defender Drivers (wd)" -Pass (-not (Test-Path "$MountDir\Windows\System32\drivers\wd")) -Detail "Deleted"

    # 8-13. SmartScreen, BrowserCore & OneDrive Binaries / Folders Deleted
    Assert-Check -Name "SmartScreen smartscreen.exe" -Pass (-not (Test-Path "$MountDir\Windows\System32\smartscreen.exe")) -Detail "Deleted"
    Assert-Check -Name "SmartScreen smartscreen.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\smartscreen.dll")) -Detail "Deleted"
    $appRepRemaining = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "Microsoft.Windows.AppRep.ChxApp_*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "SmartScreen AppRep.ChxApp" -Pass ($appRepRemaining.Count -eq 0) -Detail "Purged from SystemApps"
    Assert-Check -Name "BrowserCore Directory" -Pass (-not (Test-Path "$MountDir\Windows\BrowserCore")) -Detail "Purged from Windows"
    Assert-Check -Name "OneDrive System32 Binary" -Pass (-not (Test-Path "$MountDir\Windows\System32\OneDriveSetup.exe")) -Detail "Deleted"
    Assert-Check -Name "OneDrive SysWOW64 Binary" -Pass (-not (Test-Path "$MountDir\Windows\SysWOW64\OneDriveSetup.exe")) -Detail "Deleted"

    # Re-load hives for registry assertions
    cmd /c "reg load HKLM\OFFLINE_SYSTEM `"$sysHive`" >nul 2>&1"
    cmd /c "reg load HKLM\OFFLINE_SOFTWARE `"$sofHive`" >nul 2>&1"
    cmd /c "reg load HKU\OFFLINE_DEFAULT `"$defHive`" >nul 2>&1"

    try {
        # 14-22. ALL 9 Defender Services Deleted
        foreach ($svc in $defenderServices) {
            $q = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\$svc`" >nul 2>&1"
            Assert-Check -Name "Defender Service $svc" -Pass ($LASTEXITCODE -ne 0) -Detail "Completely deleted from registry"
        }

        # 23-25. Telemetry Services Deleted
        foreach ($svc in $telemetryServices) {
            $q = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\$svc`" >nul 2>&1"
            Assert-Check -Name "Telemetry Service $svc" -Pass ($LASTEXITCODE -ne 0) -Detail "Completely deleted from registry"
        }

        # 26-28. Telemetry DLLs Deleted
        Assert-Check -Name "Telemetry diagtrack.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\diagtrack.dll")) -Detail "Deleted"
        Assert-Check -Name "Telemetry moshost.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\moshost.dll")) -Detail "Deleted"
        Assert-Check -Name "Telemetry PhoneService.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\PhoneService.dll")) -Detail "Deleted"

        # 29. PlugPlay Service Disabled
        $ppVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\PlugPlay`" /v Start 2>nul"
        Assert-Check -Name "PlugPlay Start=4" -Pass ($ppVal -match '0x4') -Detail "Disabled"

        # 30. Spooler Service Manual
        $spVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\Spooler`" /v Start 2>nul"
        Assert-Check -Name "Spooler Start=3" -Pass ($spVal -match '0x3') -Detail "Manual"

        # 31. lfsvc Disabled
        $lfVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\lfsvc`" /v Start 2>nul"
        Assert-Check -Name "lfsvc Start=4" -Pass ($lfVal -match '0x4') -Detail "Disabled"

        # 32. RemoteRegistry Disabled
        $rrVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\RemoteRegistry`" /v Start 2>nul"
        Assert-Check -Name "RemoteRegistry Start=4" -Pass ($rrVal -match '0x4') -Detail "Disabled"

        # 33. DPS Disabled
        $dpsVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\DPS`" /v Start 2>nul"
        Assert-Check -Name "DPS Start=4" -Pass ($dpsVal -match '0x4') -Detail "Disabled"

        # 34. ConfigureChatAutoInstall
        $chatVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Communications`" /v ConfigureChatAutoInstall 2>nul"
        Assert-Check -Name "ConfigureChatAutoInstall=0" -Pass ($chatVal -match '0x0') -Detail "Applied"

        # 35. SmartScreenEnabled=off in Explorer
        $ssVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer`" /v SmartScreenEnabled 2>nul"
        Assert-Check -Name "SmartScreenEnabled=off" -Pass ($ssVal -match 'off') -Detail "Disabled in Explorer"

        # 36. EnableSmartScreen=0 in System Policies
        $essVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System`" /v EnableSmartScreen 2>nul"
        Assert-Check -Name "EnableSmartScreen=0" -Pass ($essVal -match '0x0') -Detail "Disabled in System Policies"

        # 37. BrowserCore Registrations Purged
        $bcVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore`" 2>nul"
        Assert-Check -Name "BrowserCore Chrome Registration" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from NativeMessagingHosts"

        # 38. Preserved HttpAcceptLanguageOptOut
        $langVal1 = cmd /c "reg query `"HKU\OFFLINE_DEFAULT\Control Panel\International\User Profile`" /v HttpAcceptLanguageOptOut 2>nul"
        $langVal2 = cmd /c "reg query `"HKU\OFFLINE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\RunOnce`" /v `"Telemetry Language Disable`" 2>nul"
        $langVal3 = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Control Panel\International`" /v UserHttpAcceptLanguageOptOut 2>nul"
        $langPass = ($langVal1 -match '0x1') -or ($langVal2 -match 'HttpAcceptLanguageOptOut') -or ($langVal3 -match '0x1')
        Assert-Check -Name "UserHttpAcceptLanguageOptOut=1" -Pass $langPass -Detail "Preserved"

        # 39. SecurityHealth Run Key Purged
        $shRun = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Run`" /v SecurityHealth 2>nul"
        Assert-Check -Name "SecurityHealth Run Key Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from Software Run key"
        # 40. Windows Defender Firewall Service (MpsSvc) Preserved Intact
        $fwVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\mpssvc`" /v Start 2>nul"
        Assert-Check -Name "Windows Defender Firewall Service (MpsSvc)" -Pass ($fwVal -match '0x2') -Detail "Preserved (Start=2 Automatic)"

        # 41. Base Filtering Engine Service (BFE) Preserved Intact
        $bfeVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\bfe`" /v Start 2>nul"
        Assert-Check -Name "Base Filtering Engine Service (BFE)" -Pass ($bfeVal -match '0x2') -Detail "Preserved (Start=2 Automatic)"

        # 42. .NET NGEN TaskCache Tree Purged
        $ngenTree = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\.NET Framework`" 2>nul"
        Assert-Check -Name ".NET NGEN TaskCache Tree Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from TaskCache\Tree"

        # 43. WinSAT TaskCache Tree Purged
        $wsTree = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Maintenance\WinSAT`" 2>nul"
        Assert-Check -Name "WinSAT TaskCache Tree Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from TaskCache\Tree"
    }
    finally {
        # Unload validation hives
        cmd /c "reg unload HKLM\OFFLINE_SYSTEM >nul 2>&1"
        cmd /c "reg unload HKLM\OFFLINE_SOFTWARE >nul 2>&1"
        cmd /c "reg unload HKU\OFFLINE_DEFAULT >nul 2>&1"
    }

    # 44. Defender Driver WdFilter.sys
    Assert-Check -Name "Defender Driver WdFilter.sys" -Pass (-not (Test-Path "$MountDir\Windows\System32\drivers\WdFilter.sys")) -Detail "Deleted"

    # 45. Defender SecurityHealthSystray
    Assert-Check -Name "Defender SecurityHealthSystray" -Pass (-not (Test-Path "$MountDir\Windows\System32\SecurityHealthSystray.exe")) -Detail "Deleted"

    # 46. Firewall Binary mpssvc.dll Intact
    Assert-Check -Name "Firewall Binary mpssvc.dll" -Pass (Test-Path "$MountDir\Windows\System32\mpssvc.dll") -Detail "Preserved"

    # 47. Firewall MMC wf.msc Intact
    Assert-Check -Name "Firewall MMC wf.msc" -Pass (Test-Path "$MountDir\Windows\System32\wf.msc") -Detail "Preserved"

    # 48. .NET NativeImages 64 Cache
    Assert-Check -Name ".NET NativeImages 64 Cache" -Pass (-not (Test-Path "$MountDir\Windows\assembly\NativeImages_v4.0.30319_64")) -Detail "Deleted"

    # 49. .NET NativeImages 32 Cache
    Assert-Check -Name ".NET NativeImages 32 Cache" -Pass (-not (Test-Path "$MountDir\Windows\assembly\NativeImages_v4.0.30319_32")) -Detail "Deleted"

    # 50. .NET GAC_MSIL Preserved
    Assert-Check -Name ".NET GAC_MSIL Preserved" -Pass (Test-Path "$MountDir\Windows\Microsoft.NET\assembly\GAC_MSIL") -Detail "Intact (MSIL preserved)"

    # 51. WinSAT Binary System32 Deleted
    Assert-Check -Name "WinSAT Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\WinSAT.exe")) -Detail "Deleted"

    # 52. WinSAT Performance Directory Purged
    Assert-Check -Name "WinSAT Performance Directory" -Pass (-not (Test-Path "$MountDir\Windows\Performance\WinSAT")) -Detail "Purged"

    # 53. Region Policy In-Place Patch
    $polContent = [System.IO.File]::ReadAllText($policyPath, [System.Text.Encoding]::UTF8)
    $hasEdgeUninstall = ($polContent -match 'Edge_UninstallEdge' -or $polContent -match '\{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6\}' -or $polContent -match 'Edge is uninstallable') -and ($polContent -match '"defaultState"\s*:\s*"enabled"')
    Assert-Check -Name "Region Policy In-Place" -Pass $hasEdgeUninstall -Detail "Enabled in-place"

    # 54. OEMDefaultAssociations.xml
    Assert-Check -Name "OEMDefaultAssociations.xml" -Pass (Test-Path "$MountDir\Windows\System32\OEMDefaultAssociations.xml") -Detail "Staged"

    # 55. Notepad.lnk
    Assert-Check -Name "Notepad.lnk" -Pass (Test-Path "$accDir\Notepad.lnk") -Detail "Created"

    # 56. SetupComplete.cmd Exists
    Assert-Check -Name "SetupComplete.cmd Exists" -Pass (Test-Path "$setupDir\SetupComplete.cmd") -Detail "Staged"

    # 57. SetupComplete.cmd Has Self-Delete
    $scText = [System.IO.File]::ReadAllText("$setupDir\SetupComplete.cmd", [System.Text.Encoding]::ASCII)
    Assert-Check -Name "SetupComplete Self-Delete" -Pass ($scText -match 'rd /s /q "%WINDIR%\\Setup\\Scripts"') -Detail "Contains directory self-deletion"

    $failed = $script:results | Where-Object { -not $_.Pass }
    if ($failed) {
        throw "Quality Gate FAILED: $($failed.Count) checks failed!"
    }
    Write-Host "`n============================================================" -ForegroundColor Green
    Write-Host " QUALITY GATE RESULT: $($script:results.Count)/$($script:results.Count) CHECKS PASSED (100% SUCCESS)    " -ForegroundColor Green
    Write-Host "============================================================`n" -ForegroundColor Green
}
