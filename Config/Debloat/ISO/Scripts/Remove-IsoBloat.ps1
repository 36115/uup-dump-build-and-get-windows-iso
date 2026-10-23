<#
.SYNOPSIS
    Removes bloat files, upgrade manifests, telemetry agents, and foreign boot fonts from Windows ISO media.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$MediaDir
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command Remove-IsoBloatItems -ErrorAction SilentlyContinue)) {
    $candidates = @(
        (Join-Path $PSScriptRoot "..\\..\\..\\Utils\ISO\Build-Iso.ps1"),
        (Join-Path $PSScriptRoot "..\\..\\..\\..\\Utils\ISO\Build-Iso.ps1"),
        "Utils\ISO\Build-Iso.ps1"
    )
    foreach ($cand in $candidates) {
        if (Test-Path $cand) { . (Resolve-Path $cand).Path; break }
    }
}

Remove-IsoBloatItems -MediaDir $MediaDir
