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
        [string]$Tag = "Lite",

        [Parameter(Mandatory = $false)]
        [string]$TargetOS = "",

        [Parameter(Mandatory = $false)]
        [string]$Format = ""
    )

    $resolvedTarget = if ($TargetOS) {
        $TargetOS
    } elseif (Test-Path variable:global:targetOS) {
        $global:targetOS
    } elseif ($TargetName -match '(?i)win(dows)?[-_\s]?10' -or ($BuildNumber -and $BuildNumber -ne "UnknownBuild" -and [int]($BuildNumber -split '\.')[0] -lt 22000)) {
        '10'
    } else {
        '11'
    }
    $osPrefix = "Win$resolvedTarget"
    $tagPart = if ([string]::IsNullOrWhiteSpace($Tag)) { '' } else { "-$Tag" }

    if ($Format) {
        $res = $Format
        $targetVal = if ($TargetName -and $TargetName -notmatch '[-_]') { $TargetName } else { $osPrefix }
        $res = $res -replace '\{TargetName\}', $targetVal
        $res = $res -replace '\{TargetOS\}', $resolvedTarget
        $res = $res -replace '\{OsPrefix\}', $osPrefix
        $res = $res -replace '\{Edition\}', $EditionShort
        $res = $res -replace '\{EditionShort\}', $EditionShort
        $res = $res -replace '\{Version\}', $VersionBuild
        $res = $res -replace '\{VersionBuild\}', $VersionBuild
        $res = $res -replace '\{Build\}', $BuildNumber
        $res = $res -replace '\{BuildNumber\}', $BuildNumber
        $res = $res -replace '\{Tag\}', $Tag
        return $res
    }

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
        [string]$DestinationWimFile,

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = ""
    )
    if (-not $WimLibPath -and (Get-Command Get-WimLibPath -ErrorAction SilentlyContinue)) {
        $WimLibPath = Get-WimLibPath
    }

    $totalMerged = 0
    if ($WimLibPath -and (Test-Path $WimLibPath)) {
        foreach ($wf in $WimFiles) {
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Exporting all indexes from $($wf.Name) into AIO WIM using wimlib-imagex..."
            } else {
                Write-Host "Exporting all indexes from $($wf.Name) into AIO WIM using wimlib-imagex..."
            }
            & $WimLibPath export $($wf.FullName) all $DestinationWimFile --compress=LZX:100 --check
            if ($LASTEXITCODE -ne 0) {
                throw "wimlib-imagex export failed on $($wf.FullName) with exit code $LASTEXITCODE"
            }
        }
        $totalMerged = @(Get-WindowsImage -ImagePath $DestinationWimFile).Count
    } else {
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
    }
    return $totalMerged
}

function Resolve-BaseMediaSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SourceIsoDir = "",

        [Parameter(Mandatory = $false)]
        [string]$SourceIso = "",

        [Parameter(Mandatory = $false)]
        [string]$SearchDir = ""
    )

    if ($SourceIsoDir -and (Test-Path $SourceIsoDir)) {
        return (Resolve-Path $SourceIsoDir).Path
    }
    if ($SourceIso -and (Test-Path $SourceIso)) {
        return (Resolve-Path $SourceIso).Path
    }
    if ($SearchDir -and (Test-Path (Join-Path $SearchDir "SourceIso"))) {
        return (Resolve-Path (Join-Path $SearchDir "SourceIso")).Path
    }
    return $null
}

function Export-CleanSourceIsoMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    if (-not (Test-Path $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }

    Get-ChildItem -Path $SourceDirectory | ForEach-Object {
        $itemName = $_.Name
        if ($_.PSIsContainer) {
            $destSub = Join-Path $DestinationDirectory $itemName
            New-Item -ItemType Directory -Path $destSub -Force | Out-Null
            Get-ChildItem -Path $_.FullName | ForEach-Object {
                if ($_.Name -notmatch '^install\.(wim|esd|swm)$') {
                    Copy-Item -Path $_.FullName -Destination (Join-Path $destSub $_.Name) -Recurse -Force
                }
            }
        } else {
            Copy-Item -Path $_.FullName -Destination (Join-Path $DestinationDirectory $itemName) -Force
        }
    }
}

function Copy-BootDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$DestDir
    )

    if (-not (Test-Path $SourceDir)) { return }
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

    Get-ChildItem -Path $SourceDir -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($SourceDir.Length).TrimStart('\', '/')
        $target = Join-Path $DestDir $rel
        if ($_.PSIsContainer) {
            if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
        } else {
            $parentDir = Split-Path $target -Parent
            if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
            Copy-Item -Path $_.FullName -Destination $target -Force
        }
    }
}

