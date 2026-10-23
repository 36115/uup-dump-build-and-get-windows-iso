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

function Get-WindowsImageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [Parameter(Mandatory = $false)]
        [string]$FallbackVersion = ""
    )

    $images = @(Get-WindowsImage -ImagePath $ImagePath)
    return @($images | ForEach-Object {
        $imgVer = $FallbackVersion
        try {
            $detailed = Get-WindowsImage -ImagePath $ImagePath -Index $_.ImageIndex
            if ($detailed.PSObject.Properties['MajorVersion'] -and $detailed.MajorVersion) {
                $imgVer = "$($detailed.MajorVersion).$($detailed.MinorVersion).$($detailed.Build).$($detailed.SPBuild)"
            }
        } catch {}
        [PSCustomObject]@{
            index   = $_.ImageIndex
            name    = $_.ImageName
            version = $imgVer
        }
    })
}

function Export-WimMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetadataPath,

        [Parameter(Mandatory = $true)]
        [psobject]$Metadata
    )

    Export-IsoMetadata -MetadataPath $MetadataPath -Metadata $Metadata
}

function Merge-WindowsWimImages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$WimFiles,

        [Parameter(Mandatory = $true)]
        [string]$DestinationWimFile
    )
    $totalMerged = 0
    foreach ($wf in $WimFiles) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Inspecting $($wf.FullName)..."
        } else {
            Write-Host "Inspecting $($wf.FullName)..."
        }
        $images = @(Get-WindowsImage -ImagePath $wf.FullName)
        foreach ($img in $images) {
            $idx = $img.ImageIndex
            $name = $img.ImageName
            $totalMerged++
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Exporting index $idx ($name) from $($wf.Name) into AIO WIM (Target Index: $totalMerged)..."
            } else {
                Write-Host "Exporting index $idx ($name) from $($wf.Name) into AIO WIM (Target Index: $totalMerged)..."
            }
            if (-not (Test-Path $DestinationWimFile)) {
                & dism.exe /Export-Image /SourceImageFile:$($wf.FullName) /SourceIndex:$idx /DestinationImageFile:$DestinationWimFile /Compress:max
            } else {
                & dism.exe /Export-Image /SourceImageFile:$($wf.FullName) /SourceIndex:$idx /DestinationImageFile:$DestinationWimFile
            }
            if ($LASTEXITCODE -ne 0) {
                throw "dism /Export-Image failed on $($wf.FullName) index $idx with exit code $LASTEXITCODE"
            }
        }
    }
    return $totalMerged
}

