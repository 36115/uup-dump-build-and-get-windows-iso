<#
.SYNOPSIS
    aria2 helper functions for binary discovery and automated download.
.DESCRIPTION
    Provides reusable functions across all scripts to locate aria2c.exe,
    or automatically download it from official GitHub releases into External/aria2/aria2c.exe.
#>

function Get-Aria2Path {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = "",

        [Parameter(Mandatory = $false)]
        [string]$SearchDir = ""
    )

    if ($Path -and (Test-Path $Path -PathType Leaf)) {
        return (Resolve-Path $Path).Path
    }

    if ($SearchDir -and (Test-Path $SearchDir)) {
        $binAria = Join-Path $SearchDir "bin\aria2c.exe"
        if (Test-Path $binAria -PathType Leaf) {
            return (Resolve-Path $binAria).Path
        }
        $rootAria = Join-Path $SearchDir "aria2c.exe"
        if (Test-Path $rootAria -PathType Leaf) {
            return (Resolve-Path $rootAria).Path
        }
    }

    # Locate repository root
    $repoRoot = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) {
        Get-RepoRoot $PSScriptRoot
    } else {
        (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    }

    $candidateAria = @(
        (Join-Path $repoRoot "External\aria2\aria2c.exe"),
        (Join-Path $repoRoot "External\aria2\$hostArch\aria2c.exe"),
        (Join-Path $PSScriptRoot "..\..\External\aria2\aria2c.exe"),
        (Join-Path $PSScriptRoot "..\aria2\aria2c.exe"),
        (Join-Path $PSScriptRoot "aria2c.exe")
    )
    foreach ($cand in $candidateAria) {
        if (Test-Path $cand -PathType Leaf) {
            return (Resolve-Path $cand).Path
        }
    }

    $cmdAria = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($cmdAria) {
        return $cmdAria.Source
    }

    # Target: External\aria2\aria2c.exe
    $targetDir = Join-Path $repoRoot "External\aria2"
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $targetExe = Join-Path $targetDir "aria2c.exe"
    if (Test-Path $targetExe -PathType Leaf) {
        return (Resolve-Path $targetExe).Path
    }

    Write-Host "Downloading aria2 ($hostArch) from official GitHub releases..." -ForegroundColor Cyan
    $repo = if ($hostArch -eq 'arm64') { "minnyres/aria2-windows-arm64" } else { "aria2/aria2" }
    $defaultTag = if ($hostArch -eq 'arm64') { "v1.37.0" } else { "release-1.37.0" }
    $tag = Get-LatestGitHubTag $repo $defaultTag
    $v = $tag -replace '^(release-|v)'
    $zipUrl = if ($hostArch -eq 'arm64') {
        "https://github.com/minnyres/aria2-windows-arm64/releases/download/$tag/aria2_${v}_arm64.zip"
    } else {
        "https://github.com/aria2/aria2/releases/download/$tag/aria2-$v-win-64bit-build1.zip"
    }

    if (Expand-RemoteArchive -Uri $zipUrl -DestinationPath $targetDir -Files @("aria2c.exe")) {
        if (Test-Path $targetExe -PathType Leaf) {
            return (Resolve-Path $targetExe).Path
        }
    }

    return $null
}
