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


    $candidateAria = @(
        (Join-Path $repoRoot "External\aria2\aria2c.exe"),
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

    Write-Host "Downloading aria2 from official GitHub releases..." -ForegroundColor Cyan
    $zipUrl = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"
    $tempZip = Join-Path $env:TEMP "aria2_1.37.0_$([System.IO.Path]::GetRandomFileName()).zip"
    $tempExtract = Join-Path $env:TEMP "aria2_Ext_$([System.IO.Path]::GetRandomFileName())"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

        $foundExe = Get-ChildItem -Path $tempExtract -Filter "aria2c.exe" -Recurse | Select-Object -First 1
        if ($foundExe) {
            Copy-Item -Path $foundExe.FullName -Destination $targetExe -Force
        }
    } catch {
        Write-Warning "Failed to download aria2: $_"
    } finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path $targetExe -PathType Leaf) {
        return (Resolve-Path $targetExe).Path
    }

    return $null
}