function Copy-FilteredSources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$DestDir
    )

    if (-not (Test-Path $SourceDir)) { return }
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

    $skipFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    @("install.wim", "install.esd", "install.swm") | ForEach-Object { [void]$skipFiles.Add($_) }

    Get-ChildItem -Path $SourceDir | ForEach-Object {
        $name = $_.Name
        if ($_.PSIsContainer) {
            Copy-Item -Path $_.FullName -Destination (Join-Path $DestDir $name) -Recurse -Force
        } else {
            if ($skipFiles.Contains($name)) { return }
            Copy-Item -Path $_.FullName -Destination (Join-Path $DestDir $name) -Force
        }
    }
}

function Patch-BootWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BootWimPath,

        [Parameter(Mandatory = $true)]
        [string]$DistDir,

        [Parameter(Mandatory = $false)]
        [string]$ScriptsDir = "",

        [Parameter(Mandatory = $false)]
        [string]$RegistryDir = "",

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = "",

        [Parameter(Mandatory = $false)]
        [string]$TargetOS = "",

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = ""
    )

    if (-not (Test-Path $BootWimPath)) { return }

    if (-not $TargetOS) {
        $TargetOS = if (Test-Path variable:global:targetOS) {
            $global:targetOS
        } else {
            '11'
        }
    }

    Set-ItemProperty -Path $BootWimPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    & attrib.exe -r $BootWimPath *> $null

    $mntBoot = Join-Path $env:TEMP "Mount_BootWim_$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $mntBoot -Force | Out-Null

    $hiveLoaded = $false
    try {
        & dism.exe /Mount-Wim /WimFile:$BootWimPath /Index:2 /MountDir:$mntBoot
        if ($LASTEXITCODE -ne 0) { throw "dism /Mount-Wim failed on boot.wim with exit code $LASTEXITCODE" }

        # Load offline WinPE SYSTEM hive
        $sysHive = Join-Path $mntBoot "Windows\System32\config\SYSTEM"
        if (Test-Path $sysHive) {
            cmd /c "reg unload HKLM\WINPE_BOOTSYS >nul 2>&1"
            $null = cmd /c "reg load HKLM\WINPE_BOOTSYS `"$sysHive`" 2>&1"
            if ($LASTEXITCODE -eq 0) { $hiveLoaded = $true }
        }

        $repoRoot = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) { Get-RepoRoot $PSScriptRoot } else { (Resolve-Path ".").Path }
        if (-not (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue)) {
            $profHelper = Join-Path $PSScriptRoot "..\Common\Resolve-Profile.ps1"
            if (-not (Test-Path $profHelper)) { $profHelper = Join-Path $repoRoot "Utils\Common\Resolve-Profile.ps1" }
            if (Test-Path $profHelper) { . $profHelper }
        }

        $profileDir = if ($ProfileName -and (Get-Command Resolve-ProfileDir -ErrorAction SilentlyContinue)) {
            Resolve-ProfileDir -ProfileName $ProfileName -TargetOS $TargetOS -RepoRoot $repoRoot
        } else { "" }

        $profileChain = if ($profileDir -and (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue)) {
            Get-ProfileHierarchy -ProfileDir $profileDir -RepoRoot $repoRoot -TargetOS $TargetOS
        } else { @() }

        # Discover and import WinPE registry files from profile hierarchy
        $scannedRegFiles = [System.Collections.Generic.List[string]]::new()
        if ($RegistryDir -and (Test-Path $RegistryDir)) {
            Get-ChildItem -Path $RegistryDir -Filter "*.reg" -File -ErrorAction SilentlyContinue | ForEach-Object {
                if (-not $scannedRegFiles.Contains($_.FullName)) { $scannedRegFiles.Add($_.FullName) }
            }
        }
        foreach ($item in $profileChain) {
            foreach ($sub in @("WinPE\Registry", "Registry", "All\Registry")) {
                $regDir = Join-Path $item.Dir $sub
                if (Test-Path $regDir) {
                    Get-ChildItem -Path $regDir -Filter "*.reg" -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
                        if (-not $scannedRegFiles.Contains($_.FullName)) { $scannedRegFiles.Add($_.FullName) }
                    }
                }
            }
        }

        foreach ($regPath in $scannedRegFiles) {
            $raw = [System.IO.File]::ReadAllText($regPath, [System.Text.Encoding]::UTF8)
            $replacements = @(
                @('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\', 'HKEY_LOCAL_MACHINE\WINPE_BOOTSYS\ControlSet001\'),
                @('HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\',     'HKEY_LOCAL_MACHINE\WINPE_BOOTSYS\ControlSet001\'),
                @('HKEY_LOCAL_MACHINE\SYSTEM\',                    'HKEY_LOCAL_MACHINE\WINPE_BOOTSYS\'),
                @('HKLM\SYSTEM\CurrentControlSet\',                'HKLM\WINPE_BOOTSYS\ControlSet001\'),
                @('HKLM\SYSTEM\ControlSet001\',                    'HKLM\WINPE_BOOTSYS\ControlSet001\'),
                @('HKLM\SYSTEM\',                                   'HKLM\WINPE_BOOTSYS\')
            )
            foreach ($r in $replacements) { $raw = $raw.Replace($r[0], $r[1]) }
            $tmpReg = Join-Path $env:TEMP "winpe_import_$([System.IO.Path]::GetRandomFileName()).reg"
            try {
                [System.IO.File]::WriteAllText($tmpReg, $raw, [System.Text.Encoding]::Unicode)
                cmd /c "reg import `"$tmpReg`" >nul 2>&1"
            } finally {
                if (Test-Path $tmpReg) { Remove-Item $tmpReg -Force -ErrorAction SilentlyContinue }
            }
        }

        # Discover and execute WinPE component scripts from profile hierarchy
        $scannedScripts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $profileChain) {
            $cfg = $item.Config
            $baseDir = $item.Dir
            if ($cfg -and $cfg.ContainsKey('Scripts') -and $cfg.Scripts) {
                foreach ($sc in $cfg.Scripts) {
                    $cand = Join-Path $baseDir $sc
                    if (-not (Test-Path $cand)) { $cand = Join-Path $repoRoot $sc }
                    if (Test-Path $cand) {
                        $resolved = (Resolve-Path $cand).Path
                        $scriptCmd = Get-Command $resolved -ErrorAction SilentlyContinue
                        if ($scriptCmd -and ($scriptCmd.Parameters.ContainsKey('WinPeHiveKey') -or $scriptCmd.Parameters.ContainsKey('BootWimPath') -or ($resolved -match '(?i)winpe|bypass'))) {
                            if (-not $scannedScripts.Contains($resolved)) {
                                $scannedScripts.Add($resolved)
                            }
                        }
                    }
                }
            }
            if ($cfg -and $cfg.ContainsKey('WinPeScripts') -and $cfg.WinPeScripts) {
                foreach ($sc in $cfg.WinPeScripts) {
                    $cand = Join-Path $baseDir $sc
                    if (-not (Test-Path $cand)) { $cand = Join-Path $repoRoot $sc }
                    if (Test-Path $cand) {
                        $resolved = (Resolve-Path $cand).Path
                        if (-not $scannedScripts.Contains($resolved)) {
                            $scannedScripts.Add($resolved)
                        }
                    }
                }
            }
            $winpeDir = Join-Path $baseDir "WinPE\Scripts"
            if (Test-Path $winpeDir) {
                Get-ChildItem -Path $winpeDir -Filter "*.ps1" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^Patch-BinaryPattern\.ps1$' } | ForEach-Object {
                    if (-not $scannedScripts.Contains($_.FullName)) { $scannedScripts.Add($_.FullName) }
                }
            }
        }

        foreach ($sScript in $scannedScripts) {
            $scriptCmd = Get-Command $sScript -ErrorAction SilentlyContinue
            $splat = @{}
            if ($scriptCmd) {
                $sp = $scriptCmd.Parameters
                if ($sp.ContainsKey('MountDir')) { $splat['MountDir'] = $mntBoot }
                if ($sp.ContainsKey('WinPeHiveKey')) { $splat['WinPeHiveKey'] = "HKLM\WINPE_BOOTSYS" }
                if ($sp.ContainsKey('BootWimPath')) { $splat['BootWimPath'] = $BootWimPath }
                if ($sp.ContainsKey('ImageIndex')) { $splat['ImageIndex'] = 2 }
                if ($sp.ContainsKey('WimLibPath')) { $splat['WimLibPath'] = $WimLibPath }
                if ($sp.ContainsKey('DistDir')) { $splat['DistDir'] = $DistDir }
                if ($sp.ContainsKey('TargetOS')) { $splat['TargetOS'] = $TargetOS }
                if ($sp.ContainsKey('ProfileName')) { $splat['ProfileName'] = $ProfileName }
            }
            & $sScript @splat
        }
    } finally {
        if ($hiveLoaded) {
            cmd /c "reg unload HKLM\WINPE_BOOTSYS >nul 2>&1"
        }
        & dism.exe /Unmount-Wim /MountDir:$mntBoot /Commit
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "dism /Unmount-Wim /Commit failed with exit code $LASTEXITCODE. Attempting discard..."
            & dism.exe /Unmount-Wim /MountDir:$mntBoot /Discard
        }
        Remove-Item $mntBoot -Force -Recurse -ErrorAction SilentlyContinue
    }

    if ($WimLibPath -and (Test-Path $WimLibPath)) {
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            & $WimLibPath optimize $BootWimPath --recompress --compress=LZX:100 *> $null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2
        }
    }
}

