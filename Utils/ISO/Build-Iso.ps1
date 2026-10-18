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

function Set-IsoChecksum {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [Parameter(Mandatory = $false)]
    [string]$ChecksumPath = ""
  )

  $IsoPath = (Resolve-Path $IsoPath).Path
  if ([string]::IsNullOrWhiteSpace($ChecksumPath)) {
    $ChecksumPath = "$IsoPath.sha256.txt"
  }

  if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
    Write-CleanLine "Getting the $IsoPath checksum"
  } else {
    Write-Host "Getting the $IsoPath checksum"
  }

  $hash = (Get-FileHash -Algorithm SHA256 $IsoPath).Hash.ToLowerInvariant()
  Set-Content -Encoding ascii -NoNewline -Path $ChecksumPath -Value $hash
  return $hash
}

function Export-IsoMetadata {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$MetadataPath,

    [Parameter(Mandatory = $true)]
    [psobject]$Metadata
  )

  $dir = Split-Path $MetadataPath -Parent
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  $json = ($Metadata | ConvertTo-Json -Depth 99) -replace '\\u0026','&'
  Set-Content -Encoding utf8 -Path $MetadataPath -Value $json
}

function Get-IsoName {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetName,

    [Parameter(Mandatory = $true)]
    [string]$EditionShort,

    [Parameter(Mandatory = $true)]
    [string]$VersionBuild,

    [Parameter(Mandatory = $true)]
    [string]$BuildNumber,

    [Parameter(Mandatory = $false)]
    [string]$Tag = "Lite"
  )

  $osPrefix = if ($TargetName -match '(?i)win(dows)?[-_\s]?10') { 'Win10' } else { 'Win11' }
  $tagPart = if ([string]::IsNullOrWhiteSpace($Tag)) { '' } else { "-$Tag" }
  return "$osPrefix-$EditionShort-$VersionBuild$tagPart-$BuildNumber"
}


function Resolve-DistributionDirectory {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDirectory
  )

  $distDir = Get-ChildItem -Path $BuildDirectory -Directory -ErrorAction SilentlyContinue | Where-Object {
    (Test-Path (Join-Path $_.FullName "sources\install.wim")) -or (Test-Path (Join-Path $_.FullName "sources\install.esd"))
  } | Select-Object -First 1 -ExpandProperty FullName

  if (-not $distDir) {
    if (Test-Path (Join-Path $BuildDirectory "ISOFOLDER\sources\install.wim")) {
      $distDir = Join-Path $BuildDirectory "ISOFOLDER"
    } elseif (Test-Path (Join-Path $BuildDirectory "ISOFOLDER\sources\install.esd")) {
      $distDir = Join-Path $BuildDirectory "ISOFOLDER"
    } else {
      throw "Could not locate distribution folder with sources\install.wim in $BuildDirectory"
    }
  }

  return $distDir
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

function Export-IsoArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildDirectory,
        [Parameter(Mandatory = $true)]
        [string]$TargetDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [psobject]$IsoInfo,
        [Parameter(Mandatory = $true)]
        [string]$VersionBuild,
        [Parameter(Mandatory = $false)]
        [string]$Tag = ""
    )
    $sourceIsoPath = Resolve-Path (Join-Path $BuildDirectory "*.iso")
    $isoName = Split-Path $sourceIsoPath -Leaf

    $finalIsoPath = Join-Path $TargetDirectory $isoName
    $destinationIsoChecksumPath = "$finalIsoPath.sha256.txt"
    $destinationIsoMetadataPath = "$finalIsoPath.json"

    $isoChecksum = Set-IsoChecksum -IsoPath $sourceIsoPath -ChecksumPath $destinationIsoChecksumPath
    $windowsImages = Get-IsoWindowsImages $sourceIsoPath
    Export-IsoMetadata -MetadataPath $destinationIsoMetadataPath -Metadata ([PSCustomObject]@{
        name     = $Name
        title    = $IsoInfo.title
        build    = $IsoInfo.build
        version  = $VersionBuild
        tags     = $Tag
        checksum = $isoChecksum
        images   = @($windowsImages)
        uupDump  = @{
            id                 = $IsoInfo.id
            apiUrl             = $IsoInfo.apiUrl
            downloadUrl        = $IsoInfo.downloadUrl
            downloadPackageUrl = $IsoInfo.downloadPackageUrl
        }
    })

    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Moving the created $sourceIsoPath to $finalIsoPath"
    }
    Move-Item -Force $sourceIsoPath $finalIsoPath
    Remove-Item -Force -Recurse $BuildDirectory -ErrorAction SilentlyContinue | Out-Null

    if ($env:GITHUB_ENV) {
        Write-Output "ISO_NAME=$isoName" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    }
    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine 'All Done.'
    }
}