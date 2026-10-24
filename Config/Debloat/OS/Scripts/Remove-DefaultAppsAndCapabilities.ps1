<#
.SYNOPSIS
    Remove Provisioned InboxApps, OneDrive, and Optional Features
.DESCRIPTION
    Purges pre-provisioned Windows Store apps, strips OneDrive setup and explorer pinning, and removes legacy Windows Capabilities (FOD).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MountDir,

    [Parameter(Mandatory = $false)]
    [string]$CustomRegPath = "",

    [Parameter(Mandatory = $false)]
    [string]$NSudoPath = "",

    [Parameter(Mandatory = $false)]
    [string[]]$EnabledApps = @()
)

$ErrorActionPreference = 'Stop'

Write-Step "Purging Pre-staged Apps (Windows\InboxApps)..."
$inboxApps = "$MountDir\Windows\InboxApps"
if (Test-Path $inboxApps) {
    Remove-ForceDirectory $inboxApps
    Write-Success "Windows\InboxApps purged."
} else {
    Write-Info "Windows\InboxApps already absent."
}

Write-Step "Filtering Provisioned Appx Packages (preserving EnabledApps & framework runtimes)..."
Filter-OfflineProvisionedAppxPackages -MountDir $MountDir -EnabledApps $EnabledApps

Write-Step "Purging OneDrive Setup Binaries and Decoupling Shell Namespace..."
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
    "$MountDir\Windows\System32\OneDrive.Setup"
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\OneDrive"
)
foreach ($dir in $oneDriveDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged OneDrive directory: $(Split-Path $dir -Leaf)"
    }
}

Remove-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" "OneDriveSetup"
Remove-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "OneDriveSetup"
Remove-RegValue "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" "OneDriveSetup"

$oneDriveClsids = @(
    "HKCR\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
    "HKCR\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
    "HKCR\CLSID\{04271989-C4D2-47CC-B404-063F5B0740E2}",
    "HKCR\WOW6432Node\CLSID\{04271989-C4D2-47CC-B404-063F5B0740E2}"
)
foreach ($cKey in $oneDriveClsids) {
    Set-RegValue $cKey "System.IsPinnedToNameSpaceTree" 0
}

$odPolKey = "HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
Set-RegValue $odPolKey "DisableFileSyncNGSC" 1
Set-RegValue $odPolKey "DisableLibrariesDefaultSaveToOneDrive" 1
Set-RegValue $odPolKey "DisableMeteredNetworkFileSync" 1

Remove-ScheduledTask "\Microsoft\Windows\OneDrive"
Write-Success "Purged OneDrive autorun, shell namespace CLSIDs, and enforced policies."

Write-Step "Removing Windows Capabilities (FOD) & Legacy Optional Features..."
if (Get-Command Invoke-WithoutOfflineHives -ErrorAction SilentlyContinue) {
    Invoke-WithoutOfflineHives -MountDir $MountDir -Action {
        $legacyFeatures = @("WindowsMediaPlayer", "TFTP", "WCF-TCP-PortSharing45", "MSMQ-Container")
        foreach ($feat in $legacyFeatures) {
            Disable-OfflineFeature -MountDir $MountDir -FeatureName $feat -Remove
        }

        $capPatterns = @(
            "Browser.InternetExplorer*",
            "Language.Handwriting*",
            "Language.Speech*",
            "Language.TextToSpeech*",
            "Language.OCR*",
            "MathRecognizer*",
            "App.StepsRecorder*",
            "OpenSSH.Client*",
            "Hello.Face*"
        )
        Remove-OfflineCapability -MountDir $MountDir -Pattern $capPatterns
    }
} else {
    $legacyFeatures = @("WindowsMediaPlayer", "TFTP", "WCF-TCP-PortSharing45", "MSMQ-Container")
    foreach ($feat in $legacyFeatures) {
        Disable-OfflineFeature -MountDir $MountDir -FeatureName $feat -Remove
    }

    $capPatterns = @(
        "Browser.InternetExplorer*",
        "Language.Handwriting*",
        "Language.Speech*",
        "Language.TextToSpeech*",
        "Language.OCR*",
        "MathRecognizer*",
        "App.StepsRecorder*",
        "OpenSSH.Client*",
        "Hello.Face*"
    )
    Remove-OfflineCapability -MountDir $MountDir -Pattern $capPatterns
}

$wmpDirs = @(
    "$MountDir\Program Files\Windows Media Player",
    "$MountDir\Program Files (x86)\Windows Media Player"
)
foreach ($dir in $wmpDirs) {
    if (Test-Path $dir) { Remove-ForceDirectory $dir }
}

Write-Success "Windows Capabilities and legacy features purged."