function New-BaseIsoMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SourceIsoPath,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$OutputDirectory = "",

        [Parameter(Mandatory = $false)]
        [string]$ScriptsDir = "",

        [Parameter(Mandatory = $false)]
        [string]$RegistryDir = "",

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = "",

        [Parameter(Mandatory = $false)]
        [string]$TargetOS = "",

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = ""
    )

    if (-not $SourceIsoPath -or -not (Test-Path $SourceIsoPath)) {
        throw "Source ISO or media directory not found: '$SourceIsoPath'"
    }
    $SourceIsoPath = (Resolve-Path $SourceIsoPath).Path
    $isIsoFile = -not (Test-Path $SourceIsoPath -PathType Container)

    $repoRoot = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) { Get-RepoRoot $PSScriptRoot } else { (Resolve-Path ".").Path }
    if (-not $WimLibPath -and (Get-Command Get-WimLibPath -ErrorAction SilentlyContinue)) {
        $WimLibPath = Get-WimLibPath
    }

    if (-not $TargetOS) {
        $TargetOS = if (Test-Path variable:global:targetOS) {
            $global:targetOS
        } elseif ($SourceIsoPath -match '(?i)win(dows)?[-_\s]?10') {
            '10'
        } else {
            '11'
        }
    }

    if (-not $OutputDirectory) {
        $OutputDirectory = Join-Path $env:TEMP "ISOBase_$([System.IO.Path]::GetRandomFileName())"
    }

    $stagedInstallWim = $null
    $stagedInstallEsd = $null
    $tempPreserveDir = $null
    $isSelfTarget = $false
    if (Test-Path $SourceIsoPath -PathType Container) {
        $srcResolved = (Resolve-Path $SourceIsoPath).Path.TrimEnd('\/')
        $outResolved = if (Test-Path $OutputDirectory) { (Resolve-Path $OutputDirectory).Path.TrimEnd('\/') } else { $OutputDirectory.TrimEnd('\/') }
        if ($srcResolved -ieq $outResolved) { $isSelfTarget = $true }
    }

    if (-not $isSelfTarget -and (Test-Path $OutputDirectory)) {
        $existingWim = Join-Path $OutputDirectory "sources\install.wim"
        $existingEsd = Join-Path $OutputDirectory "sources\install.esd"
        if ((Test-Path $existingWim) -or (Test-Path $existingEsd)) {
            $tempPreserveDir = Join-Path $env:TEMP "Preserve_Install_$([System.IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $tempPreserveDir -Force | Out-Null
            if (Test-Path $existingWim) {
                Move-Item $existingWim (Join-Path $tempPreserveDir "install.wim") -Force
                $stagedInstallWim = Join-Path $tempPreserveDir "install.wim"
            }
            if (Test-Path $existingEsd) {
                Move-Item $existingEsd (Join-Path $tempPreserveDir "install.esd") -Force
                $stagedInstallEsd = Join-Path $tempPreserveDir "install.esd"
            }
        }
        Remove-Item $OutputDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    $isMounted = $false
    $isoDrive = $null
    if ($isIsoFile) {
        $isoImage = Mount-DiskImage -ImagePath $SourceIsoPath -PassThru
        $isoVol = $isoImage | Get-Volume
        if (-not $isoVol -or -not $isoVol.DriveLetter) { throw "Failed to mount ISO: $SourceIsoPath" }
        $isoDrive = "$($isoVol.DriveLetter):\"
        $isMounted = $true
    } else {
        $isoDrive = $SourceIsoPath
    }

    try {
        $rootFiles = @("bootmgr", "bootmgr.efi", "autorun.inf", "setup.exe")
        foreach ($rf in $rootFiles) {
            $srcPath = Join-Path $isoDrive $rf
            if (Test-Path $srcPath) { Copy-Item -Path $srcPath -Destination (Join-Path $OutputDirectory $rf) -Force }
        }

        Copy-BootDirectory -SourceDir (Join-Path $isoDrive "boot") -DestDir (Join-Path $OutputDirectory "boot")
        Copy-BootDirectory -SourceDir (Join-Path $isoDrive "efi") -DestDir (Join-Path $OutputDirectory "efi")
        Copy-FilteredSources -SourceDir (Join-Path $isoDrive "sources") -DestDir (Join-Path $OutputDirectory "sources")

        # Discover and execute ISO media scripts from profile hierarchy
        if (-not (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue)) {
            $profHelper = Join-Path $PSScriptRoot "..\Common\Resolve-Profile.ps1"
            if (-not (Test-Path $profHelper)) { $profHelper = Join-Path $repoRoot "Utils\Common\Resolve-Profile.ps1" }
            if (Test-Path $profHelper) { . $profHelper }
        }
        $profileDir = if ($ProfileName -and (Get-Command Resolve-ProfileDir -ErrorAction SilentlyContinue)) {
            Resolve-ProfileDir -ProfileName $ProfileName -TargetOS $TargetOS -RepoRoot $repoRoot
        } else { "" }
        $profileChain = if ($profileDir -and (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue)) {
            Get-ProfileHierarchy -ProfileDir $profileDir -RepoRoot $repoRoot -TargetOS $TargetOS
        } else { @() }

        $scannedIsoScripts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $profileChain) {
            foreach ($sub in @("ISO\Scripts", "ISO")) {
                $isoScriptDir = Join-Path $item.Dir $sub
                if (Test-Path $isoScriptDir) {
                    Get-ChildItem -Path $isoScriptDir -Filter "*.ps1" -File -ErrorAction SilentlyContinue | ForEach-Object {
                        if (-not $scannedIsoScripts.Contains($_.FullName)) {
                            $scannedIsoScripts.Add($_.FullName)
                        }
                    }
                }
            }
        }

        foreach ($isoScript in $scannedIsoScripts) {
            Write-Host "  >>> Executing ISO Media Component: $([System.IO.Path]::GetFileName($isoScript))..." -ForegroundColor Cyan
            $scriptCmd = Get-Command $isoScript -ErrorAction SilentlyContinue
            $splat = @{}
            if ($scriptCmd) {
                $sp = $scriptCmd.Parameters
                if ($sp.ContainsKey('MediaDir')) { $splat['MediaDir'] = $OutputDirectory }
                if ($sp.ContainsKey('TargetOS')) { $splat['TargetOS'] = $TargetOS }
                if ($sp.ContainsKey('ProfileName')) { $splat['ProfileName'] = $ProfileName }
            } else {
                $splat['MediaDir'] = $OutputDirectory
            }
            & $isoScript @splat
        }
    } finally {
        if ($isMounted) {
            Dismount-DiskImage -ImagePath $SourceIsoPath | Out-Null
        }
    }

    if ($tempPreserveDir -and (Test-Path $tempPreserveDir)) {
        $destSources = Join-Path $OutputDirectory "sources"
        if (-not (Test-Path $destSources)) { New-Item -ItemType Directory -Path $destSources -Force | Out-Null }
        if ($stagedInstallWim -and (Test-Path $stagedInstallWim)) {
            Move-Item $stagedInstallWim (Join-Path $destSources "install.wim") -Force
        }
        if ($stagedInstallEsd -and (Test-Path $stagedInstallEsd)) {
            Move-Item $stagedInstallEsd (Join-Path $destSources "install.esd") -Force
        }
        Remove-Item $tempPreserveDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $bootWim = Join-Path (Join-Path $OutputDirectory "sources") "boot.wim"
    Patch-BootWim -BootWimPath $bootWim -DistDir $OutputDirectory -ScriptsDir $ScriptsDir -RegistryDir $RegistryDir -WimLibPath $WimLibPath -TargetOS $TargetOS -ProfileName $ProfileName

    return $OutputDirectory
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
        [string]$SourceIso,

        [Parameter(Mandatory = $false)]
        [string]$Revision,

        [Parameter(Mandatory = $false)]
        [string]$Lang = "en-us",

        [Parameter(Mandatory = $false)]
        [string]$EditionName = 'AIO',

        [Parameter(Mandatory = $false)]
        [string[]]$SelectedEditions = @(),

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = '',

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

    if ($SelectedEditions -and $SelectedEditions.Count -gt 0) {
        $allowedPatterns = [System.Collections.Generic.List[string]]::new()
        foreach ($sel in $SelectedEditions) {
            if (-not [string]::IsNullOrWhiteSpace($sel)) {
                $ed = if (Get-Command Get-EditionInfo -ErrorAction SilentlyContinue) { Get-EditionInfo $sel } else { $null }
                if ($ed) {
                    if ($ed.Short) { $allowedPatterns.Add([regex]::Escape($ed.Short)) }
                    if ($ed.Base) { $allowedPatterns.Add([regex]::Escape($ed.Base)) }
                    if ($ed.Virtual) { $allowedPatterns.Add([regex]::Escape($ed.Virtual)) }
                }
                $allowedPatterns.Add([regex]::Escape($sel.ToString().Trim()))
            }
        }
        $unique = $allowedPatterns | Select-Object -Unique
        $rx = '(?i)[-_\.](' + ($unique -join '|') + ')(\.[^.]+$|[-_\.])'

        $wimFiles = @($wimFiles | Where-Object { $_.Name -match $rx })
        if (-not $wimFiles -or $wimFiles.Count -eq 0) {
            throw "No .wim or .esd files matching selected editions ($($SelectedEditions -join ', ')) found in '$WimDirectory'."
        }
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

    $wimlib = if (Get-Command Get-WimLibPath -ErrorAction SilentlyContinue) { Get-WimLibPath } else { $null }
    if ($wimlib) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "wimlib-imagex detected: $wimlib"
        } else {
            Write-Host "wimlib-imagex detected: $wimlib"
        }
    }

    $totalMerged = Merge-WindowsWimImages -WimFiles $sortedWimFiles -DestinationWimFile $mergedWim -WimLibPath $wimlib

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
        ConvertTo-WindowsEsd -SourcePath $mergedWim -DestinationPath $mergedEsd -ImageCount $totalMerged -WimLibPath $wimlib
        Remove-Item $mergedWim -Force
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "ESD conversion complete."
        } else {
            Write-Host "ESD conversion complete."
        }
    }

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
    if (-not $WindowsTargetName) {
        $WindowsTargetName = if ($buildNumber -and $buildNumber -ne "UnknownBuild" -and [int]($buildNumber -split '\.')[0] -lt 22000) { 'windows-10@22h2' } else { 'windows-11@26h2' }
    }

    $targetOS = if (Test-Path variable:global:targetOS) {
        $global:targetOS
    } elseif ($WindowsTargetName -match '(?i)win(dows)?[-_\s]?10' -or ($buildNumber -and $buildNumber -ne "UnknownBuild" -and [int]($buildNumber -split '\.')[0] -lt 22000)) {
        '10'
    } else {
        '11'
    }

    # 4. Integrate Source ISO / Base Media
    $resolvedSourceIso = Resolve-BaseMediaSource -SourceIsoDir $SourceIsoDir -SourceIso $SourceIso -SearchDir $WimDirectory

    if ($resolvedSourceIso) {
        if (Test-Path $resolvedSourceIso -PathType Container) {
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Using clean SourceIso directory from $resolvedSourceIso..."
            } else {
                Write-Host "Using clean SourceIso directory from $resolvedSourceIso..."
            }
            Copy-Item -Path "$resolvedSourceIso\*" -Destination $stagingDir -Recurse -Force
        } else {
            $osLabel = "Windows $targetOS"
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Extracting and patching clean $osLabel base media from $resolvedSourceIso..."
            } else {
                Write-Host "Extracting and patching clean $osLabel base media from $resolvedSourceIso..."
            }
            New-BaseIsoMedia -SourceIsoPath $resolvedSourceIso -OutputDirectory $stagingDir -TargetOS $targetOS -ProfileName $ProfileName
        }
    } else {
        throw "Neither SourceIso nor clean SourceIso directory could be found to stage the bootable media structure."
    }

    $tagVal = if ($ProfileName) {
        $ProfileName
    } else {
        ""
    }
    $isoFormat = if ($ProfileName -and (Get-Command Resolve-ProfileDir -ErrorAction SilentlyContinue) -and (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue) -and (Get-Command Get-ProfileIsoNameFormat -ErrorAction SilentlyContinue)) {
        $pDir = Resolve-ProfileDir -ProfileName $ProfileName -TargetOS $targetOS
        $pChain = if ($pDir) { Get-ProfileHierarchy -ProfileDir $pDir -TargetOS $targetOS } else { @() }
        Get-ProfileIsoNameFormat -ProfileChain $pChain
    } else { "" }
    $finalIsoName = Get-IsoName -TargetName $WindowsTargetName -EditionShort $EditionName -VersionBuild $verbuild -BuildNumber $buildNumber -Tag $tagVal -TargetOS $targetOS -Format $isoFormat

    $archTag = switch -Regex ($Architecture) {
        'arm64' { 'arm64' }
        default { 'x86_64' }
    }
    $buildTag = if ($buildNumber -and $buildNumber -ne "UnknownBuild") { $buildNumber } else { $verbuild }
    if ($Revision -and $buildTag -notmatch '\.') {
        $buildTag = "$buildTag.$Revision"
    }
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

    $aioTag = ""
    if ($Esd) { $aioTag += ".E" }
    if ($ProfileName -and ($ProfileName -notmatch '(?i)default$')) {
        $aioTag += ".$ProfileName"
    }

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

