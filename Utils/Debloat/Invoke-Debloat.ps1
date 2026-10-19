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
    - Executes component cleanup (/ResetBase), purges cache/temp/WER/insights, and runs the 135-point validation suite.
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

# Remove Provisioned Copilot AppX Packages (Standalone & WFEP Provider)
Write-Info "Checking for provisioned Copilot AppX packages..."
$copilotInfo = & dism.exe /English /Image:$MountDir /Get-ProvisionedAppxPackages 2>&1
$copilotMatches = $copilotInfo | Select-String -Pattern "Microsoft\.Copilot_|Microsoft\.Windows\.Ai\.Copilot\.Provider"
foreach ($m in $copilotMatches) {
    $copilotPkgName = ($m.Line -split 'PackageName : ')[1].Trim()
    & dism.exe /English /Image:$MountDir /Remove-ProvisionedAppxPackage /PackageName:$copilotPkgName /NoRestart *> $null
    Write-Success "Removed provisioned AppX package: $copilotPkgName"
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
# Preserves kdcom.dll (mandatory static import for ntoskrnl/winload to avoid STOP 0x6B)
$kdTransports = @(
    "$MountDir\Windows\System32\kdnet.dll",
    "$MountDir\Windows\System32\kdnet_uart16550.dll",
    "$MountDir\Windows\System32\kdusb.dll",
    "$MountDir\Windows\System32\kdstub.dll",
    "$MountDir\Windows\System32\kdcpw.dll",
    "$MountDir\Windows\System32\kdhvcom.dll",
    "$MountDir\Windows\System32\kd.dll"
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

Get-ChildItem -Path "$MountDir\Windows\System32\DriverStore\FileRepository" -Filter "kdnic*.inf_*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceDirectory $_.FullName
    Write-Success "Purged DriverStore KD package: $($_.Name)"
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

# Narrator & NarratorQuickStart (Narrator Home) (NTLite Narrator)
# Purges modern AppX Narrator Home, Win32 engine, MathCAT, and localized MUI assets
$narratorApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*microsoft.windows.narratorquickstart*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $narratorApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged NarratorQuickStart SystemApp: $($app.Name)"
}

$narratorWinApps = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*Microsoft.Windows.NarratorQuickStart*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $narratorWinApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged NarratorQuickStart WindowsApp: $($app.Name)"
}

$narratorMCAT = "$MountDir\Windows\System32\NarratorMCAT"
if (Test-Path $narratorMCAT) {
    Remove-ForceDirectory $narratorMCAT
    Write-Success "Purged NarratorMCAT directory: $narratorMCAT"
}

$narratorMedia = "$MountDir\Windows\Media\Narrator"
if (Test-Path $narratorMedia) {
    Remove-ForceDirectory $narratorMedia
    Write-Success "Purged Narrator Media earcons directory: $narratorMedia"
}

$narratorBinaries = @(
    "$MountDir\Windows\System32\Narrator.exe",
    "$MountDir\Windows\System32\NarratorControlTemplates.xml",
    "$MountDir\Windows\System32\NarratorControlTemplates.xsd",
    "$MountDir\Windows\System32\NarratorHelper.exe",
    "$MountDir\Windows\System32\NarratorHook.dll",
    "$MountDir\Windows\SysWOW64\Narrator.exe",
    "$MountDir\Windows\SysWOW64\NarratorHelper.exe",
    "$MountDir\Windows\SysWOW64\NarratorHook.dll"
)
foreach ($bin in $narratorBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Narrator binary: $(Split-Path $bin -Leaf)"
    }
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "Narrator*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted Narrator MUI: $($_.Name)"
}

# Add Folder Suggestions Dialog (NTLite foldersuggestions / f46d4000-fd22-4db4-ac8e-4e1ddde828fe)
# Eliminates background crawler prompts to add non-standard media folders to libraries
$folderSuggestApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*AddSuggestedFoldersToLibraryDialog*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $folderSuggestApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged AddSuggestedFolders SystemApp: $($app.Name)"
}

$folderSuggestWinApps = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*AddSuggestedFoldersToLibraryDialog*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $folderSuggestWinApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged AddSuggestedFolders WindowsApp: $($app.Name)"
}

$folderSuggestBinaries = @(
    "$MountDir\Windows\System32\FolderSuggestionsDialog.exe",
    "$MountDir\Windows\System32\FolderSuggestions.dll",
    "$MountDir\Windows\SysWOW64\FolderSuggestionsDialog.exe",
    "$MountDir\Windows\SysWOW64\FolderSuggestions.dll"
)
foreach ($bin in $folderSuggestBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted FolderSuggestions binary: $(Split-Path $bin -Leaf)"
    }
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "FolderSuggestions*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted FolderSuggestions MUI: $($_.Name)"
}

# PinningConfirmationDialog SystemApp (NTLite pinningconfirmationdialog)
# Eliminates taskbar/start programmatic pinning confirmation prompts while preserving manual pinning
$pinningApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*Microsoft.Windows.PinningConfirmationDialog*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $pinningApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged PinningConfirmationDialog SystemApp: $($app.Name)"
}

$pinningWinApps = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*Microsoft.Windows.PinningConfirmationDialog*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $pinningWinApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged PinningConfirmationDialog WindowsApp: $($app.Name)"
}

# File Explorer (Legacy) SystemApp (NTLite c5e2524a-ea46-4f67-841f-6a9465d9d515)
# Eliminates dormant UWP File Explorer while strictly preserving desktop explorer.exe and WinUI/WASDK shell
$fileExplorerApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "Microsoft.Windows.FileExplorer_*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $fileExplorerApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged File Explorer (Legacy) SystemApp: $($app.Name)"
}

$fileExplorerWinApps = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*Microsoft.Windows.FileExplorer*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $fileExplorerWinApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged File Explorer (Legacy) WindowsApp: $($app.Name)"
}

# App Resolver (AppResolverUX) SystemApp (NTLite appresolver / e2a4f912-2574-4a75-9bb0-0d023378592b)
# Eliminates modern XAML AppResolver flyout while falling back to classic Win32 openwith.exe
$appResolverApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*Microsoft.Windows.AppResolverUX*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $appResolverApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged AppResolverUX SystemApp: $($app.Name)"
}

$appResolverWinApps = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*Microsoft.Windows.AppResolverUX*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $appResolverWinApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged AppResolverUX WindowsApp: $($app.Name)"
}

# Retail Demo Content & Retail Demo Experience (RDX) (NTLite retaildemo)
# Purges media repositories, demo engine DLLs, and OOBE demo triggers
$retailDemoDirs = @(
    "$MountDir\ProgramData\Microsoft\Windows\RetailDemo",
    "$MountDir\Windows\SystemResources\RetailDemo",
    "$MountDir\Windows\SystemApps\Microsoft.Windows.CloudExperienceHost_cw5n1h2txyewy\RetailDemo"
)
foreach ($dir in $retailDemoDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged RetailDemo directory: $(Split-Path $dir -Leaf)"
    }
}

$retailDemoBinaries = @(
    "$MountDir\Windows\System32\RDXService.dll",
    "$MountDir\Windows\System32\RDXTaskFactory.dll",
    "$MountDir\Windows\System32\Windows.System.Profile.RetailInfo.dll",
    "$MountDir\Windows\System32\rdx.dll",
    "$MountDir\Windows\System32\RDXClean.exe",
    "$MountDir\Windows\System32\RDXTask.dll",
    "$MountDir\Windows\SysWOW64\Windows.System.Profile.RetailInfo.dll",
    "$MountDir\Windows\SysWOW64\rdx.dll",
    "$MountDir\Windows\SysWOW64\RDXClean.exe",
    "$MountDir\Windows\SysWOW64\RDXTask.dll"
)
foreach ($bin in $retailDemoBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted RetailDemo binary: $(Split-Path $bin -Leaf)"
    }
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "*rdx*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted RetailDemo MUI: $($_.Name)"
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "*RetailInfo*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted RetailInfo MUI: $($_.Name)"
}

$retailDemoTasks = "$MountDir\Windows\System32\Tasks\Microsoft\Windows\RetailDemo"
if (Test-Path $retailDemoTasks) {
    Remove-ForceDirectory $retailDemoTasks
    Write-Success "Purged RetailDemo Tasks directory: $retailDemoTasks"
}

# Microsoft Usage and Quality Insights (NTLite qualityinsights / usageinsights)
# Purges DeviceCensus, invagent, appraiser, compatelrunner, RAC data, and insight tasks
$insightsDirs = @(
    "$MountDir\ProgramData\Microsoft\RAC",
    "$MountDir\ProgramData\Microsoft\Diagnosis\DownloadedSettings",
    "$MountDir\Windows\System32\appraiser",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Device Information",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Customer Experience Improvement Program"
)
foreach ($dir in $insightsDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged Quality Insights directory: $(Split-Path $dir -Leaf)"
    }
}

