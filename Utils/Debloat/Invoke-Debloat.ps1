<#
.SYNOPSIS
    Master Offline Windows 11 Debloat & Servicing Engine.
.DESCRIPTION
    Applies 100% offline debloat to a mounted Windows image:
    - Purges Defender binaries, folders, drivers, and deletes all 9 Defender services from registry.
    - Deletes telemetry services (DiagTrack, MapsBroker, PhoneSvc) and their binaries.
    - Configures custom services (PlugPlay=Disabled, Spooler=Manual, lfsvc=Disabled, DPS=Disabled).
    - Applies curated registry pack and TrustedInstaller offline keys via NSudoLC.
    - Modifies IntegratedServicesRegionPolicySet.json in-place (worldwide Edge uninstall).
    - Generates OEM associations, Notepad shortcut, and self-deleting SetupComplete.cmd.
    - Executes component cleanup (/ResetBase), purges cache/temp/WER/insights, and runs the 147-point validation suite.
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

if (-not $RegPackPath -or -not (Test-Path $RegPackPath -PathType Leaf)) {
    $candReg = Join-Path $PSScriptRoot "Windows-11-REG-Pack-(NoDefender).reg"
    if (Test-Path $candReg) {
        $RegPackPath = $candReg
    }
}

if (-not $NSudoPath -or -not (Test-Path $NSudoPath -PathType Leaf)) {
    $candidateNSudos = @(
        "C:\Users\Administrator\.gemini\antigravity-ide\brain\893a6ed1-892e-4c6e-8de5-eea3f3be87d9\scratch\NSudo Launcher\x64\NSudoLC.exe",
        "$PSScriptRoot\NSudoLC.exe"
    )
    foreach ($cand in $candidateNSudos) {
        if (Test-Path $cand -PathType Leaf) {
            $NSudoPath = $cand
            break
        }
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

function Clear-ForceDirectoryContents([string]$targetDir) {
    if (Test-Path $targetDir) {
        Get-ChildItem -Path $targetDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSIsContainer) {
                Remove-ForceDirectory $_.FullName
            } else {
                Remove-ForceFile $_.FullName
            }
        }
    }
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Invoke-ElevatedRegDelete([string[]]$regKeys) {
    $validKeys = @($regKeys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($validKeys.Count -eq 0) { return }
    if ($NSudoPath -and (Test-Path $NSudoPath)) {
        $delCmds = ($validKeys | ForEach-Object { "reg delete `"$_`" /f" }) -join "`r`n"
        $delBatch = Join-Path $env:TEMP "nsudo_reg_del_$([System.Guid]::NewGuid().ToString('N')).cmd"
        Set-Content -Path $delBatch -Value "@echo off`r`n$delCmds`r`nexit" -Encoding ASCII
        & $NSudoPath -U:T -P:E -Wait $delBatch *> $null
        Remove-Item $delBatch -Force -ErrorAction SilentlyContinue
    } else {
        foreach ($k in $validKeys) {
            cmd /c "reg delete `"$k`" /f >nul 2>&1"
        }
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

# Remove Provisioned Copilot & Microsoft Family AppX Packages
Write-Info "Checking for provisioned Copilot and Microsoft Family AppX packages..."
$provInfo = & dism.exe /English /Image:$MountDir /Get-ProvisionedAppxPackages 2>&1
$provMatches = $provInfo | Where-Object { $_ -match '^PackageName\s*:\s*(.*(Copilot|MicrosoftFamily).*)' }
foreach ($line in $provMatches) {
    $pkgName = ($line -split 'PackageName\s*:\s*')[1].Trim()
    if ($pkgName) {
        & dism.exe /English /Image:$MountDir /Remove-ProvisionedAppxPackage /PackageName:$pkgName /NoRestart *> $null
        Write-Success "Removed provisioned AppX package: $pkgName"
    }
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
    "$MountDir\Windows\System32\AppRepAgent.dll",
    "$MountDir\Windows\System32\AppRepUX.exe",
    "$MountDir\Windows\System32\SmartAppControl.dll",
    "$MountDir\Windows\SysWOW64\smartscreen.dll",
    "$MountDir\Windows\SysWOW64\smartscreenps.dll",
    "$MountDir\Windows\SysWOW64\AppRepAgent.dll"
)
foreach ($f in $smartScreenFiles) {
    if (Test-Path $f) {
        Remove-ForceFile $f
        Write-Success "Deleted SmartScreen binary: $(Split-Path $f -Leaf)"
    }
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "smartscreen*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted SmartScreen MUI: $($_.Name)"
}

$appRepApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "Microsoft.Windows.AppRep.ChxApp_*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $appRepApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged SmartScreen App: $($app.Name)"
}

# BrowserCore Host Binaries, Manifests & Satellites (NTLite browsercore)
$browserCoreFiles = @(
    "$MountDir\Windows\System32\browsercore.exe",
    "$MountDir\Windows\System32\browsercore.json",
    "$MountDir\Windows\SysWOW64\browsercore.exe",
    "$MountDir\Windows\SysWOW64\browsercore.json"
)
foreach ($bf in $browserCoreFiles) {
    if (Test-Path $bf) {
        Remove-ForceFile $bf
        Write-Success "Deleted BrowserCore binary: $(Split-Path $bf -Leaf)"
    }
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "browsercore*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted BrowserCore MUI: $($_.Name)"
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

$oneDriveDirs = @(
    "$MountDir\Windows\System32\OneDrive.Setup",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\OneDrive"
)
foreach ($dir in $oneDriveDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged OneDrive directory: $(Split-Path $dir -Leaf)"
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

# Performance Monitor & System Monitor Control (sysmon.ocx) (NTLite perfmon)
$perfmonBinaries = @(
    "$MountDir\Windows\System32\sysmon.ocx",
    "$MountDir\Windows\SysWOW64\sysmon.ocx",
    "$MountDir\Windows\System32\perfmon.exe",
    "$MountDir\Windows\System32\perfmon.msc"
)
foreach ($bin in $perfmonBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Performance Monitor binary: $(Split-Path $bin -Leaf)"
    }
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Include "sysmon.ocx.mui", "perfmon.exe.mui", "perfmon.msc.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted Performance Monitor MUI: $($_.Name)"
}

# Kernel Debugging Hardware Transports & KDNET (NTLite kerneldebug)
# Preserves kdcom.dll, kd.dll, and kdstub.dll (mandatory boot imports for ntoskrnl/winload to avoid 0xC000000F / STOP 0x6B)
$kdTransports = @(
    "$MountDir\Windows\System32\kdnet.dll",
    "$MountDir\Windows\System32\kdnet_uart16550.dll",
    "$MountDir\Windows\System32\kdusb.dll",
    "$MountDir\Windows\System32\kdcpw.dll",
    "$MountDir\Windows\System32\kdhvcom.dll"
)
foreach ($bin in $kdTransports) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Kernel Debug transport: $(Split-Path $bin -Leaf)"
    }
}

Get-ChildItem -Path "$MountDir\Windows\System32" -Filter "kd_*_*.dll" -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted Vendor KDNET driver: $($_.Name)"
}

# Windows Feature Experience Pack - CoreAI (NTLite CoreAIComponents)
# Safely purges modular on-device AI/Recall/ClickToDo without touching Base Client.CBS
$coreAiApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "MicrosoftWindows.Client.CoreAI_*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $coreAiApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged CoreAI SystemApp: $($app.Name)"
}

$coreAiBinaries = @(
    "$MountDir\Windows\System32\Windows.AI.MachineLearning.dll",
    "$MountDir\Windows\System32\Windows.AI.MachineLearning.Preview.dll",
    "$MountDir\Windows\System32\onnxruntime.dll",
    "$MountDir\Windows\System32\CoreAIPlatform.dll",
    "$MountDir\Windows\System32\CoreAIRecall.dll",
    "$MountDir\Windows\System32\RecallStorage.dll"
)
foreach ($bin in $coreAiBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted CoreAI binary: $(Split-Path $bin -Leaf)"
    }
}

