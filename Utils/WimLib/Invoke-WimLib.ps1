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

function ConvertTo-WindowsWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )

    if (-not $WimLibPath) { $WimLibPath = Get-WimLibPath }
    if ($WimLibPath -and (Test-Path $WimLibPath)) {
        & $WimLibPath export $SourcePath all $DestinationPath --check
        if ($LASTEXITCODE -ne 0) { throw "wimlib export failed on $SourcePath with exit code $LASTEXITCODE" }
    } else {
        $images = @(Get-WindowsImage -ImagePath $SourcePath)
        for ($i = 1; $i -le $images.Count; $i++) {
            & dism.exe /Export-Image /SourceImageFile:$SourcePath /SourceIndex:$i /DestinationImageFile:$DestinationPath
            if ($LASTEXITCODE -ne 0) { throw "dism /Export-Image failed on index $i with exit code $LASTEXITCODE" }
        }
    }
}

function ConvertTo-WindowsEsd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [int]$ImageCount = 0,

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )

    if (-not $WimLibPath) { $WimLibPath = Get-WimLibPath }
    if ($WimLibPath -and (Test-Path $WimLibPath)) {
        & $WimLibPath export $SourcePath all $DestinationPath --solid --check
        if ($LASTEXITCODE -ne 0) { throw "wimlib export to ESD failed on $SourcePath with exit code $LASTEXITCODE" }
    } else {
        $count = if ($ImageCount -gt 0) { $ImageCount } else { @(Get-WindowsImage -ImagePath $SourcePath).Count }
        for ($i = 1; $i -le $count; $i++) {
            & dism.exe /Export-Image /SourceImageFile:$SourcePath /SourceIndex:$i /DestinationImageFile:$DestinationPath /Compress:recovery
            if ($LASTEXITCODE -ne 0) { throw "dism /Export-Image failed on index $i with exit code $LASTEXITCODE" }
        }
    }
}

function Optimize-WindowsWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$ImagePath,

        [Parameter(Mandatory = $false)]
        [int]$ImageCount = 0,

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )

    if (-not $WimLibPath) { $WimLibPath = Get-WimLibPath }
    if ($WimLibPath -and (Test-Path $WimLibPath)) {
        & $WimLibPath optimize $ImagePath --recompress --compress=LZX:100 --check
        if ($LASTEXITCODE -ne 0) { throw "wimlib optimize failed on $ImagePath with exit code $LASTEXITCODE" }
    } else {
        $count = if ($ImageCount -gt 0) { $ImageCount } else { @(Get-WindowsImage -ImagePath $ImagePath).Count }
        $dir = Split-Path $ImagePath -Parent
        $tempCompact = Join-Path $dir "temp_compact_$([System.IO.Path]::GetRandomFileName()).wim"
        if (Test-Path $tempCompact) { Remove-Item $tempCompact -Force }
        try {
            for ($i = 1; $i -le $count; $i++) {
                & dism.exe /Export-Image /SourceImageFile:$ImagePath /SourceIndex:$i /DestinationImageFile:$tempCompact /Compress:max /CheckIntegrity
                if ($LASTEXITCODE -ne 0) { throw "dism /Export-Image compaction failed on index $i with exit code $LASTEXITCODE" }
            }
            Remove-Item $ImagePath -Force
            Move-Item $tempCompact $ImagePath -Force
        } catch {
            if (Test-Path $tempCompact) { Remove-Item $tempCompact -Force -ErrorAction SilentlyContinue }
            throw
        }
    }
}

function Clone-WindowsWimImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $true)]
        [int]$SourceIndex,
        [Parameter(Mandatory = $true)]
        [string]$DestinationName,
        [Parameter(Mandatory = $false)]
        [string]$DestinationDescription = "",
        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )

    if (-not $WimLibPath) { $WimLibPath = Get-WimLibPath }
    if ($WimLibPath -and (Test-Path $WimLibPath)) {
        & $WimLibPath export $ImagePath $SourceIndex $ImagePath "$DestinationName" "$DestinationDescription"
        if ($LASTEXITCODE -ne 0) { throw "wimlib export clone failed on $ImagePath index $SourceIndex with exit code $LASTEXITCODE" }
    } else {
        $dir = Split-Path $ImagePath -Parent
        $tempClone = Join-Path $dir "clone_$([System.IO.Path]::GetRandomFileName()).wim"
        try {
            & dism.exe /Export-Image /SourceImageFile:$ImagePath /SourceIndex:$SourceIndex /DestinationImageFile:$tempClone /DestinationName:"$DestinationName"
            if ($LASTEXITCODE -ne 0) { throw "dism /Export-Image to temporary clone failed on index $SourceIndex with exit code $LASTEXITCODE" }
            & dism.exe /Export-Image /SourceImageFile:$tempClone /SourceIndex:1 /DestinationImageFile:$ImagePath /DestinationName:"$DestinationName"
            if ($LASTEXITCODE -ne 0) { throw "dism /Export-Image from clone back to destination failed with exit code $LASTEXITCODE" }
        } finally {
            if (Test-Path $tempClone) { Remove-Item $tempClone -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Set-WimImageInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $true)]
        [int]$Index,
        [Parameter(Mandatory = $true)]
        [string]$NewName,
        [Parameter(Mandatory = $false)]
        [string]$NewDescription = "",
        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )

    if (-not $WimLibPath) { $WimLibPath = Get-WimLibPath }
    if ($WimLibPath -and (Test-Path $WimLibPath)) {
        if ($NewDescription) {
            & $WimLibPath info $ImagePath $Index "$NewName" "$NewDescription"
        } else {
            & $WimLibPath info $ImagePath $Index "$NewName"
        }
        if ($LASTEXITCODE -ne 0) { throw "wimlib info failed to update metadata on $ImagePath index $Index with exit code $LASTEXITCODE" }
    }
}

function Resolve-ServicingWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistributionDirectory,
        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )
    $installWim = Join-Path $DistributionDirectory "sources\install.wim"
    if (-not (Test-Path $installWim)) {
        $installEsd = Join-Path $DistributionDirectory "sources\install.esd"
        if (Test-Path $installEsd) {
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Exporting install.esd to install.wim for servicing..."
            }
            ConvertTo-WindowsWim -SourcePath $installEsd -DestinationPath $installWim -WimLibPath $WimLibPath
            Remove-Item $installEsd -Force
        } else {
            throw "Neither install.wim nor install.esd found in $DistributionDirectory\sources"
        }
    }
    return $installWim
}

function ConvertTo-DistributionEsd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistributionDirectory,
        [Parameter(Mandatory = $false)]
        [string]$InstallWim = "",
        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )
    if (-not $InstallWim) {
        $InstallWim = Join-Path $DistributionDirectory "sources\install.wim"
    }
    if (Test-Path $InstallWim) {
        $wimImages = @(Get-WindowsImage -ImagePath $InstallWim)
        $imageCount = $wimImages.Count
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Converting install.wim ($imageCount index(es)) to install.esd..."
        }
        $installEsd = Join-Path $DistributionDirectory "sources\install.esd"
        if (Test-Path $installEsd) { Remove-Item $installEsd -Force }
        ConvertTo-WindowsEsd -SourcePath $InstallWim -DestinationPath $installEsd -ImageCount $imageCount -WimLibPath $WimLibPath
        Remove-Item $InstallWim -Force
        return $installEsd
    }
    return ""
}
