<#
.SYNOPSIS
    Windows ISO creation, packaging, and inspection utilities.
.DESCRIPTION
    Provides reusable helper functions for inspecting Windows ISO images and
    packaging bootable Windows installation ISOs using cdimage.exe.
#>

function Get-CdimagePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$CdimagePath = "",

        [Parameter(Mandatory = $false)]
        [string]$SearchDir = ""
    )

    if ($CdimagePath -and (Test-Path $CdimagePath)) {
        return (Resolve-Path $CdimagePath).Path
    }

    if ($SearchDir -and (Test-Path $SearchDir)) {
        $binCdimage = Join-Path $SearchDir "bin\cdimage.exe"
        if (Test-Path $binCdimage) {
            return (Resolve-Path $binCdimage).Path
        }
        $rootCdimage = Join-Path $SearchDir "cdimage.exe"
        if (Test-Path $rootCdimage) {
            return (Resolve-Path $rootCdimage).Path
        }
        $found = Get-ChildItem -Path $SearchDir -Filter "cdimage.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
        if ($found -and (Test-Path $found)) {
            return $found
        }
    }

    $repoCdimage = Join-Path $PSScriptRoot "..\..\cdimage.exe"
    if (Test-Path $repoCdimage) {
        return (Resolve-Path $repoCdimage).Path
    }

    if (Test-Path "cdimage.exe") {
        return (Resolve-Path "cdimage.exe").Path
    }

    $cmd = Get-Command cdimage.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function New-IsoImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$DestinationIsoPath,

        [Parameter(Mandatory = $false)]
        [string]$VolumeLabel = "",

        [Parameter(Mandatory = $false)]
        [ValidateSet("x64", "arm64")]
        [string]$Architecture = "x64",

        [Parameter(Mandatory = $false)]
        [string]$CdimagePath = "",

        [Parameter(Mandatory = $false)]
        [string]$SearchDir = ""
    )

    $cdimageExe = Get-CdimagePath -CdimagePath $CdimagePath -SearchDir $SearchDir
    if (-not $cdimageExe) {
        $cdimageExe = Get-CdimagePath -SearchDir $SourceDir
    }
    if (-not $cdimageExe) {
        throw "cdimage.exe could not be found to build the ISO."
    }

    $destDir = Split-Path $DestinationIsoPath -Parent
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $label = if ([string]::IsNullOrWhiteSpace($VolumeLabel)) {
        [System.IO.Path]::GetFileNameWithoutExtension($DestinationIsoPath)
    } else {
        $VolumeLabel
    }

    $dvdLabel = ($label -replace '[^A-Za-z0-9_]','_')
    if ($dvdLabel.Length -gt 32) {
        $dvdLabel = $dvdLabel.Substring(0, 32)
    }

    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Packaging final ISO with cdimage: $DestinationIsoPath (Label: $dvdLabel)..."
    } else {
        Write-Host "Packaging final ISO with cdimage: $DestinationIsoPath (Label: $dvdLabel)..."
    }

    $bootEtfs = Join-Path $SourceDir "boot\etfsboot.com"
    $bootEfi  = Join-Path $SourceDir "efi\Microsoft\boot\efisys.bin"

    if ($Architecture -ne "arm64" -and (Test-Path $bootEtfs)) {
        & $cdimageExe "-bootdata:2#p0,e,b$bootEtfs#pEF,e,b$bootEfi" -o -m -u2 -udfver102 "-l$dvdLabel" $SourceDir $DestinationIsoPath
    } else {
        & $cdimageExe "-bootdata:1#pEF,e,b$bootEfi" -o -m -u2 -udfver102 "-l$dvdLabel" $SourceDir $DestinationIsoPath
    }

    if ($LASTEXITCODE -ne 0) {
        throw "cdimage.exe failed with exit code $LASTEXITCODE"
    }

    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "ISO generated successfully: $DestinationIsoPath"
    } else {
        Write-Host "ISO generated successfully: $DestinationIsoPath"
    }
}

function Get-IsoWindowsImages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$IsoPath,

        [Parameter(Mandatory = $false)]
        [switch]$Esd
    )

    $IsoPath = (Resolve-Path $IsoPath).Path
    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Mounting $IsoPath"
    } else {
        Write-Host "Mounting $IsoPath"
    }

    $isoImage = Mount-DiskImage $IsoPath -PassThru
    try {
        $isoVolume = $isoImage | Get-Volume
        $installPath = if ($Esd) {
            "$($isoVolume.DriveLetter):\sources\install.esd"
        } elseif (Test-Path "$($isoVolume.DriveLetter):\sources\install.wim") {
            "$($isoVolume.DriveLetter):\sources\install.wim"
        } elseif (Test-Path "$($isoVolume.DriveLetter):\sources\install.esd") {
            "$($isoVolume.DriveLetter):\sources\install.esd"
        } else {
            "$($isoVolume.DriveLetter):\sources\install.wim"
        }

        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Getting Windows images from $installPath"
        } else {
            Write-Host "Getting Windows images from $installPath"
        }

        $winImages = @(Get-WindowsImage -ImagePath $installPath)
        $winImages | ForEach-Object {
            $image = Get-WindowsImage -ImagePath $installPath -Index $_.ImageIndex
            $imgVer = if ($image.PSObject.Properties['MajorVersion'] -and $image.MajorVersion) {
                "$($image.MajorVersion).$($image.MinorVersion).$($image.Build).$($image.SPBuild)"
            } elseif ($image.PSObject.Properties['Version'] -and $image.Version) {
                $image.Version
            } else { "" }
            [PSCustomObject]@{ index = $image.ImageIndex; name = $image.ImageName; version = $imgVer }
        }
    }
    finally {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Dismounting $IsoPath"
        } else {
            Write-Host "Dismounting $IsoPath"
        }
        Dismount-DiskImage $IsoPath | Out-Null
    }
}

function Resolve-TargetDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Architecture,
        [Parameter(Mandatory = $false)]
        [string]$Build = "",
        [Parameter(Mandatory = $false)]
        [string]$FallbackVersion = ""
    )
    $archTag = switch -Regex ($Architecture) {
        'arm64' { 'arm64' }
        default { 'x86_64' }
    }
    $buildTag = if ($Build) { $Build } else { $FallbackVersion }
    $targetDir = Join-Path $DestinationDirectory "Target\$archTag\$buildTag"
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }
    return $targetDir
}