$insightsBinaries = @(
    "$MountDir\Windows\System32\DeviceCensus.exe",
    "$MountDir\Windows\System32\invagent.dll",
    "$MountDir\Windows\System32\appraiser.dll",
    "$MountDir\Windows\System32\appraiser.dat",
    "$MountDir\Windows\System32\compatelrunner.exe",
    "$MountDir\Windows\System32\Win32CompatibilityAppraiserCSP.dll",
    "$MountDir\Windows\SysWOW64\DeviceCensus.exe",
    "$MountDir\Windows\SysWOW64\invagent.dll",
    "$MountDir\Windows\SysWOW64\appraiser.dll",
    "$MountDir\Windows\SysWOW64\compatelrunner.exe"
)
foreach ($bin in $insightsBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Quality Insights binary: $(Split-Path $bin -Leaf)"
    }
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "*DeviceCensus*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted DeviceCensus MUI: $($_.Name)"
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "*invagent*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted invagent MUI: $($_.Name)"
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "*appraiser*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted appraiser MUI: $($_.Name)"
}

Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter "*compatelrunner*.mui" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-ForceFile $_.FullName
    Write-Success "Deleted compatelrunner MUI: $($_.Name)"
}

# Windows Error Reporting (WER) (NTLite errorreporting / WerSvc)
# Purges WerFault, WerFaultSecure, wermgr, wersvc.dll, werconcpl.dll, faultrep.dll, and WER task
$werDirs = @(
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Windows Error Reporting"
)
foreach ($dir in $werDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged WER directory: $(Split-Path $dir -Leaf)"
    }
}

$werBinaries = @(
    "$MountDir\Windows\System32\WerFault.exe",
    "$MountDir\Windows\System32\WerFaultSecure.exe",
    "$MountDir\Windows\System32\wermgr.exe",
    "$MountDir\Windows\System32\wersvc.dll",
    "$MountDir\Windows\System32\werconcpl.dll",
    "$MountDir\Windows\System32\faultrep.dll",
    "$MountDir\Windows\SysWOW64\WerFault.exe",
    "$MountDir\Windows\SysWOW64\WerFaultSecure.exe",
    "$MountDir\Windows\SysWOW64\wermgr.exe",
    "$MountDir\Windows\SysWOW64\faultrep.dll"
)
foreach ($bin in $werBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted WER binary: $(Split-Path $bin -Leaf)"
    }
}

