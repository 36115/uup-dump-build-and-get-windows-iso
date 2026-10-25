<#
.SYNOPSIS
    NSudo helper functions for binary discovery, elevation, and dynamic download.
.DESCRIPTION
    Provides reusable functions across all scripts to locate NSudoLC.exe,
    automatically download it when needed, and execute commands under TrustedInstaller.
#>

function Get-NSudoPath {
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

    $candidateNSudos = @(
        (Join-Path $repoRoot "External\NSudo\NSudoLC.exe"),
        (Join-Path $repoRoot "External\NSudo\$hostArch\NSudoLC.exe"),
        (Join-Path $repoRoot "External\NSudo\ARM64\NSudoLC.exe"),
        (Join-Path $repoRoot "External\NSudo\x64\NSudoLC.exe"),
        (Join-Path $PSScriptRoot "NSudoLC.exe"),
        (Join-Path $PSScriptRoot "$hostArch\NSudoLC.exe"),
        (Join-Path $PSScriptRoot "ARM64\NSudoLC.exe"),
        (Join-Path $PSScriptRoot "x64\NSudoLC.exe")
    )
    foreach ($cand in $candidateNSudos) {
        if (Test-Path $cand -PathType Leaf) {
            return (Resolve-Path $cand).Path
        }
    }

    $cmdNSudo = Get-Command NSudoLC -ErrorAction SilentlyContinue
    if ($cmdNSudo) {
        return $cmdNSudo.Source
    }

    # Destination directory under External\NSudo
    $targetDir = Join-Path $repoRoot "External\NSudo"
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $targetExe = Join-Path $targetDir "NSudoLC.exe"
    if (Test-Path $targetExe -PathType Leaf) {
        return (Resolve-Path $targetExe).Path
    }

    Write-Host "Downloading NSudo from GitHub release ($hostArch)..." -ForegroundColor Cyan
    $tag = Get-LatestGitHubTag "M2TeamArchived/NSudo" "8.2"
    $zipUrl = "https://github.com/M2TeamArchived/NSudo/releases/download/$tag/NSudo_${tag}_All_Components.zip"
    $archFilter = if ($hostArch -eq 'arm64') { "*ARM64*" } else { "*x64*" }

    if (Expand-RemoteArchive -Uri $zipUrl -DestinationPath $targetDir -Files @("NSudoLC.exe") -PathFilter $archFilter) {
        if (Test-Path $targetExe -PathType Leaf) {
            return (Resolve-Path $targetExe).Path
        }
    }

    return $null
}

function Invoke-NSudo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
        [Alias('CommandLine', 'Command')]
        [string[]]$Commands,

        [Parameter(Mandatory = $false)]
        [string]$NSudoPath = ""
    )

    $validCmds = @($Commands | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($validCmds.Count -eq 0) { return }
    $batchContent = "@echo off`r`n" + ($validCmds -join "`r`n") + "`r`nexit"

    if (-not $NSudoPath) { $NSudoPath = Get-NSudoPath }
    if ($NSudoPath -and (Test-Path $NSudoPath -PathType Leaf)) {
        $cmdBatch = Join-Path $env:TEMP "nsudo_$([System.Guid]::NewGuid().ToString('N')).cmd"
        try {
            Set-Content -Path $cmdBatch -Value $batchContent -Encoding ASCII
            & $NSudoPath -U:T -P:E -Wait $cmdBatch *> $null
        } finally {
            if (Test-Path $cmdBatch) { Remove-Item $cmdBatch -Force -ErrorAction SilentlyContinue }
        }
    } else {
        $cmdBatch = Join-Path $env:TEMP "cmd_$([System.Guid]::NewGuid().ToString('N')).cmd"
        try {
            Set-Content -Path $cmdBatch -Value $batchContent -Encoding ASCII
            cmd /c "`"$cmdBatch`" >nul 2>&1"
        } finally {
            if (Test-Path $cmdBatch) { Remove-Item $cmdBatch -Force -ErrorAction SilentlyContinue }
        }
    }
}
