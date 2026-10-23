<#
.SYNOPSIS
    7-Zip helper functions for binary discovery and automated download.
.DESCRIPTION
    Provides reusable functions across all scripts to locate 7za.exe / 7z.exe,
    or automatically download standalone 7za.exe from 7-zip.org into External/7za/7za.exe.
#>

function Get-7zPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = ""
    )

    if ($Path -and (Test-Path $Path -PathType Leaf)) {
        return (Resolve-Path $Path).Path
    }

    # Locate repository root
    $repoRoot = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) {
        Get-RepoRoot $PSScriptRoot
    } else {
        $r = $PSScriptRoot
        while ($r -and -not (Test-Path (Join-Path $r ".git"))) {
            $p = Split-Path $r -Parent
            if ($p -eq $r) { break }
            $r = $p
        }
        if (-not $r -or -not (Test-Path (Join-Path $r ".git"))) {
            $r = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        }
        $r
    }

    $candidate7z = @(
        (Join-Path $repoRoot "External\7za\7za.exe"),
        (Join-Path $repoRoot "External\7z\7za.exe"),
        (Join-Path $PSScriptRoot "windows-x64\7za.exe"),
        (Join-Path $PSScriptRoot "7za.exe"),
        (Join-Path $PSScriptRoot "..\..\External\7za\7za.exe")
    )
    foreach ($cand in $candidate7z) {
        if (Test-Path $cand -PathType Leaf) {
            return (Resolve-Path $cand).Path
        }
    }

    $cmd7z = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd7z) { return $cmd7z.Source }
    $cmd7za = Get-Command 7za -ErrorAction SilentlyContinue
    if ($cmd7za) { return $cmd7za.Source }

    if (Test-Path "$env:ProgramFiles\7-Zip\7z.exe") {
        return "$env:ProgramFiles\7-Zip\7z.exe"
    }
    if (Test-Path "${env:ProgramFiles(x86)}\7-Zip\7z.exe") {
        return "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    }

    # Target: External\7za\7za.exe
    $targetDir = Join-Path $repoRoot "External\7za"
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $targetExe = Join-Path $targetDir "7za.exe"
    if (Test-Path $targetExe -PathType Leaf) {
        return (Resolve-Path $targetExe).Path
    }

    Write-Host "Downloading standalone 7za from 7-zip.org..." -ForegroundColor Cyan
    $url = "https://www.7-zip.org/a/7zr.exe"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $targetExe -UseBasicParsing
    } catch {
        Write-Warning "Failed to download 7za: $_"
    }

    if (Test-Path $targetExe -PathType Leaf) {
        return (Resolve-Path $targetExe).Path
    }

    return $null
}
