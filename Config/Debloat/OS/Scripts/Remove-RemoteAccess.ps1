<#
.SYNOPSIS
    Remove Remote Desktop Connection (Client) & Remote Registry Service
.DESCRIPTION
    Purges Remote Desktop Connection (mstsc), 32-bit client binaries, and Remote Registry service.
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

Write-Step "Removing Microsoft-RemoteDesktopConnection Feature and Shortcuts..."
Disable-OfflineFeature -MountDir $MountDir -FeatureName "Microsoft-RemoteDesktopConnection" -Remove
Write-Success "Feature Microsoft-RemoteDesktopConnection disabled with payload removed."

$rdcShortcut = "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories\Remote Desktop Connection.lnk"
if (Test-Path $rdcShortcut) {
    Remove-ForceFile $rdcShortcut
    Write-Success "Deleted shortcut: $(Split-Path $rdcShortcut -Leaf)"
}

Write-Step "Purging Remote Desktop Client - 32 bit (mstsc32)..."
$rdp32Binaries = @(
    "$MountDir\Windows\SysWOW64\mstsc.exe",
    "$MountDir\Windows\SysWOW64\mstscax.dll",
    "$MountDir\Windows\SysWOW64\aepic.dll",
    "$MountDir\Windows\SysWOW64\wbem\mstscax.mof"
)
foreach ($bin in $rdp32Binaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted 32-bit RDP binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path "$MountDir\Windows\SysWOW64" -Pattern @("mstsc*.mui", "aepic*.mui") -Recurse
Remove-ForceFilesByPattern -Path "$MountDir\Windows\SysWOW64\wbem" -Pattern "mstscax.mfl" -Recurse

Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\mstsc.exe"
$rdp32Clsids = @(
    "{7cacbd7b-0d99-468e-ac33-22e495c0afe5}",
    "{9a819714-9467-4caf-9d32-d8727d149022}",
    "{4eb5335f-8429-411a-8b84-5163fe1096e6}",
    "{73c76318-649f-4240-b8bc-21a4f0015569}",
    "{a4804d52-5a98-466d-a11f-f46328328c68}"
)
foreach ($cls in $rdp32Clsids) {
    Remove-RegKey "HKCR\CLSID\$cls"
    Remove-RegKey "HKCR\WOW6432Node\CLSID\$cls"
}
Write-Success "Purged 32-bit Remote Desktop Client binaries and CLSIDs."

Write-Step "Purging Remote Registry Service Binaries & Pipe Server..."
$remoteRegBin = "$MountDir\Windows\System32\regsvc.dll"
if (Test-Path $remoteRegBin) {
    Remove-ForceFile $remoteRegBin
    Write-Success "Deleted RemoteRegistry binary: $(Split-Path $remoteRegBin -Leaf)"
}

Remove-ForceFilesByPattern -Path "$MountDir\Windows\System32" -Pattern "regsvc*.mui" -Recurse

Remove-OfflineService "RemoteRegistry"
Remove-RegKey "HKLM\SYSTEM\CurrentControlSet\Control\SecurePipeServers\winreg"
Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\RemoteRegistry"

Write-Success "Purged RemoteRegistry binaries, service configuration, and pipe servers."
