<#
.SYNOPSIS
    Purge Internet Explorer & Legacy Browser Shells
.DESCRIPTION
    Purges IE 64/32-bit browser shells, shortcuts, and registry registrations.
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

Write-Step "Purging Internet Explorer 32-bit..."
$ieDir = "$MountDir\Program Files (x86)\Internet Explorer"
if (Test-Path $ieDir) {
    Remove-ForceDirectory $ieDir
    Write-Success "Purged Internet Explorer directory: $(Split-Path $ieDir -Leaf)"
}


Remove-RegKey "HKLM\SOFTWARE\Clients\StartMenuInternet\IEXPLORE.EXE"
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Clients\StartMenuInternet\IEXPLORE.EXE"
Remove-RegKey "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11cf-8B85-00AA005B4383}"
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11cf-8B85-00AA005B4383}"
Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\iexplore.exe"
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\iexplore.exe"

Write-Success "Purged Internet Explorer shells, shortcuts, and registrations."
