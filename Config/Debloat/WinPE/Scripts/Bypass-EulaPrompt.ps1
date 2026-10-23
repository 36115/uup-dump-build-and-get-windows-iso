<#
.SYNOPSIS
    WinPE Setup EULA Bypass via Binary Patching.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$MountDir = "",

    [Parameter(Mandatory = $false)]
    [string]$WinPeHiveKey = "HKLM\WINPE_BOOTSYS",

    [Parameter(Mandatory = $false)]
    [string]$BootWimPath = "",

    [Parameter(Mandatory = $false)]
    [int]$ImageIndex = 2,

    [Parameter(Mandatory = $false)]
    [string]$WimLibPath = "",

    [Parameter(Mandatory = $false)]
    [string]$DistDir = ""
)

$ErrorActionPreference = 'Stop'

Write-Host "  >>> Executing WinPE Component: Bypass-EulaPrompt..." -ForegroundColor Cyan

if (-not (Get-Command Enable-WinPeSetupBypass -ErrorAction SilentlyContinue)) {
    $candidates = @(
        (Join-Path $PSScriptRoot "..\\..\\..\\Utils\WinPE\Invoke-WinPeServicing.ps1"),
        (Join-Path $PSScriptRoot "..\\..\\..\\..\\Utils\WinPE\Invoke-WinPeServicing.ps1"),
        "Utils\WinPE\Invoke-WinPeServicing.ps1"
    )
    foreach ($cand in $candidates) {
        if (Test-Path $cand) { . (Resolve-Path $cand).Path; break }
    }
}

Enable-WinPeSetupBypass -Type Eula @PSBoundParameters