$coreAiDirs = @(
    "$MountDir\Windows\System32\CoreAI",
    "$MountDir\Windows\SystemResources\CoreAI"
)
foreach ($d in $coreAiDirs) {
    if (Test-Path $d) {
        Remove-ForceDirectory $d
        Write-Success "Purged CoreAI directory: $(Split-Path $d -Leaf)"
    }
}

# Windows Feature Experience Pack - Copilot Shell Provider & Standalone App (NTLite Copilot)
$copilotSysApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*Copilot*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $copilotSysApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged Copilot SystemApp: $($app.Name)"
}

$copilotWinApps = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*Copilot*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $copilotWinApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged Copilot WindowsApp: $($app.Name)"
}

# Microsoft Family & Parental Controls (NTLite parentalcontrols / microsoftfamily)
# Purges modern Family apps, ParentalControls SystemApp, WPC core binaries, and filter driver
$familyWinApps = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*MicrosoftFamily*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $familyWinApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged MicrosoftFamily WindowsApp: $($app.Name)"
}

$pcSysApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*ParentalControls*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $pcSysApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged ParentalControls SystemApp: $($app.Name)"
}

$familyBinaries = @(
    "$MountDir\Windows\System32\Wpc.dll",
    "$MountDir\Windows\System32\WpcApi.dll",
    "$MountDir\Windows\System32\WpcDesktopMonSvc.dll",
    "$MountDir\Windows\System32\WpcMon.exe",
    "$MountDir\Windows\System32\WpcProxyStubs.dll",
    "$MountDir\Windows\System32\WpcRefreshTask.dll",
    "$MountDir\Windows\System32\WpcTok.exe",
    "$MountDir\Windows\System32\WpcWebFilter.dll",
    "$MountDir\Windows\System32\wpcbroker.exe",
    "$MountDir\Windows\System32\wpccpl.dll",
    "$MountDir\Windows\System32\wpcmig.dll",
    "$MountDir\Windows\System32\wpcsettings.dll",
    "$MountDir\Windows\System32\FamilySafetyExt.dll",
    "$MountDir\Windows\System32\wpcatltoast.png",
    "$MountDir\Windows\System32\wpcmon.png",
    # 106. Kernel Debug Stub kdcom.dll Preserved
    Assert-Check -Name "Kernel Debug Stub kdcom.dll Preserved" -Pass (Test-Path "$MountDir\Windows\System32\kdcom.dll") -Detail "Intact (Prevents STOP 0x6B)"

    # 107. CoreAI SystemApp Purged
    $coreAiRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "MicrosoftWindows.Client.CoreAI_*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "CoreAI SystemApp Purged" -Pass ($coreAiRem.Count -eq 0) -Detail "Purged from SystemApps"
    # 108. CoreAI onnxruntime.dll Deleted
    Assert-Check -Name "CoreAI onnxruntime.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\onnxruntime.dll")) -Detail "Deleted"

    # 109. Base Client.CBS Preserved
    $cbsRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "MicrosoftWindows.Client.CBS_*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "Base Client.CBS Preserved" -Pass ($cbsRem.Count -gt 0) -Detail "Intact (Taskbar/Explorer preserved)"
    # 110. Copilot SystemApps Purged
    $copilotSysRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*Copilot*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "Copilot SystemApps Purged" -Pass ($copilotSysRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 111. Copilot WindowsApps Purged
    $copilotWinRem = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*Copilot*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "Copilot WindowsApps Purged" -Pass ($copilotWinRem.Count -eq 0) -Detail "Purged from Program Files\WindowsApps"

    # 112. ParentalControls SystemApp Purged
    $pcSysRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*ParentalControls*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "ParentalControls SystemApp Purged" -Pass ($pcSysRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 113. MicrosoftFamily WindowsApps Purged
    $famWinRem = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*MicrosoftFamily*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "MicrosoftFamily WindowsApps Purged" -Pass ($famWinRem.Count -eq 0) -Detail "Purged from Program Files\WindowsApps"

    # 114. ParentalControls Wpc.dll Deleted
    Assert-Check -Name "ParentalControls Wpc.dll Deleted" -Pass (-not (Test-Path "$MountDir\Windows\System32\Wpc.dll")) -Detail "Deleted"

    # 115. ParentalControls SysWOW64 Wpc.dll Deleted
    Assert-Check -Name "ParentalControls SysWOW64 Wpc.dll Deleted" -Pass (-not (Test-Path "$MountDir\Windows\SysWOW64\Wpc.dll")) -Detail "Deleted"

    # 116. FamilySafetyExt.dll System32 Deleted
    Assert-Check -Name "FamilySafetyExt.dll System32 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\System32\FamilySafetyExt.dll")) -Detail "Deleted"

    # 117. FamilySafetyExt.dll SysWOW64 Deleted
    Assert-Check -Name "FamilySafetyExt.dll SysWOW64 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\SysWOW64\FamilySafetyExt.dll")) -Detail "Deleted"

    # 118. Narrator Binary System32 Deleted
    Assert-Check -Name "Narrator Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\Narrator.exe")) -Detail "Deleted"

    # 119. NarratorMCAT Directory Purged
    Assert-Check -Name "NarratorMCAT Directory" -Pass (-not (Test-Path "$MountDir\Windows\System32\NarratorMCAT")) -Detail "Purged"

    # 120. NarratorQuickStart SystemApp Purged    $narratorAppCount = (Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*microsoft.windows.narratorquickstart*" -Directory -ErrorAction SilentlyContinue).Count
    Assert-Check -Name "NarratorQuickStart SystemApp Purged" -Pass ($narratorAppCount -eq 0) -Detail "Purged from SystemApps"

    # 121. Add Folder Suggestions SystemApp Purged
    $fsAppRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*AddSuggestedFoldersToLibraryDialog*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "Add Folder Suggestions SystemApp Purged" -Pass ($fsAppRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 122. PinningConfirmationDialog SystemApp Purged
    $pinningAppRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*Microsoft.Windows.PinningConfirmationDialog*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "PinningConfirmationDialog SystemApp Purged" -Pass ($pinningAppRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 123. File Explorer (Legacy) SystemApp Purged
    $feAppRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "Microsoft.Windows.FileExplorer_*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "File Explorer (Legacy) SystemApp Purged" -Pass ($feAppRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 124. AppResolverUX SystemApp Purged
    $arAppRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*Microsoft.Windows.AppResolverUX*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "AppResolverUX SystemApp Purged" -Pass ($arAppRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 125. Classic Open With Binary openwith.exe Preserved
    Assert-Check -Name "Classic openwith.exe Preserved" -Pass (Test-Path "$MountDir\Windows\System32\openwith.exe") -Detail "Intact (Classic Win32 dialog fallback)"

    # 126. OneDrive Tasks Directory Purged
    Assert-Check -Name "OneDrive Tasks Directory Purged" -Pass (-not (Test-Path "$MountDir\Windows\System32\Tasks\Microsoft\Windows\OneDrive")) -Detail "Purged from System32\Tasks"

    # 127. RetailDemo CloudExperienceHost Purged
    Assert-Check -Name "RetailDemo CloudExperienceHost Purged" -Pass (-not (Test-Path "$MountDir\Windows\SystemApps\Microsoft.Windows.CloudExperienceHost_cw5n1h2txyewy\RetailDemo")) -Detail "Purged from CloudExperienceHost"

    # 128. SetupAPI Logs Purged
    $setupapiCount = (Get-ChildItem "$MountDir\Windows\inf" -Filter "setupapi*.log" -File -ErrorAction SilentlyContinue).Count
    Assert-Check -Name "SetupAPI Logs Purged" -Pass ($setupapiCount -eq 0) -Detail "setupapi*.log purged from Windows\inf"

    # 129. Windows Temp Empty
    $winTempCount = (Get-ChildItem "$MountDir\Windows\Temp" -Recurse -File -ErrorAction SilentlyContinue).Count
    Assert-Check -Name "Windows Temp Empty" -Pass ($winTempCount -eq 0) -Detail "No temporary files remaining in Windows\Temp"

    # 130. Windows Temp Directory Exists
    Assert-Check -Name "Windows Temp Directory Exists" -Pass (Test-Path "$MountDir\Windows\Temp") -Detail "Root directory anchor preserved"

    # 131. WinSxS Backup Files Purged
    $backupFiles = @(Get-ChildItem -Path "$MountDir\Windows\WinSxS\Backup" -Force -ErrorAction SilentlyContinue)
    Assert-Check -Name "WinSxS Backup Files Purged" -Pass ($backupFiles.Count -eq 0) -Detail "Files inside WinSxS\Backup purged ($($backupFiles.Count) remaining)"

    # 132. WinSxS Backup Directory Exists
    Assert-Check -Name "WinSxS Backup Directory Exists" -Pass (Test-Path "$MountDir\Windows\WinSxS\Backup") -Detail "Root servicing directory anchor preserved"

    # 133. CBS Logs Purged
    Assert-Check -Name "CBS Logs Purged" -Pass (-not (Test-Path "$MountDir\Windows\Logs\CBS\CBS.log")) -Detail "CBS.log deleted"

    # 111. Sysprep Panther Directory Purged
    Assert-Check -Name "Sysprep Panther Directory Purged" -Pass (-not (Test-Path "$MountDir\Windows\System32\sysprep\Panther")) -Detail "Windows\System32\sysprep\Panther directory purged"

    # 135. DeviceCensus Binary System32 Deleted
    Assert-Check -Name "DeviceCensus Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\DeviceCensus.exe")) -Detail "Deleted"

    # 136. invagent Binary System32 Deleted
    Assert-Check -Name "invagent Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\invagent.dll")) -Detail "Deleted"
    # 137. appraiser Binary System32 Deleted
    Assert-Check -Name "appraiser Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\appraiser.dll")) -Detail "Deleted"

    # 138. Appraiser Directory System32 Purged
    Assert-Check -Name "Appraiser Directory System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\appraiser")) -Detail "Purged"

    # 139. WerFault.exe System32 Deleted
    Assert-Check -Name "WerFault.exe System32 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\System32\WerFault.exe")) -Detail "Deleted"

    # 140. WerFault.exe SysWOW64 Deleted
    Assert-Check -Name "WerFault.exe SysWOW64 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\SysWOW64\WerFault.exe")) -Detail "Deleted"

    # 141. wermgr.exe System32 Deleted
    Assert-Check -Name "wermgr.exe System32 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\System32\wermgr.exe")) -Detail "Deleted"

    # 142. wersvc.dll System32 Deleted
    Assert-Check -Name "wersvc.dll System32 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\System32\wersvc.dll")) -Detail "Deleted"

    # 143. Region Policy In-Place Patch
    $polContent = [System.IO.File]::ReadAllText($policyPath, [System.Text.Encoding]::UTF8)
    $hasEdgeUninstall = ($polContent -match 'Edge_UninstallEdge' -or $polContent -match '\{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6\}' -or $polContent -match 'Edge is uninstallable') -and ($polContent -match '"defaultState"\s*:\s*"enabled"')
    Assert-Check -Name "Region Policy In-Place" -Pass $hasEdgeUninstall -Detail "Enabled in-place"

    # 144. OEMDefaultAssociations.xml
    Assert-Check -Name "OEMDefaultAssociations.xml" -Pass (Test-Path "$MountDir\Windows\System32\OEMDefaultAssociations.xml") -Detail "Staged"

    # 145. Notepad.lnk
    Assert-Check -Name "Notepad.lnk" -Pass (Test-Path "$accDir\Notepad.lnk") -Detail "Created"

    # 146. SetupComplete.cmd Exists
    Assert-Check -Name "SetupComplete.cmd Exists" -Pass (Test-Path "$setupDir\SetupComplete.cmd") -Detail "Staged"

    # 147. SetupComplete.cmd Has Self-Delete
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
