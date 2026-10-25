<#
.SYNOPSIS
    Host architecture discovery.
.DESCRIPTION
    Exposes $global:hostArch ('arm64' or 'x64') for all scripts to consume directly.
#>

$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$global:hostArch = if ($arch -eq 'ARM64') { 'arm64' } else { 'x64' }

function Get-HostArch {
    [CmdletBinding()]
    param()
    return $global:hostArch
}

Set-Alias -Name Get-HostArchitecture -Value Get-HostArch -ErrorAction SilentlyContinue