function New-AioIsoImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WimDirectory,

        [Parameter(Mandatory = $false)]
        [string]$WindowsTargetName = '',

        [Parameter(Mandatory = $false)]
        [string]$DestinationDirectory = 'Out',

        [Parameter(Mandatory = $false)]
        [ValidateSet("x64", "arm64")]
        [string]$Architecture = "x64",

        [Parameter(Mandatory = $false)]
        [switch]$Esd,

        [Parameter(Mandatory = $false)]
        [string]$SourceIsoDir,

        [Parameter(Mandatory = $false)]
        [string]$Revision,

        [Parameter(Mandatory = $false)]
        [string]$Lang = "en-us",

        [Parameter(Mandatory = $false)]
        [string]$EditionName = 'AIO',

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = "",

        [Parameter(Mandatory = $false)]
        [string]$TempDirectory = ''
    )

    Set-StrictMode -Version Latest
    $ProgressPreference = 'SilentlyContinue'
    $ErrorActionPreference = 'Stop'

    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "=== Starting All-In-One (AIO) Windows ISO Builder ==="
        Write-CleanLine "Target: $WindowsTargetName | Arch: $Architecture | WimDir: $WimDirectory"
    } else {
        Write-Host "=== Starting All-In-One (AIO) Windows ISO Builder ==="
        Write-Host "Target: $WindowsTargetName | Arch: $Architecture | WimDir: $WimDirectory"
    }

    if (-not (Test-Path $WimDirectory)) {
        throw "WimDirectory '$WimDirectory' does not exist."
    }

    if (-not (Test-Path $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }

    # Discover all WIM / ESD files in WimDirectory
    $wimFiles = @(Get-ChildItem -Path $WimDirectory -Recurse -File | Where-Object {
        $_.Extension -match '^\.(wim|esd)$' -and $_.Name -notmatch '^boot\.'
    })

    if (-not $wimFiles -or $wimFiles.Count -eq 0) {
        throw "No .wim or .esd files found in '$WimDirectory'."
    }

    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Found $($wimFiles.Count) image file(s) in ${WimDirectory}:"
        $wimFiles | ForEach-Object { Write-CleanLine "  - $($_.FullName)" }
    } else {
        Write-Host "Found $($wimFiles.Count) image file(s) in ${WimDirectory}:"
        $wimFiles | ForEach-Object { Write-Host "  - $($_.FullName)" }
    }

    $sortedWimFiles = $wimFiles | Sort-Object { Get-EditionPriority $_.Name }

    # Stage AIO install.wim
    $stagingBase = if ($TempDirectory -and (Test-Path $TempDirectory)) { $TempDirectory } else { $env:TEMP }
    $stagingDir = Join-Path $stagingBase "AIO_Staging_$([System.IO.Path]::GetRandomFileName())"
    $stagingSources = Join-Path $stagingDir "sources"
    New-Item -ItemType Directory -Path $stagingSources -Force | Out-Null

    $mergedWim = Join-Path $stagingSources "install.wim"
    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Merging images into $mergedWim..."
    } else {
        Write-Host "Merging images into $mergedWim..."
    }

    $totalMerged = Merge-WindowsWimImages -WimFiles $sortedWimFiles -DestinationWimFile $mergedWim

    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Successfully merged $totalMerged index(es) into $mergedWim."
    } else {
        Write-Host "Successfully merged $totalMerged index(es) into $mergedWim."
    }

    # Convert to ESD if requested
    if ($Esd) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Converting AIO install.wim to install.esd..."
        } else {
            Write-Host "Converting AIO install.wim to install.esd..."
        }
        $mergedEsd = Join-Path $stagingSources "install.esd"
        for ($i = 1; $i -le $totalMerged; $i++) {
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Exporting index $i of $totalMerged to install.esd /Compress:recovery..."
            } else {
                Write-Host "Exporting index $i of $totalMerged to install.esd /Compress:recovery..."
            }
            & dism.exe /Export-Image /SourceImageFile:$mergedWim /SourceIndex:$i /DestinationImageFile:$mergedEsd /Compress:recovery
            if ($LASTEXITCODE -ne 0) {
                throw "dism /Export-Image to ESD failed on index $i with exit code $LASTEXITCODE"
            }
        }
        Remove-Item $mergedWim -Force
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "ESD conversion complete."
        } else {
            Write-Host "ESD conversion complete."
        }
    }

    # Integrate Base Media
    $resolvedSourceIso = if ($SourceIsoDir -and (Test-Path $SourceIsoDir)) {
        (Resolve-Path $SourceIsoDir).Path
    } elseif (Test-Path (Join-Path $WimDirectory "SourceIso")) {
        (Resolve-Path (Join-Path $WimDirectory "SourceIso")).Path
    } else {
        $null
    }

    if (-not $resolvedSourceIso) {
        throw "Source media directory could not be found to stage the bootable media structure."
    }

    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Staging base media from $resolvedSourceIso into $stagingDir..."
    } else {
        Write-Host "Staging base media from $resolvedSourceIso into $stagingDir..."
    }
    Copy-Item -Path "$resolvedSourceIso\*" -Destination $stagingDir -Recurse -Force

    # Read build metadata from JSON files if available
    $firstJson = Get-ChildItem -Path $WimDirectory -Filter "*.json" -Recurse -File | Select-Object -First 1
    $buildNumber = "UnknownBuild"
    $verbuild = "AIO"
    if ($firstJson) {
        try {
            $meta = Get-Content $firstJson.FullName -Raw | ConvertFrom-Json
            if (-not $WindowsTargetName -and $meta.PSObject.Properties['name'] -and $meta.name) { $WindowsTargetName = $meta.name }
            if ($meta.PSObject.Properties['build'] -and $meta.build)     { $buildNumber = $meta.build }
            if ($meta.PSObject.Properties['version'] -and $meta.version) { $verbuild = $meta.version }
        } catch {}
    }
    if (-not $WindowsTargetName) { $WindowsTargetName = 'windows-11@26h2' }

    $tagVal = if ($ProfileName) {
        $ProfileName
    } else {
        ""
    }
    $finalIsoName = Get-IsoName -TargetName $WindowsTargetName -EditionShort $EditionName -VersionBuild $verbuild -BuildNumber $buildNumber -Tag $tagVal

    $archTag = switch -Regex ($Architecture) {
        'arm64' { 'arm64' }
        default { 'x86_64' }
    }
    $buildTag = if ($buildNumber -and $buildNumber -ne "UnknownBuild") { $buildNumber } else { $verbuild }
    $targetDirectory = Join-Path $DestinationDirectory "Target\$archTag\$buildTag"
    if (-not (Test-Path $targetDirectory)) {
        New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
    }

    $createdIsoPath = Join-Path $targetDirectory "$finalIsoName.iso"

    # Package AIO ISO
    New-IsoImage -SourceDir $stagingDir -DestinationIsoPath $createdIsoPath -VolumeLabel $finalIsoName -Architecture $Architecture -SearchDir $WimDirectory

    # Checksum & Metadata
    $isoChecksum = Set-IsoChecksum -IsoPath $createdIsoPath -ChecksumPath "$createdIsoPath.sha256.txt"

    $finalMediaFile = if ($Esd) { Join-Path $stagingSources "install.esd" } else { Join-Path $stagingSources "install.wim" }
    $finalImages = @(Get-WindowsImage -ImagePath $finalMediaFile)

    $aioTag = ""
    if ($Esd) { $aioTag += ".E" }
    if ($ProfileName -and ($ProfileName -notmatch '(?i)default$')) { $aioTag += ".$ProfileName" }

    Export-IsoMetadata -MetadataPath "$createdIsoPath.json" -Metadata ([PSCustomObject]@{
        name       = $WindowsTargetName
        edition    = $EditionName
        build      = $buildNumber
        version    = $verbuild
        tags       = $aioTag
        checksum   = $isoChecksum
        images     = Get-WindowsImageMetadata -ImagePath $finalMediaFile -FallbackVersion $verbuild
    })

    # Clean staging
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($env:GITHUB_ENV) {
        Write-Output "ISO_NAME=$finalIsoName" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    }

    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "All Done. AIO ISO Ready: $createdIsoPath"
    } else {
        Write-Host "All Done. AIO ISO Ready: $createdIsoPath"
    }
    return $createdIsoPath
}

