<#
.SYNOPSIS
    Wimlib helper functions for binary discovery and image servicing.
.DESCRIPTION
    Provides reusable functions across all scripts to locate wimlib-imagex.exe,
    automatically download it when needed, optimize WIM images, and export WIM/ESD images.
#>

function Get-WimLibPath {
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


    $candidateWimlibs = @(
        (Join-Path $repoRoot "External\WimLib\wimlib-imagex.exe"),
        (Join-Path $PSScriptRoot "wimlib-imagex.exe"),
        (Join-Path $PSScriptRoot "windows-x64\wimlib-imagex.exe")
    )
    foreach ($cand in $candidateWimlibs) {
        if (Test-Path $cand -PathType Leaf) {
            return (Resolve-Path $cand).Path
        }
    }

    $cmdWimlib = Get-Command wimlib-imagex -ErrorAction SilentlyContinue
    if ($cmdWimlib) {
        return $cmdWimlib.Source
    }

    # Destination directory: External\WimLib
    $targetDir = Join-Path $repoRoot "External\WimLib"
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $targetExe = Join-Path $targetDir "wimlib-imagex.exe"
    if (Test-Path $targetExe -PathType Leaf) {
        return (Resolve-Path $targetExe).Path
    }

    Write-Host "Downloading wimlib-imagex from wimlib.net..." -ForegroundColor Cyan
    $zipUrl = "https://wimlib.net/downloads/wimlib-1.14.4-windows-x86_64-bin.zip"
    $tempZip = Join-Path $env:TEMP "wimlib_1.14.4_$([System.IO.Path]::GetRandomFileName()).zip"
    $tempExtract = Join-Path $env:TEMP "wimlib_Ext_$([System.IO.Path]::GetRandomFileName())"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
        
        $filesToCopy = @("wimlib-imagex.exe", "libwim-15.dll")
        foreach ($file in $filesToCopy) {
            $foundFile = Get-ChildItem -Path $tempExtract -Filter $file -Recurse | Select-Object -First 1
            if ($foundFile) {
                Copy-Item -Path $foundFile.FullName -Destination (Join-Path $targetDir $file) -Force
            }
        }
    } catch {
        Write-Warning "Failed to download wimlib: $_"
    } finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path $targetExe -PathType Leaf) {
        return (Resolve-Path $targetExe).Path
    }

    return $null
}

function Optimize-WimImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$ImagePath,

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )

    if (-not $WimLibPath) { $WimLibPath = Get-WimLibPath }
    if ($WimLibPath -and (Test-Path $WimLibPath)) {
        & $WimLibPath optimize $ImagePath --recompress --compress=LZX:100 --check
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

function Export-WimImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string]$SourceIndex = "all",

        [Parameter(Mandatory = $false)]
        [switch]$Solid,

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )

    if (-not $WimLibPath) { $WimLibPath = Get-WimLibPath }
    if ($WimLibPath -and (Test-Path $WimLibPath)) {
        $argsList = @("export", $SourcePath, $SourceIndex, $DestinationPath, "--check")
        if ($Solid) { $argsList += "--solid" }
        & $WimLibPath @argsList
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}
