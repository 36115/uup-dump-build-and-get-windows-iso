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
        (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    }

    $candidate7z = @(
        (Join-Path $repoRoot "External\7za\7z.exe"),
        (Join-Path $repoRoot "External\7za\7za.exe"),
        (Join-Path $repoRoot "External\7z\7z.exe"),
        (Join-Path $repoRoot "External\7z\7za.exe"),
        (Join-Path $repoRoot "External\7z\$hostArch\7z.exe"),
        (Join-Path $PSScriptRoot "windows-$hostArch\7z.exe"),
        (Join-Path $PSScriptRoot "windows-x64\7za.exe"),
        (Join-Path $PSScriptRoot "7za.exe"),
        (Join-Path $PSScriptRoot "7z.exe"),
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

    # Target: External\7za
    $targetDir = Join-Path $repoRoot "External\7za"
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $target7z = Join-Path $targetDir "7z.exe"
    $target7za = Join-Path $targetDir "7za.exe"
    if (Test-Path $target7z -PathType Leaf) {
        return (Resolve-Path $target7z).Path
    }
    if (Test-Path $target7za -PathType Leaf) {
        return (Resolve-Path $target7za).Path
    }

    Write-Host "Downloading native 7-Zip for Windows ($hostArch)..." -ForegroundColor Cyan
    $tag = Get-LatestGitHubTag "ip7z/7zip" "26.05"
    $ver = $tag -replace '\.'
    $installerUrl = "https://github.com/ip7z/7zip/releases/download/$tag/7z$ver-$hostArch.exe"

    $tempSetup = Join-Path $env:TEMP "7z_setup_$([System.IO.Path]::GetRandomFileName()).exe"
    try {
        if (Save-RemoteFile -Uri $installerUrl -DestinationFile $tempSetup) {
            Start-Process -FilePath $tempSetup -ArgumentList "/S", "/D=$targetDir" -Wait
            if (Test-Path $target7z -PathType Leaf) {
                if (-not (Test-Path $target7za)) {
                    Copy-Item -Path $target7z -Destination $target7za -Force -ErrorAction SilentlyContinue
                }
                return (Resolve-Path $target7z).Path
            }
        }
    } finally {
        if (Test-Path $tempSetup) { Remove-Item $tempSetup -Force -ErrorAction SilentlyContinue }
    }

    # Fallback to standalone 7zr
    Write-Host "Falling back to standalone 7za..." -ForegroundColor Yellow
    if (Save-RemoteFile -Uri "https://www.7-zip.org/a/7zr.exe" -DestinationFile $target7za) {
        if (Test-Path $target7za -PathType Leaf) {
            return (Resolve-Path $target7za).Path
        }
    }

    return $null
}