function Get-SetupPlatformFootprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcesDir
    )
    $footprint = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $cfgPath = Join-Path $SourcesDir "setupplatform.cfg"
    if (Test-Path $cfgPath) {
        $inFootprint = $false
        foreach ($line in (Get-Content -Path $cfgPath -ErrorAction SilentlyContinue)) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) {
                $sec = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
                $inFootprint = ($sec -match '^Footprint\.')
                continue
            }
            if ($inFootprint -and $trimmed -and -not $trimmed.StartsWith(';')) {
                $item = $trimmed.TrimEnd('\/').ToLowerInvariant()
                if ($item.Contains('\')) {
                    $base = [System.IO.Path]::GetFileName($item)
                    if ($base) { [void]$footprint.Add($base) }
                    $root = $item.Split('\')[0]
                    if ($root -and $root -ne '*-*') { [void]$footprint.Add($root) }
                } else {
                    [void]$footprint.Add($item)
                }
            }
        }
    }
    return $footprint
}

function Remove-IsoBloatItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$MediaDir,

        [Parameter(Mandatory = $false)]
        [string]$TargetOS = "",

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludedItems = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$Directories = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$Files = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$LanguageFiles = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$EfiFiles = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$BootFiles = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$FootprintExclusions = @()
    )
    if (-not (Test-Path $MediaDir)) { return }

    # 1. Strip non-Latin CJK boot fonts from boot\ and efi\
    foreach ($sub in @("boot", "efi\Microsoft\boot")) {
        $fontDir = Join-Path $MediaDir (Join-Path $sub "fonts")
        if (-not (Test-Path $fontDir)) { $fontDir = Join-Path $MediaDir $sub }
        if (Test-Path $fontDir) {
            Get-ChildItem -Path $fontDir -Filter "*.ttf" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -notmatch '^(segmono|segoe|wgl4)') {
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # 2. Strip specified EFI boot files (protect boot.stl and memtest.efi on Windows 11)
    $efiBootDir = Join-Path $MediaDir "efi\Microsoft\boot"
    if ((Test-Path $efiBootDir) -and $EfiFiles) {
        foreach ($f in $EfiFiles) {
            if ($TargetOS -eq '11' -and $f -match '(?i)boot\.stl|memtest') { continue }
            $p = Join-Path $efiBootDir $f
            if (Test-Path $p) {
                Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 2b. Strip specified legacy boot files from boot\ (only safe on Windows 10)
    $bootDir = Join-Path $MediaDir "boot"
    if ((Test-Path $bootDir) -and $BootFiles) {
        foreach ($f in $BootFiles) {
            if ($TargetOS -eq '11' -and $f -match '(?i)memtest|bootsect') { continue }
            $p = Join-Path $bootDir $f
            if (Test-Path $p) {
                Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 3. Strip bloat directories from sources\
    $sourcesDir = Join-Path $MediaDir "sources"
    if (Test-Path $sourcesDir) {
        # Discover and protect files, directories, and manifests required by SetupPlatform footprints.
        # SetupPlatform.dll verifies footprint sections in setupplatform.cfg (Basic, Servicing, ICB, Migration).
        # On Windows 11 Modern Setup, missing footprint items cause setup to fail with 0x80070032.
        # On Windows 10, footprint items are not protected so legacy bloat is thoroughly stripped.
        $protectedFootprint = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($ExcludedItems) {
            foreach ($ex in $ExcludedItems) {
                if ($ex) { [void]$protectedFootprint.Add($ex.Trim()) }
            }
        }

        if ($TargetOS -eq '11') {
            if ($FootprintExclusions) {
                foreach ($item in $FootprintExclusions) {
                    if ($item) { [void]$protectedFootprint.Add($item.Trim()) }
                }
            }

            $cfgFootprint = Get-SetupPlatformFootprint -SourcesDir $sourcesDir
            foreach ($item in $cfgFootprint) {
                [void]$protectedFootprint.Add($item)
            }
        }

        if ($Directories) {
            foreach ($d in $Directories) {
                if ($protectedFootprint.Contains($d) -or $protectedFootprint.Contains($d.ToLowerInvariant())) { continue }
                $p = Join-Path $sourcesDir $d
                if (Test-Path $p) {
                    Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # 4. Strip bloat/upgrade/migration files from sources\
        if ($Files) {
            foreach ($f in $Files) {
                if ($protectedFootprint.Contains($f) -or $protectedFootprint.Contains($f.ToLowerInvariant())) { continue }
                $p = Join-Path $sourcesDir $f
                if (Test-Path $p) {
                    Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # 5. Strip orphaned .mui and unneeded documentation files from language subdirectories in sources\
        if ($LanguageFiles) {
            Get-ChildItem -Path $sourcesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $langDir = $_.FullName
                foreach ($lf in $LanguageFiles) {
                    if ($protectedFootprint.Contains($lf) -or $protectedFootprint.Contains($lf.ToLowerInvariant())) { continue }
                    $lp = Join-Path $langDir $lf
                    if (Test-Path $lp) {
                        Remove-Item -Path $lp -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
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
            # Check for existing base ISO in BuildDirectory and unpack to ISOFOLDER
            $isoFile = Get-ChildItem -Path $BuildDirectory -Filter "*.iso" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '(?i)clean' } |
                Select-Object -First 1
            if ($isoFile) {
                $targetDir = Join-Path $BuildDirectory "ISOFOLDER"
                if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                    Write-CleanLine "Extracting base ISO $($isoFile.FullName) to $targetDir..."
                } else {
                    Write-Host "Extracting base ISO $($isoFile.FullName) to $targetDir..." -ForegroundColor Cyan
                }
                if (-not (Test-Path $targetDir)) {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                }

                $7zHelper = Join-Path $PSScriptRoot "..\7z\Get-7zPath.ps1"
                if (Test-Path $7zHelper) { . $7zHelper }
                $sevenZip = if (Get-Command Get-7zPath -ErrorAction SilentlyContinue) {
                    Get-7zPath
                } else {
                    (Get-Command 7z -ErrorAction SilentlyContinue).Source
                }

                if ($sevenZip -and (Test-Path $sevenZip)) {
                    & $sevenZip x -y $isoFile.FullName "-o$targetDir" | Out-Null
                } else {
                    $mount = Mount-DiskImage -ImagePath $isoFile.FullName -PassThru
                    try {
                        $vol = $mount | Get-Volume
                        if (-not $vol -or -not $vol.DriveLetter) { throw "Failed to mount ISO: $($isoFile.FullName)" }
                        $drive = "$($vol.DriveLetter):\"
                        Copy-Item -Path "$drive*" -Destination $targetDir -Recurse -Force
                    } finally {
                        Dismount-DiskImage -ImagePath $isoFile.FullName -ErrorAction SilentlyContinue | Out-Null
                    }
                }

                if ((Test-Path (Join-Path $targetDir "sources\install.wim")) -or (Test-Path (Join-Path $targetDir "sources\install.esd"))) {
                    return $targetDir
                }
            }

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

function Sync-ServicedImageToMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDistribution,
        [Parameter(Mandatory = $true)]
        [string]$TargetMedia
    )
    $servicedWim = Join-Path $SourceDistribution "sources\install.wim"
    $servicedEsd = Join-Path $SourceDistribution "sources\install.esd"
    $targetSources = Join-Path $TargetMedia "sources"
    if (-not (Test-Path $targetSources)) {
        New-Item -ItemType Directory -Path $targetSources -Force | Out-Null
    }
    if (Test-Path $servicedEsd) {
        Copy-Item -Path $servicedEsd -Destination (Join-Path $targetSources "install.esd") -Force
    } elseif (Test-Path $servicedWim) {
        Copy-Item -Path $servicedWim -Destination (Join-Path $targetSources "install.wim") -Force
    }

    # Ensure multi-index images display the edition selection screen in Windows Setup
    $finalImg = if (Test-Path (Join-Path $targetSources "install.esd")) {
        Join-Path $targetSources "install.esd"
    } elseif (Test-Path (Join-Path $targetSources "install.wim")) {
        Join-Path $targetSources "install.wim"
    } else { $null }

    if ($finalImg) {
        $imgCount = @(Get-WindowsImage -ImagePath $finalImg).Count
        if ($imgCount -gt 1) {
            $eiCfg = Join-Path $targetSources "ei.cfg"
            Set-Content -Path $eiCfg -Value "[Channel]`r`nRetail`r`n[VL]`r`n0`r`n" -Encoding ASCII -Force
        }
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
        [string]$FallbackVersion = "",
        [Parameter(Mandatory = $false)]
        [string]$Revision = ""
    )
    $archTag = switch -Regex ($Architecture) {
        'arm64' { 'arm64' }
        default { 'x86_64' }
    }
    $buildTag = if ($Build) { $Build } else { $FallbackVersion }
    if ($Revision -and $buildTag -notmatch '\.') {
        $buildTag = "$buildTag.$Revision"
    }
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
