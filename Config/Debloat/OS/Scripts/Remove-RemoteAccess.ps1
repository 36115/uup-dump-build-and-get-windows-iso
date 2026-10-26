<#
.SYNOPSIS
    Remove Remote Desktop (64/32-bit) and Remote Registry Services
.DESCRIPTION
    Removes Microsoft-RemoteDesktopConnection feature, 32-bit SysWOW64 mstsc binaries, and eradicates RemoteRegistry service and secure winreg pipe.
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

Write-Step "Purging Remote Desktop Client - 32 bit (mstsc32)..."
$rdp32Binaries = @(
    "$MountDir\Windows\SysWOW64\mstsc.exe",
    "$MountDir\Windows\SysWOW64\mstscax.dll",
    "$MountDir\Windows\SysWOW64\mstsctransclient.dll",
    "$MountDir\Windows\SysWOW64\aepic.dll",
    "$MountDir\Windows\SysWOW64\wbem\mstscax.mof"
)
foreach ($bin in $rdp32Binaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted RDP 32-bit binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path "$MountDir\Windows\SysWOW64" -Pattern @("mstsc*.mui", "mstsctransclient*.mui", "aepic*.mui") -Recurse
Remove-ForceFilesByPattern -Path "$MountDir\Windows\SysWOW64\wbem" -Pattern "mstscax.mfl" -Recurse

Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\mstsc.exe"
$rdp32Clsids = @(
    "{4EDCB26C-D24C-4E72-AF07-B576699AC0DE}",
    "{7CACBD7B-0D99-46E8-8832-E42BDAC67D74}",
    "{209d156c-e70e-4bf4-be1d-8524317180fd}",
    "{a9d7c759-61ba-45bc-8840-01045535c49e}",
    "{8C11E605-EAEB-4248-9EBF-FB229A098E4B}"
)
foreach ($cls in $rdp32Clsids) {
    Remove-RegKey "HKCR\WOW6432Node\CLSID\$cls"
}

Write-Success "Purged 32-bit Remote Desktop Client binaries and CLSIDs."

Write-Step "Purging Remote Registry Service Binaries & Pipe Server..."
$remoteRegBinaries = @(
    "$MountDir\Windows\System32\regsvc.dll",
    "$MountDir\Windows\SysWOW64\regsvc.dll"
)
foreach ($bin in $remoteRegBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted RemoteRegistry binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern "regsvc*.mui" -Recurse

Remove-OfflineService "RemoteRegistry"
Remove-RegKey "HKLM\SYSTEM\CurrentControlSet\Control\SecurePipeServers\winreg"
Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\RemoteRegistry"

Remove-RegMultiSzItem -Key "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost" -ValueName "LocalServiceAndNoImpersonation" -Item "RemoteRegistry"
Write-Success "Eradicated Remote Registry service, binaries, and winreg pipe server."
