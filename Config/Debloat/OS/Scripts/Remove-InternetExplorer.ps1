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

Write-Step "Purging Internet Explorer & IE 32-bit..."
$ieDirs = @(
    "$MountDir\Program Files\Internet Explorer",
    "$MountDir\Program Files (x86)\Internet Explorer"
)
foreach ($dir in $ieDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged Internet Explorer directory: $(Split-Path $dir -Leaf)"
    }
}

$ieBinaries = @(
    "$MountDir\Windows\System32\ie4uinit.exe",
    "$MountDir\Windows\System32\ieUnatt.exe",
    "$MountDir\Windows\SysWOW64\ie4uinit.exe",
    "$MountDir\Windows\SysWOW64\ieUnatt.exe"
)
foreach ($bin in $ieBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Internet Explorer binary: $(Split-Path $bin -Leaf)"
    }
}

$ieShortcuts = @(
    "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Internet Explorer.lnk",
    "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories\Internet Explorer.lnk",
    "$MountDir\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Internet Explorer.lnk",
    "$MountDir\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Accessories\Internet Explorer.lnk"
)
foreach ($lnk in $ieShortcuts) {
    if (Test-Path $lnk) {
        Remove-ForceFile $lnk
        Write-Success "Deleted Internet Explorer shortcut: $(Split-Path $lnk -Leaf)"
    }
}

Remove-RegKey "HKLM\SOFTWARE\Clients\StartMenuInternet\IEXPLORE.EXE"
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Clients\StartMenuInternet\IEXPLORE.EXE"
Remove-RegKey "HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11cf-8B85-00AA005B4383}"
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11cf-8B85-00AA005B4383}"
Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\iexplore.exe"
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\iexplore.exe"

Write-Success "Purged Internet Explorer shells, shortcuts, and registrations."
