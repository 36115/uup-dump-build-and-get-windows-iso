<#
.SYNOPSIS
    WinPE Hardware Requirement Bypasses & Setup Configuration.
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

Write-Host "  >>> Executing WinPE Component: Bypass-HardwareRequirements..." -ForegroundColor Cyan

if (-not (Get-Command Enable-Win11HardwareBypass -ErrorAction SilentlyContinue)) {
    $candidates = @(
        (Join-Path $PSScriptRoot "..\\..\\..\\Utils\WinPE\WinPE.ps1"),
        (Join-Path $PSScriptRoot "..\\..\\..\\..\\Utils\WinPE\WinPE.ps1"),
        "Utils\WinPE\WinPE.ps1"
    )
    foreach ($cand in $candidates) {
        if (Test-Path $cand) { . (Resolve-Path $cand).Path; break }
    }
}

Enable-Win11HardwareBypass -WinPeHiveKey $WinPeHiveKey -MountDir $MountDir
