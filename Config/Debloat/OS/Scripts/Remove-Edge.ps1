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
$edgeDevToolsBin = "$MountDir\Windows\System32\MicrosoftEdgeDevTools.exe"
if (Test-Path $edgeDevToolsBin) {
    Remove-ForceFile $edgeDevToolsBin
    Write-Success "Deleted DevTools binary: $(Split-Path $edgeDevToolsBin -Leaf)"
}

Remove-ForceFilesByPattern -Path "$MountDir\Windows\WinSxS" -Pattern "*crosoftedgedevtools*" -Recurse

Remove-RegKey "HKCR\microsoft-edge-devtools"

Write-Success "Purged Microsoft Edge DevTools Client registrations."

Write-Step "Purging Microsoft Edge Directories..."
$edgeDirs = @(
    "$MountDir\Program Files (x86)\Microsoft\Edge",
    "$MountDir\Program Files (x86)\Microsoft\EdgeUpdate",
    "$MountDir\Program Files (x86)\Microsoft\EdgeCore"
)
foreach ($dir in $edgeDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged Microsoft Edge directory: $(Split-Path $dir -Leaf)"
    }
}

Write-Step "Configuring IntegratedServicesRegionPolicySet.json (Worldwide Edge Uninstall)..."
Set-OfflineRegionPolicy -MountDir $MountDir -PolicyName "Edge_UninstallEdge" -State "enabled"
