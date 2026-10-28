<#
.SYNOPSIS
    Purge Microsoft Edge Components & Enable Worldwide Edge Uninstall
.DESCRIPTION
    Purges Microsoft Edge DevTools Client, Edge system directories and shortcuts, and patches
    IntegratedServicesRegionPolicySet.json offline to enable Microsoft Edge uninstallation worldwide.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MountDir,

    [Parameter(Mandatory = $false)]
    [string]$CustomRegPath = "",

    [Parameter(Mandatory = $false)]
    [string]$NSudoPath = ""
)

$ErrorActionPreference = 'Stop'

Write-Step "Purging Microsoft Edge DevTools Client..."
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*MicrosoftEdgeDevToolsClient*"
$edgeDevToolsBinaries = @(
    "$MountDir\Windows\System32\MicrosoftEdgeDevTools.exe"
)
foreach ($bin in $edgeDevToolsBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted DevTools binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path "$MountDir\Windows\WinSxS" -Pattern "*crosoftedgedevtools*" -Recurse

$inboxAppsKey = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications"
foreach ($k in (Get-RegSubKey $inboxAppsKey "MicrosoftEdgeDevToolsClient")) {
    Remove-RegKey $k
}

Remove-RegKey "HKCR\microsoft-edge-devtools"

Write-Success "Purged Microsoft Edge DevTools Client registrations."

Write-Step "Purging Microsoft Edge Directories and Shortcuts..."
$edgeDirs = @(
    "$MountDir\Program Files (x86)\Microsoft\Edge",
    "$MountDir\Program Files (x86)\Microsoft\EdgeUpdate",
    "$MountDir\Program Files (x86)\Microsoft\EdgeCore",
    "$MountDir\Program Files\Microsoft\Edge",
    "$MountDir\Program Files\Microsoft\EdgeUpdate",
    "$MountDir\Program Files\Microsoft\EdgeCore"
)
foreach ($dir in $edgeDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged Microsoft Edge directory: $(Split-Path $dir -Leaf)"
    }
}

$edgeShortcuts = @(
    "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
    "$MountDir\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
    "$MountDir\Users\Public\Desktop\Microsoft Edge.lnk"
)
foreach ($lnk in $edgeShortcuts) {
    if (Test-Path $lnk) {
        Remove-ForceFile $lnk
        Write-Success "Deleted Microsoft Edge shortcut: $(Split-Path $lnk -Leaf)"
    }
}

Write-Step "Configuring IntegratedServicesRegionPolicySet.json (Worldwide Edge Uninstall)..."
Set-OfflineRegionPolicy -MountDir $MountDir -PolicyName "Edge_UninstallEdge" -State "enabled"