Set-Alias -Name New-AioIso -Value New-AioIsoImage -ErrorAction SilentlyContinue


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

function Export-WimOnlyArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$distDir,
        [Parameter(Mandatory = $false)]
        [string]$cleanSourceIsoDir = "",
        [Parameter(Mandatory = $true)]
        [string]$targetDirectory,
        [Parameter(Mandatory = $true)]
        [string]$buildDirectory,
        [Parameter(Mandatory = $true)]
        [string]$name,
        [Parameter(Mandatory = $true)]
        [string]$editionShort,
        [Parameter(Mandatory = $true)]
        [string]$build,
        [Parameter(Mandatory = $true)]
        [string]$verbuild,
        [Parameter(Mandatory = $false)]
        [string]$tag = ""
    )
    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "wimOnly mode active. Staging serviced WIM artifact..."
    }
    $finalArtifact = if ($cleanSourceIsoDir -and (Test-Path (Join-Path $cleanSourceIsoDir "sources\install.esd"))) {
        Join-Path $cleanSourceIsoDir "sources\install.esd"
    } elseif ($cleanSourceIsoDir -and (Test-Path (Join-Path $cleanSourceIsoDir "sources\install.wim"))) {
        Join-Path $cleanSourceIsoDir "sources\install.wim"
    } else {
        Join-Path $distDir "sources\install.wim"
    }
    $targetExt = if ($finalArtifact -match '\.esd$') { ".esd" } else { ".wim" }
    $outWimName = "$name-$editionShort$targetExt"
    $outWimPath = Join-Path $targetDirectory $outWimName

    Copy-Item -Path $finalArtifact -Destination $outWimPath -Force
    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Serviced image saved to $outWimPath"
    }

    # Also preserve cdimage.exe if available so assembly jobs do not need to re-fetch
    $cdimageExe = Get-ChildItem -Path $buildDirectory -Filter "cdimage.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
    if ($cdimageExe -and (Test-Path $cdimageExe)) {
        Copy-Item -Path $cdimageExe -Destination (Join-Path $targetDirectory "cdimage.exe") -Force
    }

    # Stage clean SourceIso directory (without install image) for AIO assembly
    if ($cleanSourceIsoDir -and (Test-Path $cleanSourceIsoDir)) {
        $outSourceIsoDir = Join-Path $targetDirectory "SourceIso"
        if (-not (Test-Path $outSourceIsoDir)) {
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Staging clean SourceIso directory to $outSourceIsoDir for AIO assembly..."
            }
            Export-CleanSourceIsoMedia -SourceDirectory $cleanSourceIsoDir -DestinationDirectory $outSourceIsoDir
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Clean SourceIso directory staged successfully."
            }
        }
    }

    # Write JSON metadata
    $wimMetadata = [PSCustomObject]@{
        name       = $name
        edition    = $editionShort
        build      = $build
        version    = $verbuild
        tags       = $tag
        wimFile    = $outWimName
        images     = Get-WindowsImageMetadata -ImagePath $outWimPath -FallbackVersion $verbuild
    }
    Export-WimMetadata -MetadataPath (Join-Path $targetDirectory "$name-$editionShort.json") -Metadata $wimMetadata

    Remove-Item -Path $buildDirectory -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

    if ($env:GITHUB_ENV) {
        Write-Output "WIM_FILE=$outWimPath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
        Write-Output "EDITION_NAME=$editionShort" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
        Write-Output "ISO_NAME=$name-$editionShort" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    }

    # Clean up build scratch directory so runner disk is freed and artifacts are not bloated
    if (Test-Path $buildDirectory) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Cleaning build scratch directory: $buildDirectory..."
        }
        Remove-Item -Path $buildDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "wimOnly completed successfully for $editionShort."
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