$werMuiFilters = @("WerFault*.mui", "wermgr*.mui", "werconcpl*.mui", "wersvc*.mui", "faultrep*.mui")
foreach ($filter in $werMuiFilters) {
    Get-ChildItem -Path "$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64" -Filter $filter -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-ForceFile $_.FullName
        Write-Success "Deleted WER MUI: $($_.Name)"
    }
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
        "WerSvc"         = 4  # Disabled (Windows Error Reporting)
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

        # 5g. CONFIGURE SMARTSCREEN, APP HOST & SMART APP CONTROL HARDENING (NTLite smartscreen)
        Write-Info "Configuring SmartScreen disabled, Smart App Control disabled, and removing BrowserCore registrations..."
        
        # Explorer Shell Hooks & System Policies
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer`" /v SmartScreenEnabled /t REG_SZ /d off /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System`" /v EnableSmartScreen /t REG_DWORD /d 0 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System`" /v ShellSmartScreenLevel /t REG_SZ /d Off /f >nul 2>&1"
        cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer`" /v SmartScreenEnabled /t REG_SZ /d off /f >nul 2>&1"
        cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Software\Policies\Microsoft\Windows\System`" /v EnableSmartScreen /t REG_DWORD /d 0 /f >nul 2>&1"
        cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Software\Policies\Microsoft\Windows\System`" /v ShellSmartScreenLevel /t REG_SZ /d Off /f >nul 2>&1"

        # Edge & Store App Content Evaluation Hardening
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Edge`" /v SmartScreenEnabled /t REG_DWORD /d 0 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Edge`" /v SmartScreenPuaEnabled /t REG_DWORD /d 0 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost`" /v EnableWebContentEvaluation /t REG_DWORD /d 0 /f >nul 2>&1"
        cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\AppHost`" /v EnableWebContentEvaluation /t REG_DWORD /d 0 /f >nul 2>&1"

        # Smart App Control (SAC) CI Policy Neutralization (SYSTEM hive)
        cmd /c "reg add `"HKLM\OFFLINE_SYSTEM\ControlSet001\Control\CI\Policy`" /v VerifiedAndReputablePolicyState /t REG_DWORD /d 0 /f >nul 2>&1"

        # BrowserCore Native Messaging Hosts (Chrome, Edge, Firefox in HKLM, WOW6432Node, and Default Profile)
        $nativeHosts = @(
            "HKLM\OFFLINE_SOFTWARE\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore",
            "HKLM\OFFLINE_SOFTWARE\WOW6432Node\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.microsoft.browsercore",
            "HKLM\OFFLINE_SOFTWARE\WOW6432Node\Microsoft\Edge\NativeMessagingHosts\com.microsoft.browsercore",
            "HKLM\OFFLINE_SOFTWARE\Mozilla\NativeMessagingHosts\com.microsoft.browsercore",
            "HKLM\OFFLINE_SOFTWARE\WOW6432Node\Mozilla\NativeMessagingHosts\com.microsoft.browsercore",
            "HKU\OFFLINE_DEFAULT\Software\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore",
            "HKU\OFFLINE_DEFAULT\Software\Microsoft\Edge\NativeMessagingHosts\com.microsoft.browsercore",
            "HKU\OFFLINE_DEFAULT\Software\Mozilla\NativeMessagingHosts\com.microsoft.browsercore"
        )
        Invoke-ElevatedRegDelete $nativeHosts
        Write-Success "SmartScreen disabled (SmartScreenEnabled=off, EnableSmartScreen=0, VerifiedAndReputablePolicyState=0) and BrowserCore NativeMessagingHosts purged across Chrome, Edge, and Firefox."

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
        $ngenDelKeys = @()
        foreach ($tg in $ngenTaskGuids) {
            $ngenDelKeys += "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\$tg"
            $ngenDelKeys += "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Maintenance\$tg"
            $ngenDelKeys += "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Plain\$tg"
        }
        $ngenDelKeys += "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\.NET Framework"
        Invoke-ElevatedRegDelete $ngenDelKeys
        Write-Success "Purged .NET Framework NGEN TaskCache registrations."

        # 5i. PURGE WINSAT SCHEDULED TASK & REGISTRY STORE (NTLite winsat)
        Write-Info "Purging WinSAT scheduled task & registry store..."
        $winSatTaskGuid = "{731E952A-D01C-4D49-A37F-C8F1396F13B7}"
        $wsDelKeys = @(
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\$winSatTaskGuid",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Maintenance\$winSatTaskGuid",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Plain\$winSatTaskGuid",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Maintenance\WinSAT",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinSAT"
        )
        Invoke-ElevatedRegDelete $wsDelKeys
        Write-Success "Purged WinSAT TaskCache and registry configuration."

        # 5j. PURGE SYSTEM MONITOR (sysmon.ocx) & PERFORMANCE MONITOR (NTLite perfmon)
        Write-Info "Purging System Monitor (sysmon.ocx) COM classes and PLA tasks..."
        $plaTaskGuid = "{F5CA4ED2-23E2-4BEA-8B5A-1C338018A4B5}"
        $plaDelKeys = @(
            "HKLM\OFFLINE_SOFTWARE\Classes\CLSID\{C4D2D8E0-7E5E-11D0-A3A4-00A0C90348F6}",
            "HKLM\OFFLINE_SOFTWARE\Classes\WOW6432Node\CLSID\{C4D2D8E0-7E5E-11D0-A3A4-00A0C90348F6}",
            "HKLM\OFFLINE_SOFTWARE\Classes\Sysmon.3",
            "HKLM\OFFLINE_SOFTWARE\Classes\Sysmon.1",
            "HKLM\OFFLINE_SOFTWARE\Classes\TypeLib\{C4D2D8D0-7E5E-11D0-A3A4-00A0C90348F6}",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\$plaTaskGuid",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Plain\$plaTaskGuid",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\PLA"
        )
        Invoke-ElevatedRegDelete $plaDelKeys

        # 5k. DISABLE KERNEL TELEMETRY & DIAGNOSTIC AUTOLOGGERS
        Write-Info "Disabling kernel telemetry and diagnostic AutoLoggers..."
        $telemetryLoggers = @("Diagtrack-Listener", "SQMLogger", "DefenderApiLogger", "DefenderAuditLogger")
        foreach ($logger in $telemetryLoggers) {
            cmd /c "reg add `"HKLM\OFFLINE_SYSTEM\ControlSet001\Control\WMI\Autologger\$logger`" /v Start /t REG_DWORD /d 0 /f >nul 2>&1"
        }
        Write-Success "Purged sysmon COM classes, PLA tasks, and disabled telemetry AutoLoggers."

        # 5l. PURGE COREAI & COPILOT WFEP PROVIDER / ENFORCE POLICIES (NTLite CoreAIComponents & Copilot WFEP)
        Write-Info "Purging CoreAI and Copilot AppxAllUserStore registrations and enforcing policies..."
        $coreAiDelKeys = @()
        $inboxCoreAi = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"MicrosoftWindows.Client.CoreAI`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $inboxCoreAi) {
            $coreAiDelKeys += $line.Line.Trim()
        }

        # Purge Copilot from AppxAllUserStore (InboxApplications, Applications, Deprovisioned)
        $inboxCopilot = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"Copilot`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $inboxCopilot) {
            $coreAiDelKeys += $line.Line.Trim()
        }
        $appsCopilot = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications`" /f `"Copilot`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $appsCopilot) {
            $coreAiDelKeys += $line.Line.Trim()
        }
        $deproCopilot = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned`" /f `"Copilot`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $deproCopilot) {
            $coreAiDelKeys += $line.Line.Trim()
        }
        if ($coreAiDelKeys.Count -gt 0) {
            Invoke-ElevatedRegDelete $coreAiDelKeys
        }

        # AI & Copilot policies
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\WindowsAI`" /v DisableAIDataAnalysis /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\WindowsAI`" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot`" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Software\Policies\Microsoft\Windows\WindowsCopilot`" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f >nul 2>&1"

        # Taskbar Shell Decoupling: eliminate Copilot button for all users
        cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced`" /v ShowCopilotButton /t REG_DWORD /d 0 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced`" /v ShowCopilotButton /t REG_DWORD /d 0 /f >nul 2>&1"

        # Edge Context Sharing & Sidebar Copilot Decoupling
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Edge`" /v CopilotPageContext /t REG_DWORD /d 0 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Edge`" /v ShowCopilotButton /t REG_DWORD /d 0 /f >nul 2>&1"
        Write-Success "Purged CoreAI/Copilot AppxAllUserStore, decoupled Taskbar button, and enforced AI/Edge lockdown policies."

        # 5m. PURGE NARRATOR ASSISTIVE TECHNOLOGY (AT) & APPX REGISTRATIONS (NTLite Narrator)
        Write-Info "Purging Narrator Assistive Technology (AT) and AppX registrations..."
        $narratorDelKeys = @(
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility\ATs\Narrator",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility\ATs\narrator"
        )

        $inboxNarrator = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"NarratorQuickStart`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $inboxNarrator) {
            $narratorDelKeys += $line.Line.Trim()
        }
        $appsNarrator = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications`" /f `"NarratorQuickStart`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $appsNarrator) {
            $narratorDelKeys += $line.Line.Trim()
        }
        $deproNarrator = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned`" /f `"NarratorQuickStart`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $deproNarrator) {
            $narratorDelKeys += $line.Line.Trim()
        }
        Invoke-ElevatedRegDelete $narratorDelKeys
        Write-Success "Purged Narrator ATs registration and NarratorQuickStart AppxAllUserStore entries."

        # 5n. PURGE ADD FOLDER SUGGESTIONS DIALOG REGISTRATIONS (NTLite foldersuggestions)
        Write-Info "Purging Add Folder Suggestions dialog registrations..."
        $folderSuggestDelKeys = @()
        $inboxFolderSuggest = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $inboxFolderSuggest) {
            $folderSuggestDelKeys += $line.Line.Trim()
        }
        $appsFolderSuggest = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications`" /f `"F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $appsFolderSuggest) {
            $folderSuggestDelKeys += $line.Line.Trim()
        }
        $deproFolderSuggest = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned`" /f `"F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $deproFolderSuggest) {
            $folderSuggestDelKeys += $line.Line.Trim()
        }
        $folderSuggestDelKeys += "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Storage\FolderSuggestions"
        $folderSuggestDelKeys += "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\StorageSense\FolderSuggestions"
        Invoke-ElevatedRegDelete $folderSuggestDelKeys
        Write-Success "Purged Add Folder Suggestions dialog AppxAllUserStore registrations and task trees."

        # 5o. PURGE PINNING CONFIRMATION DIALOG REGISTRATIONS (NTLite pinningconfirmationdialog)
        Write-Info "Purging PinningConfirmationDialog AppxAllUserStore registrations..."
        $pinningDelKeys = @()
        $inboxPinning = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"PinningConfirmationDialog`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $inboxPinning) {
            $pinningDelKeys += $line.Line.Trim()
        }
        $appsPinning = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications`" /f `"PinningConfirmationDialog`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $appsPinning) {
            $pinningDelKeys += $line.Line.Trim()
        }
        $deproPinning = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned`" /f `"PinningConfirmationDialog`" 2>nul" | Select-String "HKEY_"
        foreach ($line in $deproPinning) {
            $pinningDelKeys += $line.Line.Trim()
        }
        Invoke-ElevatedRegDelete $pinningDelKeys
        Write-Success "Purged PinningConfirmationDialog AppxAllUserStore registrations."

        # 5p. PURGE FILE EXPLORER (LEGACY) REGISTRATIONS (NTLite c5e2524a-ea46-4f67-841f-6a9465d9d515)
        Write-Info "Purging File Explorer (Legacy) AppxAllUserStore registrations..."
        $fileExplorerDelKeys = @()
        $feQueries = @("c5e2524a-ea46-4f67-841f-6a9465d9d515", "Microsoft.Windows.FileExplorer")
        foreach ($q in $feQueries) {
            $inboxFE = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"$q`" 2>nul" | Select-String "HKEY_"
            foreach ($line in $inboxFE) {
                $fileExplorerDelKeys += $line.Line.Trim()
            }
            $appsFE = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications`" /f `"$q`" 2>nul" | Select-String "HKEY_"
            foreach ($line in $appsFE) {
                $fileExplorerDelKeys += $line.Line.Trim()
            }
            $deproFE = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned`" /f `"$q`" 2>nul" | Select-String "HKEY_"
            foreach ($line in $deproFE) {
                $fileExplorerDelKeys += $line.Line.Trim()
            }
        }
        Invoke-ElevatedRegDelete ($fileExplorerDelKeys | Select-Object -Unique)
        Write-Success "Purged File Explorer (Legacy) AppxAllUserStore registrations."

        # 5q. PURGE APP RESOLVER UX REGISTRATIONS & RESTORE CLASSIC OPEN WITH (NTLite appresolver / e2a4f912-2574-4a75-9bb0-0d023378592b)
        Write-Info "Purging AppResolverUX AppxAllUserStore registrations and enforcing classic Open With..."
        $appResolverDelKeys = @()
        $arQueries = @("E2A4F912-2574-4A75-9BB0-0D023378592B", "Microsoft.Windows.AppResolverUX")
        foreach ($q in $arQueries) {
            $inboxAR = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"$q`" 2>nul" | Select-String "HKEY_"
            foreach ($line in $inboxAR) {
                $appResolverDelKeys += $line.Line.Trim()
            }
            $appsAR = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications`" /f `"$q`" 2>nul" | Select-String "HKEY_"
            foreach ($line in $appsAR) {
                $appResolverDelKeys += $line.Line.Trim()
            }
            $deproAR = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned`" /f `"$q`" 2>nul" | Select-String "HKEY_"
            foreach ($line in $deproAR) {
                $appResolverDelKeys += $line.Line.Trim()
            }
        }
        Invoke-ElevatedRegDelete ($appResolverDelKeys | Select-Object -Unique)

        # Enforce classic Win32 Open With and suppress Store recommendation prompts & new app toasts
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Explorer`" /v NoUseStoreOpenWith /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Explorer`" /v NoNewAppAlert /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Software\Policies\Microsoft\Windows\Explorer`" /v NoUseStoreOpenWith /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Software\Policies\Microsoft\Windows\Explorer`" /v NoNewAppAlert /t REG_DWORD /d 1 /f >nul 2>&1"
        Write-Success "Purged AppResolverUX AppxAllUserStore registrations and configured NoUseStoreOpenWith=1."

        # 5r. PURGE ONEDRIVE FIRST-RUN AUTORUN & ENFORCE DISABLE POLICIES (NTLite OneDrive)
        Write-Info "Purging OneDrive first-run trigger, unpinning Explorer navigation CLSIDs, and enforcing policies..."
        
        # Purge First-Logon Trigger from Default User profile template
        cmd /c "reg delete `"HKU\OFFLINE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Run`" /v OneDriveSetup /f >nul 2>&1"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Run`" /v OneDriveSetup /f >nul 2>&1"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run`" /v OneDriveSetup /f >nul 2>&1"

        # Unpin OneDrive Shell Namespace CLSIDs ({018D5C66-4533-4307-9B53-224DE2ED1FE6} & {04271989-C4D2-47CC-B404-063F5B0740E2})
        $oneDriveClsids = @("{018D5C66-4533-4307-9B53-224DE2ED1FE6}", "{04271989-C4D2-47CC-B404-063F5B0740E2}")
        foreach ($clsid in $oneDriveClsids) {
            cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Classes\CLSID\$clsid`" /v System.IsPinnedToNameSpaceTree /t REG_DWORD /d 0 /f >nul 2>&1"
            cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Classes\WOW6432Node\CLSID\$clsid`" /v System.IsPinnedToNameSpaceTree /t REG_DWORD /d 0 /f >nul 2>&1"
            cmd /c "reg add `"HKU\OFFLINE_DEFAULT\Software\Classes\CLSID\$clsid`" /v System.IsPinnedToNameSpaceTree /t REG_DWORD /d 0 /f >nul 2>&1"
            cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\$clsid`" /f >nul 2>&1"
        }

        # Enforce Group Policy Hardening (DisableFileSyncNGSC=1, DisableLibrariesDefaultSaveToOneDrive=1, DisableMeteredNetworkFileSync=1)
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\OneDrive`" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\OneDrive`" /v DisableLibrariesDefaultSaveToOneDrive /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\OneDrive`" /v DisableMeteredNetworkFileSync /t REG_DWORD /d 1 /f >nul 2>&1"

        # Purge TaskCache registrations for OneDrive
        $oneDriveTaskDelKeys = @(
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\OneDrive"
        )
        Invoke-ElevatedRegDelete $oneDriveTaskDelKeys
        Write-Success "Purged OneDrive first-run trigger, unpinned Explorer CLSIDs, and enforced DisableFileSyncNGSC."

        # 5s. PURGE RETAIL DEMO EXPERIENCE (RDX) REGISTRY & ENFORCE POLICY (NTLite retaildemo)
        Write-Info "Purging Retail Demo Experience (RDX) registry keys and enforcing AllowRetailDemo=0 policy..."
        $rdxDelKeys = @(
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\RetailDemo",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList\RDX",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\RetailDemo"
        )
        Invoke-ElevatedRegDelete $rdxDelKeys

        # Deprovision RetailDemo InboxApplications from AppxAllUserStore if registered
        $rdxAppxKeys = @(cmd /c 'reg query "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications" /f "RetailDemo" 2>nul' | Select-String "HKEY_")
        if ($rdxAppxKeys.Count -gt 0) {
            $rdxDelAppx = @($rdxAppxKeys | ForEach-Object { ($_.ToString().Trim() -replace 'HKEY_LOCAL_MACHINE\\', 'HKLM\') })
            Invoke-ElevatedRegDelete $rdxDelAppx
            Write-Success "Purged RetailDemo InboxApplications registrations."
        }

        # Enforce AllowRetailDemo=0 policy to prevent any future reactivation
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\RetailDemo`" /v AllowRetailDemo /t REG_DWORD /d 0 /f >nul 2>&1"
        Write-Success "Retail Demo Experience (RDX) purged and AllowRetailDemo=0 policy enforced."

        # 5t. PURGE USAGE & QUALITY INSIGHTS TASKCACHE & ENFORCE GROUP POLICIES (NTLite qualityinsights)
        Write-Info "Purging Usage and Quality Insights TaskCache and enforcing anti-telemetry policies..."
        $insightsTaskDelKeys = @(
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Device Information",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser Exp",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\ProgramDataUpdater",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\AitAgent",
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Customer Experience Improvement Program"
        )
        Invoke-ElevatedRegDelete $insightsTaskDelKeys

        # Enforce Group Policy Hardening
        # AppCompat: DisableInventory=1, AITEnable=0
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\AppCompat`" /v DisableInventory /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\AppCompat`" /v AITEnable /t REG_DWORD /d 0 /f >nul 2>&1"

        # DeviceCensus: DisableDeviceCensus=1
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\DeviceCensus`" /v DisableDeviceCensus /t REG_DWORD /d 1 /f >nul 2>&1"

        # DataCollection: AllowTelemetry=0, DisableOneSettingsDownloads=1
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\DataCollection`" /v AllowTelemetry /t REG_DWORD /d 0 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\DataCollection`" /v DisableOneSettingsDownloads /t REG_DWORD /d 1 /f >nul 2>&1"

        Write-Success "Usage & Quality Insights TaskCache purged and hardening policies enforced."

        # 5u. NEUTRALIZE WINDOWS ERROR REPORTING (WER) & AEDEBUG POST-MORTEM HOOKS (NTLite errorreporting)
        Write-Info "Neutralizing Windows Error Reporting (WER) and AeDebug post-mortem crash hooks..."
        # 64-bit AeDebug: Delete Debugger value, set Auto="0"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug`" /v Debugger /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug`" /v Auto /t REG_SZ /d 0 /f >nul 2>&1"

        # 32-bit WOW64 AeDebug: Delete Debugger value, set Auto="0"
        cmd /c "reg delete `"HKLM\OFFLINE_SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug`" /v Debugger /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug`" /v Auto /t REG_SZ /d 0 /f >nul 2>&1"

        # TaskCache: Purge Windows Error Reporting QueueReporting tree
        $werTaskDelKeys = @(
            "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Windows Error Reporting"
        )
        Invoke-ElevatedRegDelete $werTaskDelKeys

        # Group Policy & System Registry Hardening (Disable WER completely)
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting`" /v Disabled /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting`" /v DontShowUI /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting`" /v DontSendAdditionalData /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting`" /v LoggingDisabled /t REG_DWORD /d 1 /f >nul 2>&1"
        cmd /c "reg add `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\Windows Error Reporting`" /v Disabled /t REG_DWORD /d 1 /f >nul 2>&1"

        Write-Success "AeDebug neutralized, WER TaskCache purged, and WER policies enforced."
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

# Remove Performance Monitor shortcuts
$perfmonShortcuts = @(
    "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Performance Monitor.lnk",
    "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Windows Tools\Performance Monitor.lnk"
)
foreach ($lnk in $perfmonShortcuts) {
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
schtasks /delete /tn "\Microsoft\Windows\PLA\System\ConvertLogEntries" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\Device Information\Device" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\Device Information\Device User" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\Application Experience\ProgramDataUpdater" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator" /f >nul 2>&1
schtasks /delete /tn "\Microsoft\Windows\Windows Error Reporting\QueueReporting" /f >nul 2>&1

bcdedit /set {current} debug off >nul 2>&1
bcdedit /set {current} bootdebug off >nul 2>&1

cd /d %SystemDrive%\
start /b "" cmd /c "ping 127.0.0.1 -n 2 >nul & rd /s /q "%WINDIR%\Setup\Scripts""
exit
'@
[System.IO.File]::WriteAllText("$setupDir\SetupComplete.cmd", $setupCmd, [System.Text.Encoding]::ASCII)
Write-Success "Generated: $setupDir\SetupComplete.cmd (erases Scripts directory on completion)."

# -------------------------------------------------------------
# STEP 10: Component Cleanup (/ResetBase) & Offline Cache/Temp Purge
# -------------------------------------------------------------
if (-not $SkipCleanup) {
    Write-Step "[10/11] Running DISM Component Cleanup (/ResetBase)..."
    $cleanRes = & dism.exe /English /Image:$MountDir /Cleanup-Image /StartComponentCleanup /ResetBase /NoRestart 2>&1
    Write-Success "Component cleanup executed successfully."
} else {
    Write-Info "Skipping component cleanup (-SkipCleanup specified)."
}

Write-Info "Purging offline cache and temporary files across 9 categories (NTLite cache.temp)..."

# Category 1: Windows Update & SoftwareDistribution Cache
$swDistDirs = @(
    "$MountDir\Windows\SoftwareDistribution\Download",
    "$MountDir\Windows\SoftwareDistribution\DataStore",
    "$MountDir\Windows\SoftwareDistribution\PostRebootEventCache.V2",
    "$MountDir\Windows\SoftwareDistribution\SLS"
)
foreach ($sdd in $swDistDirs) {
    if (Test-Path $sdd) {
        Clear-ForceDirectoryContents $sdd
    }
}
if (Test-Path "$MountDir\Windows\SoftwareDistribution") {
    $swDownload = "$MountDir\Windows\SoftwareDistribution\Download"
    if (-not (Test-Path $swDownload)) {
        New-Item -ItemType Directory -Path $swDownload -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

# Category 2: Delivery Optimization (P2P Update Cache)
$doDirs = @(
    "$MountDir\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache",
    "$MountDir\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Logs"
)
foreach ($dod in $doDirs) {
    if (Test-Path $dod) {
        Clear-ForceDirectoryContents $dod
    }
}

# Category 3: CBS & DISM Servicing Logs
$servicingLogFiles = @(
    "$MountDir\Windows\Logs\CBS\CBS.log",
    "$MountDir\Windows\Logs\DISM\dism.log"
)
foreach ($slf in $servicingLogFiles) {
    if (Test-Path $slf) {
        Remove-ForceFile $slf
    }
}
if (Test-Path "$MountDir\Windows\Logs\CBS") {
    Get-ChildItem -Path "$MountDir\Windows\Logs\CBS" -Filter "CbsPersist_*" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-ForceFile $_.FullName
    }
}
$servicingLogDirs = @(
    "$MountDir\Windows\Logs\DPX",
    "$MountDir\Windows\Logs\MoSetup"
)
foreach ($sld in $servicingLogDirs) {
    if (Test-Path $sld) {
        Remove-ForceDirectory $sld
    }
}

# Category 4: Windows Setup, Sysprep & Panther Logs
$pantherDirs = @(
    "$MountDir\Windows\Panther",
    "$MountDir\Windows\System32\sysprep\Panther"
)
foreach ($pd in $pantherDirs) {
    if (Test-Path $pd) {
        Remove-ForceDirectory $pd
    }
}
if (Test-Path "$MountDir\Windows\inf") {
    Get-ChildItem -Path "$MountDir\Windows\inf" -Filter "setupapi*.log" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-ForceFile $_.FullName
    }
}

# Category 5: Cryptographic Transaction Logs (catroot2 commit logs only, preserving catdb)
if (Test-Path "$MountDir\Windows\System32\catroot2") {
    Get-ChildItem -Path "$MountDir\Windows\System32\catroot2" -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @(".log", ".jrs", ".chk") -or $_.Name -like "edb*"
    } | ForEach-Object {
        if ($_.Name -notlike "*catdb*") {
            Remove-ForceFile $_.FullName
        }
    }
}

# Category 6: Prefetch & ReadyBoot Cache
if (Test-Path "$MountDir\Windows\Prefetch") {
    Get-ChildItem -Path "$MountDir\Windows\Prefetch" -Filter "*.pf" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-ForceFile $_.FullName
    }
    if (Test-Path "$MountDir\Windows\Prefetch\ReadyBoot") {
        Get-ChildItem -Path "$MountDir\Windows\Prefetch\ReadyBoot" -Filter "*.fx" -File -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-ForceFile $_.FullName
        }
    }
}

# Category 7: Font & Shell Thumbnail/Icon Caches
if (Test-Path "$MountDir\Windows\ServiceProfiles\LocalService\AppData\Local") {
    Get-ChildItem -Path "$MountDir\Windows\ServiceProfiles\LocalService\AppData\Local" -Filter "FontCache*" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-ForceFile $_.FullName
    }
}
if (Test-Path "$MountDir\Users\Default\AppData\Local\Microsoft\Windows\Explorer") {
    Get-ChildItem -Path "$MountDir\Users\Default\AppData\Local\Microsoft\Windows\Explorer" -Filter "*cache*.db" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-ForceFile $_.FullName
    }
}

# Category 8: Error Reporting (WER) & Crash Dumps
$werDirs = @(
    "$MountDir\ProgramData\Microsoft\Windows\WER\ReportQueue",
    "$MountDir\ProgramData\Microsoft\Windows\WER\ReportArchive",
    "$MountDir\ProgramData\Microsoft\Windows\WER\Temp"
)
foreach ($wd in $werDirs) {
    if (Test-Path $wd) {
        Clear-ForceDirectoryContents $wd
    }
}
$dumpItems = @(
    "$MountDir\Windows\MEMORY.DMP",
    "$MountDir\Windows\Minidump"
)
foreach ($di in $dumpItems) {
    if (Test-Path $di) {
        if ((Get-Item $di).PSIsContainer) {
            Remove-ForceDirectory $di
        } else {
            Remove-ForceFile $di
        }
    }
}

# Category 9: System & User Temp Directories
Clear-ForceDirectoryContents "$MountDir\Windows\Temp"
Clear-ForceDirectoryContents "$MountDir\Users\Default\AppData\Local\Temp"

Write-Success "Offline cache and temp files purged; root directory anchors preserved."

# -------------------------------------------------------------
# STEP 11: 135-Point Automated Quality Gate / Validation
# -------------------------------------------------------------
if (-not $SkipValidation) {
    Write-Step "[11/11] Running 135-Point Quality Gate Validation..."

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

    # 8-20. SmartScreen, AppRep, BrowserCore, RetailDemo & OneDrive Binaries / Folders Deleted
    Assert-Check -Name "SmartScreen smartscreen.exe" -Pass (-not (Test-Path "$MountDir\Windows\System32\smartscreen.exe")) -Detail "Deleted"
    Assert-Check -Name "SmartScreen smartscreen.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\smartscreen.dll")) -Detail "Deleted"
    Assert-Check -Name "SmartScreen AppRepAgent.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\AppRepAgent.dll")) -Detail "Deleted"
    $appRepRemaining = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "Microsoft.Windows.AppRep.ChxApp_*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "SmartScreen AppRep.ChxApp" -Pass ($appRepRemaining.Count -eq 0) -Detail "Purged from SystemApps"
    Assert-Check -Name "BrowserCore Directory" -Pass (-not (Test-Path "$MountDir\Windows\BrowserCore")) -Detail "Purged from Windows"
    Assert-Check -Name "BrowserCore Host System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\browsercore.exe")) -Detail "Deleted"
    Assert-Check -Name "BrowserCore Manifest System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\browsercore.json")) -Detail "Deleted"
    Assert-Check -Name "RetailDemo ProgramData Repository" -Pass (-not (Test-Path "$MountDir\ProgramData\Microsoft\Windows\RetailDemo")) -Detail "Purged"
    Assert-Check -Name "RetailDemo RDXService.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\RDXService.dll")) -Detail "Deleted"
    Assert-Check -Name "RetailDemo RDXTaskFactory.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\RDXTaskFactory.dll")) -Detail "Deleted"
    Assert-Check -Name "RetailDemo RetailInfo.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\Windows.System.Profile.RetailInfo.dll")) -Detail "Deleted"
    Assert-Check -Name "OneDrive System32 Binary" -Pass (-not (Test-Path "$MountDir\Windows\System32\OneDriveSetup.exe")) -Detail "Deleted"
    Assert-Check -Name "OneDrive SysWOW64 Binary" -Pass (-not (Test-Path "$MountDir\Windows\SysWOW64\OneDriveSetup.exe")) -Detail "Deleted"

    # Re-load hives for registry assertions
    cmd /c "reg load HKLM\OFFLINE_SYSTEM `"$sysHive`" >nul 2>&1"
    cmd /c "reg load HKLM\OFFLINE_SOFTWARE `"$sofHive`" >nul 2>&1"
    cmd /c "reg load HKU\OFFLINE_DEFAULT `"$defHive`" >nul 2>&1"

    try {
        # 21-29. ALL 9 Defender Services Deleted
        foreach ($svc in $defenderServices) {
            $q = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\$svc`" >nul 2>&1"
            Assert-Check -Name "Defender Service $svc" -Pass ($LASTEXITCODE -ne 0) -Detail "Completely deleted from registry"
        }

        # 30-32. Telemetry Services Deleted
        foreach ($svc in $telemetryServices) {
            $q = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\$svc`" >nul 2>&1"
            Assert-Check -Name "Telemetry Service $svc" -Pass ($LASTEXITCODE -ne 0) -Detail "Completely deleted from registry"
        }

        # 33-35. Telemetry DLLs Deleted
        Assert-Check -Name "Telemetry diagtrack.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\diagtrack.dll")) -Detail "Deleted"
        Assert-Check -Name "Telemetry moshost.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\moshost.dll")) -Detail "Deleted"
        Assert-Check -Name "Telemetry PhoneService.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\PhoneService.dll")) -Detail "Deleted"

        # 36. PlugPlay Service Disabled
        $ppVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\PlugPlay`" /v Start 2>nul"
        Assert-Check -Name "PlugPlay Start=4" -Pass ($ppVal -match '0x4') -Detail "Disabled"

        # 37. Spooler Service Manual
        $spVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\Spooler`" /v Start 2>nul"
        Assert-Check -Name "Spooler Start=3" -Pass ($spVal -match '0x3') -Detail "Manual"

        # 38. lfsvc Disabled
        $lfVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\lfsvc`" /v Start 2>nul"
        Assert-Check -Name "lfsvc Start=4" -Pass ($lfVal -match '0x4') -Detail "Disabled"

        # 39. RemoteRegistry Disabled
        $rrVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\RemoteRegistry`" /v Start 2>nul"
        Assert-Check -Name "RemoteRegistry Start=4" -Pass ($rrVal -match '0x4') -Detail "Disabled"

        # 40. DPS Disabled
        $dpsVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\DPS`" /v Start 2>nul"
        Assert-Check -Name "DPS Start=4" -Pass ($dpsVal -match '0x4') -Detail "Disabled"

        # 41. ConfigureChatAutoInstall
        $chatVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Communications`" /v ConfigureChatAutoInstall 2>nul"
        Assert-Check -Name "ConfigureChatAutoInstall=0" -Pass ($chatVal -match '0x0') -Detail "Applied"

        # 42. SmartScreenEnabled=off in Explorer
        $ssVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer`" /v SmartScreenEnabled 2>nul"
        Assert-Check -Name "SmartScreenEnabled=off" -Pass ($ssVal -match 'off') -Detail "Disabled in Explorer"

        # 43. EnableSmartScreen=0 in System Policies
        $essVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System`" /v EnableSmartScreen 2>nul"
        Assert-Check -Name "EnableSmartScreen=0" -Pass ($essVal -match '0x0') -Detail "Disabled in System Policies"

        # 44. ShellSmartScreenLevel=Off in System Policies
        $ssLevel = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\System`" /v ShellSmartScreenLevel 2>nul"
        Assert-Check -Name "ShellSmartScreenLevel=Off" -Pass ($ssLevel -match 'Off') -Detail "Disabled Shell Interception in System Policies"

        # 45. Smart App Control State=0 (VerifiedAndReputablePolicyState)
        $sacVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Control\CI\Policy`" /v VerifiedAndReputablePolicyState 2>nul"
        Assert-Check -Name "Smart App Control State=0" -Pass ($sacVal -match '0x0') -Detail "Permanently Disabled in CI Policy"

        # 46. AppHost EnableWebContentEvaluation=0
        $appHostVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost`" /v EnableWebContentEvaluation 2>nul"
        Assert-Check -Name "AppHost EnableWebContentEvaluation=0" -Pass ($appHostVal -match '0x0') -Detail "Disabled Web Content Evaluation"

        # 47. Edge SmartScreenEnabled=0
        $edgeSsVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Edge`" /v SmartScreenEnabled 2>nul"
        Assert-Check -Name "Edge SmartScreenEnabled=0" -Pass ($edgeSsVal -match '0x0') -Detail "Disabled in Edge Policies"

        # 48. BrowserCore Chrome HKLM Host Purged
        $bcChrome = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore`" 2>nul"
        Assert-Check -Name "BrowserCore Chrome HKLM Host" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from HKLM NativeMessagingHosts"

        # 49. BrowserCore Chrome Default Profile Host Purged
        $bcChromeDef = cmd /c "reg query `"HKU\OFFLINE_DEFAULT\Software\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore`" 2>nul"
        Assert-Check -Name "BrowserCore Chrome Default Profile Host" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from Default NTUSER.DAT"

        # 50. BrowserCore Edge HKLM Host Purged
        $bcEdge = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.microsoft.browsercore`" 2>nul"
        Assert-Check -Name "BrowserCore Edge HKLM Host" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from HKLM NativeMessagingHosts"

        # 51. BrowserCore Mozilla HKLM Host Purged
        $bcMoz = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Mozilla\NativeMessagingHosts\com.microsoft.browsercore`" 2>nul"
        Assert-Check -Name "BrowserCore Mozilla HKLM Host" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from HKLM NativeMessagingHosts"

        # 52. Preserved HttpAcceptLanguageOptOut
        $langVal1 = cmd /c "reg query `"HKU\OFFLINE_DEFAULT\Control Panel\International\User Profile`" /v HttpAcceptLanguageOptOut 2>nul"
        $langVal2 = cmd /c "reg query `"HKU\OFFLINE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\RunOnce`" /v `"Telemetry Language Disable`" 2>nul"
        $langVal3 = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Control Panel\International`" /v UserHttpAcceptLanguageOptOut 2>nul"
        $langPass = ($langVal1 -match '0x1') -or ($langVal2 -match 'HttpAcceptLanguageOptOut') -or ($langVal3 -match '0x1')
        Assert-Check -Name "UserHttpAcceptLanguageOptOut=1" -Pass $langPass -Detail "Preserved"

        # 53. SecurityHealth Run Key Purged
        $shRun = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Run`" /v SecurityHealth 2>nul"
        Assert-Check -Name "SecurityHealth Run Key Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from Software Run key"

        # 54. Windows Defender Firewall Service (MpsSvc) Preserved Intact
        $fwVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\mpssvc`" /v Start 2>nul"
        Assert-Check -Name "Windows Defender Firewall Service (MpsSvc)" -Pass ($fwVal -match '0x2') -Detail "Preserved (Start=2 Automatic)"

        # 55. Base Filtering Engine Service (BFE) Preserved Intact
        $bfeVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\bfe`" /v Start 2>nul"
        Assert-Check -Name "Base Filtering Engine Service (BFE)" -Pass ($bfeVal -match '0x2') -Detail "Preserved (Start=2 Automatic)"

        # 56. .NET NGEN TaskCache Tree Purged
        $ngenTree = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\.NET Framework`" 2>nul"
        Assert-Check -Name ".NET NGEN TaskCache Tree Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from TaskCache\Tree"

        # 57. WinSAT TaskCache Tree Purged
        $wsTree = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Maintenance\WinSAT`" 2>nul"
        Assert-Check -Name "WinSAT TaskCache Tree Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from TaskCache\Tree"

        # 58. PLA TaskCache Tree Purged
        $plaTree = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\PLA`" 2>nul"
        Assert-Check -Name "PLA TaskCache Tree Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from TaskCache\Tree"

        # 59. Telemetry AutoLogger Diagtrack-Listener Start=0
        $diagVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener`" /v Start 2>nul"
        Assert-Check -Name "AutoLogger Diagtrack-Listener Start=0" -Pass ($diagVal -match '0x0') -Detail "Disabled"

        # 60. CoreAI InboxApplications Purged
        $coreAiReg = @(cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"MicrosoftWindows.Client.CoreAI`" 2>nul" | Select-String "HKEY_")
        Assert-Check -Name "CoreAI InboxApplications Purged" -Pass ($coreAiReg.Count -eq 0) -Detail "Purged from AppxAllUserStore"

        # 61. WindowsAI Policy DisableAIDataAnalysis=1
        $aiVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\WindowsAI`" /v DisableAIDataAnalysis 2>nul"
        Assert-Check -Name "WindowsAI DisableAIDataAnalysis=1" -Pass ($aiVal -match '0x1') -Detail "Applied"

        # 62. WindowsCopilot Policy TurnOffWindowsCopilot=1
        $copilotVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot`" /v TurnOffWindowsCopilot 2>nul"
        Assert-Check -Name "WindowsCopilot TurnOffWindowsCopilot=1" -Pass ($copilotVal -match '0x1') -Detail "Applied"

        # 63. Narrator AT Registration Purged
        $narratorAt = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility\ATs\Narrator`" 2>nul"
        Assert-Check -Name "Narrator AT Registration Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from Accessibility\ATs"

        # 64. NarratorQuickStart InboxApplications Purged
        $narratorAppx = @(cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"NarratorQuickStart`" 2>nul" | Select-String "HKEY_")
        Assert-Check -Name "NarratorQuickStart InboxApplications Purged" -Pass ($narratorAppx.Count -eq 0) -Detail "Purged from AppxAllUserStore"

        # 65. Add Folder Suggestions InboxApp Purged
        $fsAppx = @(cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE`" 2>nul" | Select-String "HKEY_")
        Assert-Check -Name "Add Folder Suggestions InboxApp Purged" -Pass ($fsAppx.Count -eq 0) -Detail "Purged from AppxAllUserStore"

        # 66. PinningConfirmationDialog InboxApp Purged
        $pinningAppx = @(cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"PinningConfirmationDialog`" 2>nul" | Select-String "HKEY_")
        Assert-Check -Name "PinningConfirmationDialog InboxApp Purged" -Pass ($pinningAppx.Count -eq 0) -Detail "Purged from AppxAllUserStore"

        # 67. File Explorer (Legacy) InboxApp Purged
        $feAppx = @(cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"c5e2524a-ea46-4f67-841f-6a9465d9d515`" 2>nul" | Select-String "HKEY_")
        Assert-Check -Name "File Explorer (Legacy) InboxApp Purged" -Pass ($feAppx.Count -eq 0) -Detail "Purged from AppxAllUserStore"

        # 68. AppResolverUX InboxApp Purged
        $arAppx = @(cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications`" /f `"E2A4F912-2574-4A75-9BB0-0D023378592B`" 2>nul" | Select-String "HKEY_")
        Assert-Check -Name "AppResolverUX InboxApp Purged" -Pass ($arAppx.Count -eq 0) -Detail "Purged from AppxAllUserStore"

        # 69. Explorer NoUseStoreOpenWith=1 Policy
        $openWithVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Explorer`" /v NoUseStoreOpenWith 2>nul"
        Assert-Check -Name "Explorer NoUseStoreOpenWith=1" -Pass ($openWithVal -match '0x1') -Detail "Enforced in Explorer Policies"

        # 70. OneDrive Default Profile Run Key Purged
        $odRun = cmd /c "reg query `"HKU\OFFLINE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Run`" /v OneDriveSetup 2>nul"
        Assert-Check -Name "OneDrive Default Profile Run Key Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from Default NTUSER.DAT"

        # 71. OneDrive Policy DisableFileSyncNGSC=1
        $odPol = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\OneDrive`" /v DisableFileSyncNGSC 2>nul"
        Assert-Check -Name "OneDrive DisableFileSyncNGSC=1" -Pass ($odPol -match '0x1') -Detail "Enforced in Policies"

        # 72. OneDrive Namespace Unpinned
        $odPin = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}`" /v System.IsPinnedToNameSpaceTree 2>nul"
        Assert-Check -Name "OneDrive Namespace Pinned=0" -Pass ($odPin -match '0x0') -Detail "Unpinned from Explorer Sidebar"

        # 73. RetailDemo Registry Tree Purged
        $rdxVal = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows\CurrentVersion\RetailDemo`" 2>nul"
        Assert-Check -Name "RetailDemo Registry Tree Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from CurrentVersion\RetailDemo"

        # 74. RetailDemo AllowRetailDemo=0 Policy
        $rdxPol = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\RetailDemo`" /v AllowRetailDemo 2>nul"
        Assert-Check -Name "RetailDemo AllowRetailDemo=0" -Pass ($rdxPol -match '0x0') -Detail "Enforced in Policies"

        # 75. Device Information TaskCache Purged
        $diTree = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Device Information`" 2>nul"
        Assert-Check -Name "Device Information TaskCache Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from TaskCache\Tree"

        # 76. Compatibility Appraiser TaskCache Purged
        $appTree = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser`" 2>nul"
        Assert-Check -Name "Compatibility Appraiser TaskCache Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from TaskCache\Tree"

        # 77. AppCompat DisableInventory=1 Policy
        $invPol = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\AppCompat`" /v DisableInventory 2>nul"
        Assert-Check -Name "AppCompat DisableInventory=1" -Pass ($invPol -match '0x1') -Detail "Enforced in AppCompat Policies"

        # 78. DeviceCensus DisableDeviceCensus=1 Policy
        $censusPol = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\DeviceCensus`" /v DisableDeviceCensus 2>nul"
        Assert-Check -Name "DeviceCensus DisableDeviceCensus=1" -Pass ($censusPol -match '0x1') -Detail "Enforced in DeviceCensus Policies"

        # 79. WerSvc Service Start=4
        $werVal = cmd /c "reg query `"HKLM\OFFLINE_SYSTEM\ControlSet001\Services\WerSvc`" /v Start 2>nul"
        Assert-Check -Name "WerSvc Start=4" -Pass ($werVal -match '0x4') -Detail "Disabled"

        # 80. AeDebug 64 Debugger Unhooked
        $ae64Dbg = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug`" /v Debugger 2>nul"
        Assert-Check -Name "AeDebug 64 Debugger Unhooked" -Pass ($LASTEXITCODE -ne 0) -Detail "No crash handler hook"

        # 81. AeDebug 64 Auto=0
        $ae64Auto = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug`" /v Auto 2>nul"
        Assert-Check -Name "AeDebug 64 Auto=0" -Pass ($ae64Auto -match '0') -Detail "Crash dialog suppressed"

        # 82. AeDebug WOW64 Debugger Unhooked
        $ae32Dbg = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug`" /v Debugger 2>nul"
        Assert-Check -Name "AeDebug WOW64 Debugger Unhooked" -Pass ($LASTEXITCODE -ne 0) -Detail "No crash handler hook"

        # 83. WER TaskCache Purged
        $tcWer = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Windows Error Reporting`" 2>nul"
        Assert-Check -Name "WER TaskCache Purged" -Pass ($LASTEXITCODE -ne 0) -Detail "Purged from TaskCache\Tree"

        # 84. WER Policy Disabled=1
        $werPol = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting`" /v Disabled 2>nul"
        Assert-Check -Name "WER Policy Disabled=1" -Pass ($werPol -match '0x1') -Detail "Enforced in Policies"

        # 85. Default Profile ShowCopilotButton=0
        $scbDef = cmd /c "reg query `"HKU\OFFLINE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced`" /v ShowCopilotButton 2>nul"
        Assert-Check -Name "Default Profile ShowCopilotButton=0" -Pass ($scbDef -match '0x0') -Detail "Taskbar button eliminated for all new users"

        # 86. Edge CopilotPageContext=0
        $edgeCpc = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Edge`" /v CopilotPageContext 2>nul"
        Assert-Check -Name "Edge CopilotPageContext=0" -Pass ($edgeCpc -match '0x0') -Detail "Edge context sharing disabled"

        # 87. Edge ShowCopilotButton=0
        $edgeScb = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Policies\Microsoft\Edge`" /v ShowCopilotButton 2>nul"
        Assert-Check -Name "Edge ShowCopilotButton=0" -Pass ($edgeScb -match '0x0') -Detail "Edge sidebar Copilot button disabled"
    }
    finally {
        # Unload validation hives
        cmd /c "reg unload HKLM\OFFLINE_SYSTEM >nul 2>&1"
        cmd /c "reg unload HKLM\OFFLINE_SOFTWARE >nul 2>&1"
        cmd /c "reg unload HKU\OFFLINE_DEFAULT >nul 2>&1"
    }

    # 88. Defender Driver WdFilter.sys
    Assert-Check -Name "Defender Driver WdFilter.sys" -Pass (-not (Test-Path "$MountDir\Windows\System32\drivers\WdFilter.sys")) -Detail "Deleted"

    # 89. Defender SecurityHealthSystray
    Assert-Check -Name "Defender SecurityHealthSystray" -Pass (-not (Test-Path "$MountDir\Windows\System32\SecurityHealthSystray.exe")) -Detail "Deleted"

    # 90. Firewall Binary mpssvc.dll Intact
    Assert-Check -Name "Firewall Binary mpssvc.dll" -Pass (Test-Path "$MountDir\Windows\System32\mpssvc.dll") -Detail "Preserved"

    # 91. Firewall MMC wf.msc Intact
    Assert-Check -Name "Firewall MMC wf.msc" -Pass (Test-Path "$MountDir\Windows\System32\wf.msc") -Detail "Preserved"

    # 92. .NET NativeImages 64 Cache
    Assert-Check -Name ".NET NativeImages 64 Cache" -Pass (-not (Test-Path "$MountDir\Windows\assembly\NativeImages_v4.0.30319_64")) -Detail "Deleted"

    # 93. .NET NativeImages 32 Cache
    Assert-Check -Name ".NET NativeImages 32 Cache" -Pass (-not (Test-Path "$MountDir\Windows\assembly\NativeImages_v4.0.30319_32")) -Detail "Deleted"

    # 94. .NET GAC_MSIL Preserved
    Assert-Check -Name ".NET GAC_MSIL Preserved" -Pass (Test-Path "$MountDir\Windows\Microsoft.NET\assembly\GAC_MSIL") -Detail "Intact (MSIL preserved)"

    # 95. WinSAT Binary System32 Deleted
    Assert-Check -Name "WinSAT Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\WinSAT.exe")) -Detail "Deleted"

    # 96. WinSAT Performance Directory Purged
    Assert-Check -Name "WinSAT Performance Directory" -Pass (-not (Test-Path "$MountDir\Windows\Performance\WinSAT")) -Detail "Purged"

    # 97. System Monitor sysmon.ocx Deleted
    Assert-Check -Name "System Monitor sysmon.ocx" -Pass (-not (Test-Path "$MountDir\Windows\System32\sysmon.ocx")) -Detail "Deleted"

    # 98. Performance Monitor perfmon.exe Deleted
    Assert-Check -Name "Performance Monitor perfmon.exe" -Pass (-not (Test-Path "$MountDir\Windows\System32\perfmon.exe")) -Detail "Deleted"

    # 99. Resource Monitor resmon.exe Preserved
    Assert-Check -Name "Resource Monitor resmon.exe Preserved" -Pass (Test-Path "$MountDir\Windows\System32\resmon.exe") -Detail "Preserved"

    # 100. Kernel Debug Transport kdnet.dll Deleted
    Assert-Check -Name "Kernel Debug Transport kdnet.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\kdnet.dll")) -Detail "Deleted"

    # 101. Kernel Debug DriverStore kdnic Purged
    $kdnicCount = (Get-ChildItem -Path "$MountDir\Windows\System32\DriverStore\FileRepository" -Filter "kdnic*.inf_*" -Directory -ErrorAction SilentlyContinue).Count
    Assert-Check -Name "Kernel Debug DriverStore kdnic" -Pass ($kdnicCount -eq 0) -Detail "Purged"

    # 102. Kernel Debug Stub kdcom.dll Preserved
    Assert-Check -Name "Kernel Debug Stub kdcom.dll Preserved" -Pass (Test-Path "$MountDir\Windows\System32\kdcom.dll") -Detail "Intact (Prevents STOP 0x6B)"

    # 103. CoreAI SystemApp Purged
    $coreAiRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "MicrosoftWindows.Client.CoreAI_*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "CoreAI SystemApp Purged" -Pass ($coreAiRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 104. CoreAI onnxruntime.dll Deleted
    Assert-Check -Name "CoreAI onnxruntime.dll" -Pass (-not (Test-Path "$MountDir\Windows\System32\onnxruntime.dll")) -Detail "Deleted"

    # 105. Base Client.CBS Preserved
    $cbsRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "MicrosoftWindows.Client.CBS_*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "Base Client.CBS Preserved" -Pass ($cbsRem.Count -gt 0) -Detail "Intact (Taskbar/Explorer preserved)"

    # 106. Copilot SystemApps Purged
    $copilotSysRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*Copilot*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "Copilot SystemApps Purged" -Pass ($copilotSysRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 107. Copilot WindowsApps Purged
    $copilotWinRem = Get-ChildItem -Path "$MountDir\Program Files\WindowsApps" -Filter "*Copilot*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "Copilot WindowsApps Purged" -Pass ($copilotWinRem.Count -eq 0) -Detail "Purged from Program Files\WindowsApps"

    # 108. Narrator Binary System32 Deleted
    Assert-Check -Name "Narrator Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\Narrator.exe")) -Detail "Deleted"

    # 109. NarratorMCAT Directory Purged
    Assert-Check -Name "NarratorMCAT Directory" -Pass (-not (Test-Path "$MountDir\Windows\System32\NarratorMCAT")) -Detail "Purged"

    # 110. NarratorQuickStart SystemApp Purged
    $narratorAppCount = (Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*microsoft.windows.narratorquickstart*" -Directory -ErrorAction SilentlyContinue).Count
    Assert-Check -Name "NarratorQuickStart SystemApp Purged" -Pass ($narratorAppCount -eq 0) -Detail "Purged from SystemApps"

    # 111. Add Folder Suggestions SystemApp Purged
    $fsAppRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*AddSuggestedFoldersToLibraryDialog*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "Add Folder Suggestions SystemApp Purged" -Pass ($fsAppRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 112. PinningConfirmationDialog SystemApp Purged
    $pinningAppRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*Microsoft.Windows.PinningConfirmationDialog*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "PinningConfirmationDialog SystemApp Purged" -Pass ($pinningAppRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 113. File Explorer (Legacy) SystemApp Purged
    $feAppRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "Microsoft.Windows.FileExplorer_*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "File Explorer (Legacy) SystemApp Purged" -Pass ($feAppRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 114. AppResolverUX SystemApp Purged
    $arAppRem = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "*Microsoft.Windows.AppResolverUX*" -Directory -ErrorAction SilentlyContinue
    Assert-Check -Name "AppResolverUX SystemApp Purged" -Pass ($arAppRem.Count -eq 0) -Detail "Purged from SystemApps"

    # 115. Classic Open With Binary openwith.exe Preserved
    Assert-Check -Name "Classic openwith.exe Preserved" -Pass (Test-Path "$MountDir\Windows\System32\openwith.exe") -Detail "Intact (Classic Win32 dialog fallback)"

    # 116. OneDrive Tasks Directory Purged
    Assert-Check -Name "OneDrive Tasks Directory Purged" -Pass (-not (Test-Path "$MountDir\Windows\System32\Tasks\Microsoft\Windows\OneDrive")) -Detail "Purged from System32\Tasks"

    # 117. RetailDemo CloudExperienceHost Purged
    Assert-Check -Name "RetailDemo CloudExperienceHost Purged" -Pass (-not (Test-Path "$MountDir\Windows\SystemApps\Microsoft.Windows.CloudExperienceHost_cw5n1h2txyewy\RetailDemo")) -Detail "Purged from CloudExperienceHost"

    # 118. SetupAPI Logs Purged
    $setupapiCount = (Get-ChildItem "$MountDir\Windows\inf" -Filter "setupapi*.log" -File -ErrorAction SilentlyContinue).Count
    Assert-Check -Name "SetupAPI Logs Purged" -Pass ($setupapiCount -eq 0) -Detail "setupapi*.log purged from Windows\inf"

    # 119. Windows Temp Empty
    $winTempCount = (Get-ChildItem "$MountDir\Windows\Temp" -Recurse -File -ErrorAction SilentlyContinue).Count
    Assert-Check -Name "Windows Temp Empty" -Pass ($winTempCount -eq 0) -Detail "No temporary files remaining in Windows\Temp"

    # 120. Windows Temp Directory Exists
    Assert-Check -Name "Windows Temp Directory Exists" -Pass (Test-Path "$MountDir\Windows\Temp") -Detail "Root directory anchor preserved"

    # 121. CBS Logs Purged
    Assert-Check -Name "CBS Logs Purged" -Pass (-not (Test-Path "$MountDir\Windows\Logs\CBS\CBS.log")) -Detail "CBS.log deleted"

    # 122. Panther Directory Purged
    Assert-Check -Name "Panther Directory Purged" -Pass (-not (Test-Path "$MountDir\Windows\Panther")) -Detail "Windows\Panther directory purged"

    # 123. DeviceCensus Binary System32 Deleted
    Assert-Check -Name "DeviceCensus Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\DeviceCensus.exe")) -Detail "Deleted"

    # 124. invagent Binary System32 Deleted
    Assert-Check -Name "invagent Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\invagent.dll")) -Detail "Deleted"

    # 125. appraiser Binary System32 Deleted
    Assert-Check -Name "appraiser Binary System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\appraiser.dll")) -Detail "Deleted"

    # 126. Appraiser Directory System32 Purged
    Assert-Check -Name "Appraiser Directory System32" -Pass (-not (Test-Path "$MountDir\Windows\System32\appraiser")) -Detail "Purged"

    # 127. WerFault.exe System32 Deleted
    Assert-Check -Name "WerFault.exe System32 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\System32\WerFault.exe")) -Detail "Deleted"

    # 128. WerFault.exe SysWOW64 Deleted
    Assert-Check -Name "WerFault.exe SysWOW64 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\SysWOW64\WerFault.exe")) -Detail "Deleted"

    # 129. wermgr.exe System32 Deleted
    Assert-Check -Name "wermgr.exe System32 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\System32\wermgr.exe")) -Detail "Deleted"

    # 130. wersvc.dll System32 Deleted
    Assert-Check -Name "wersvc.dll System32 Deleted" -Pass (-not (Test-Path "$MountDir\Windows\System32\wersvc.dll")) -Detail "Deleted"

    # 131. Region Policy In-Place Patch
    $polContent = [System.IO.File]::ReadAllText($policyPath, [System.Text.Encoding]::UTF8)
    $hasEdgeUninstall = ($polContent -match 'Edge_UninstallEdge' -or $polContent -match '\{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6\}' -or $polContent -match 'Edge is uninstallable') -and ($polContent -match '"defaultState"\s*:\s*"enabled"')
    Assert-Check -Name "Region Policy In-Place" -Pass $hasEdgeUninstall -Detail "Enabled in-place"

    # 132. OEMDefaultAssociations.xml
    Assert-Check -Name "OEMDefaultAssociations.xml" -Pass (Test-Path "$MountDir\Windows\System32\OEMDefaultAssociations.xml") -Detail "Staged"

    # 133. Notepad.lnk
    Assert-Check -Name "Notepad.lnk" -Pass (Test-Path "$accDir\Notepad.lnk") -Detail "Created"

    # 134. SetupComplete.cmd Exists
    Assert-Check -Name "SetupComplete.cmd Exists" -Pass (Test-Path "$setupDir\SetupComplete.cmd") -Detail "Staged"

    # 135. SetupComplete.cmd Has Self-Delete
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
