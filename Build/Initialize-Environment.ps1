<#
.SYNOPSIS
    Environment and tooling bootstrap script for uup-dump-build-and-get-windows-iso.
.DESCRIPTION
    Dynamically loads all helper modules under Utils/, ensures external binaries
    (aria2, 7z, NSudo, WimLib) are downloaded to External/ and present in PATH
    (including $env:GITHUB_PATH on GitHub Actions runners).
#>

[CmdletBinding()]
param(
    [switch]$Force
)

# 1. Determine repository root
if (-not (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue)) {
    function Get-RepoRoot([string]$startPath) {
        $dir = if ($startPath) { $startPath } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        while ($dir -and -not (Test-Path (Join-Path $dir ".git"))) {
            $parent = Split-Path $dir -Parent
            if (-not $parent -or $parent -eq $dir) { break }
            $dir = $parent
        }
        if ($dir -and (Test-Path (Join-Path $dir ".git"))) {
            return (Resolve-Path $dir).Path
        }
        return (Resolve-Path ".").Path
    }

}

$repoRoot = Get-RepoRoot $PSScriptRoot

# Configure Windows Defender exclusions
if ($IsWindows -or ($env:OS -like "*Windows*")) {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionPath $env:TEMP, "C:\output", "D:\output", "C:\a", "D:\a" -ErrorAction SilentlyContinue
}

# 2. Dot-source all utility helper scripts in Utils/
$utilsDir = Join-Path $repoRoot "Utils"
if (Test-Path $utilsDir) {
    $helperFiles = Get-ChildItem -Path $utilsDir -Filter "*.ps1" -Recurse | Where-Object {
        $_.Name -notmatch '(?i)^(setup|initialize-environment)\.ps1$' -and $_.FullName -notmatch '\\Debloat\\' -and $_.FullName -notmatch '\\AIO\\'
    }
    foreach ($helper in $helperFiles) {
        try {
            . $helper.FullName
        } catch {
            Write-Warning "Could not load helper '$($helper.FullName)': $_"
        }
    }
}

# 3. Discover/download external tools and collect directories for PATH
$pathsToAdd = [System.Collections.Generic.List[string]]::new()

# External/aria2
if (Get-Command Get-Aria2Path -ErrorAction SilentlyContinue) {
    try {
        $aria2Path = Get-Aria2Path
        if ($aria2Path -and (Test-Path $aria2Path -PathType Leaf)) {
            $dir = Split-Path $aria2Path -Parent
            if (-not $pathsToAdd.Contains($dir)) { $pathsToAdd.Add($dir) }
        }
    } catch {
        Write-Warning "aria2 setup failed: $_"
    }
}

# External/7za (7-Zip)
if (Get-Command Get-7zPath -ErrorAction SilentlyContinue) {
    try {
        $sevenZipPath = Get-7zPath
        if ($sevenZipPath -and (Test-Path $sevenZipPath -PathType Leaf)) {
            $dir = Split-Path $sevenZipPath -Parent
            if (-not $pathsToAdd.Contains($dir)) { $pathsToAdd.Add($dir) }
            # Ensure '7z.exe' exists in the folder if 7za.exe is present
            $sevenZTarget = Join-Path $dir "7z.exe"
            if (-not (Test-Path $sevenZTarget) -and ((Split-Path $sevenZipPath -Leaf) -ieq "7za.exe")) {
                Copy-Item -Path $sevenZipPath -Destination $sevenZTarget -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Warning "7z setup failed: $_"
    }
}

# External/NSudo
if (Get-Command Get-NSudoPath -ErrorAction SilentlyContinue) {
    try {
        $nsudoPath = Get-NSudoPath
        if ($nsudoPath -and (Test-Path $nsudoPath -PathType Leaf)) {
            $dir = Split-Path $nsudoPath -Parent
            if (-not $pathsToAdd.Contains($dir)) { $pathsToAdd.Add($dir) }
        }
    } catch {
        Write-Warning "NSudo setup failed: $_"
    }
}

# External/WimLib
if (Get-Command Get-WimLibPath -ErrorAction SilentlyContinue) {
    try {
        $wimlibPath = Get-WimLibPath
        if ($wimlibPath -and (Test-Path $wimlibPath -PathType Leaf)) {
            $dir = Split-Path $wimlibPath -Parent
            if (-not $pathsToAdd.Contains($dir)) { $pathsToAdd.Add($dir) }
        }
    } catch {
        Write-Warning "WimLib setup failed: $_"
    }
}

# 4. Add collected tool directories to PATH and GITHUB_PATH
foreach ($p in $pathsToAdd) {
    if (Test-Path $p) {
        $resolved = (Resolve-Path $p).Path
        $currentPaths = $env:PATH -split [System.IO.Path]::PathSeparator
        if (-not ($currentPaths -contains $resolved)) {
            $env:PATH = "$resolved$([System.IO.Path]::PathSeparator)$env:PATH"
        }
        if ($env:GITHUB_PATH) {
            $resolved | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
        }
    }
}

$global:UUP_ENVIRONMENT_READY = $true
Write-Host "Environment configured successfully. External tools added to PATH." -ForegroundColor Green
