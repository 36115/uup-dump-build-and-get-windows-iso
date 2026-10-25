<#
.SYNOPSIS
    UUP Dump caching, configuration change detection, and base media reuse engine.
.DESCRIPTION
    Provides automated caching of base Windows ISOs and distributions downloaded from UUP Dump.
    Detects when UUP Dump configurations have changed while explicitly excluding settings
    that do not affect the final ISO output (such as AutoExit, Cleanup, AutoStart, ForceDism,
    SkipISO packaging, and offline servicing customizations like SeparateDefenderEditions or Registry tweaks).
    Avoids redundant multi-gigabyte re-downloads when building repeatedly or modifying servicing tweaks.
#>

function Get-UupImpactingConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$BuildCfg,

        [Parameter(Mandatory = $false)]
        [psobject]$IsoInfo,

        [Parameter(Mandatory = $false)]
        [hashtable]$ConvertConfigOverrides = @{},

        [Parameter(Mandatory = $false)]
        [string]$VirtualEdition = "",

        [Parameter(Mandatory = $false)]
        [psobject[]]$ProfileChain = @(),

        [Parameter(Mandatory = $false)]
        [string]$RepoRoot = ""
    )

    $targetName = if ($BuildCfg.Target) { [string]$BuildCfg.Target } else { "" }
    $arch = if ($BuildCfg.Architecture) { [string]$BuildCfg.Architecture } else { "" }
    $edition = if ($BuildCfg.Edition) { [string]$BuildCfg.Edition } else { "" }
    $lang = if ($BuildCfg.Language) { [string]$BuildCfg.Language } else { "" }
    $revision = if ($BuildCfg.Revision) { [string]$BuildCfg.Revision } else { "" }
    $uupUuid = if ($IsoInfo -and $IsoInfo.PSObject.Properties['id'] -and $IsoInfo.id) {
        [string]$IsoInfo.id
    } elseif ($IsoInfo -and $IsoInfo.PSObject.Properties['uuid'] -and $IsoInfo.uuid) {
        [string]$IsoInfo.uuid
    } else {
        ""
    }

    # Core parameters that directly alter the source UUP packages or target Windows image bits
    $impacting = [ordered]@{
        Target         = $targetName.ToLowerInvariant().Trim()
        Architecture   = $arch.ToLowerInvariant().Trim()
        Edition        = $edition.ToLowerInvariant().Trim()
        Language       = $lang.ToLowerInvariant().Trim()
        Revision       = $revision.Trim()
        UupUuid        = $uupUuid.Trim()
        VirtualEdition = $VirtualEdition.Trim()
        NetFx3         = [bool]$BuildCfg.NetFx3
        Drivers        = [bool]$BuildCfg.Drivers
    }

    # -------------------------------------------------------------------------
    # ConvertConfig.ini filtering:
    # Keys that AFFECT final ISO output from UUP dump:
    #   - ResetBase     : Integrates updates and resets base component store
    #   - NetFx3        : Integrates offline .NET 3.5 cab payload
    #   - AddDrivers    : Injects drivers from Drivers/ into the base image
    #   - SkipEdge      : 0 = keep Edge, 1 = skip legacy Edge, 2 = skip Edge Chromium
    #   - SkipWinRE     : 1 = removes WinRE.wim from the image
    #   - StartVirtual  : 1 = enables virtual edition generation
    #   - vAutoEditions : Virtual editions to generate
    #   - vDeleteSource : 1 = removes base edition when building virtual edition
    #   - wim2esd       : 1 = compresses base image to install.esd instead of install.wim
    #   - CustomList    : 1 = filters inbox modern apps via CustomAppsList.txt
    #
    # Keys that DO NOT affect final ISO output from UUP dump (EXCLUDED):
    #   - AutoExit      : Only controls cmd prompt exit vs pause (UI only)
    #   - Cleanup       : Only controls deletion of temp conversion files (temp files only)
    #   - AutoStart     : Only controls automatic conversion start (UI only)
    #   - ForceDism     : Only controls tool selection (DISM vs wimlib; identical output)
    #   - RefKey        : Internal debug key for decryption
    #   - CheckUpdates  : Checks converter script updates online
    #   - SkipISO       : Only controls packaging into .iso vs folder; Windows content is identical
    #   - vSkipISO      : Mirrors SkipISO for virtual editions
    #   - vwim2esd      : Mirrors wim2esd
    # -------------------------------------------------------------------------
    $impactingConvertKeys = @(
        'ResetBase', 'AddDrivers', 'NetFx3', 'SkipEdge', 'SkipWinRE',
        'StartVirtual', 'vAutoEditions', 'vDeleteSource', 'wim2esd', 'CustomList'
    )

    $filteredConvert = [ordered]@{}
    if ($ConvertConfigOverrides) {
        foreach ($k in ($ConvertConfigOverrides.Keys | Sort-Object)) {
            $keyStr = $k.ToString()
            if ($impactingConvertKeys -contains $keyStr) {
                $filteredConvert[$keyStr] = [string]$ConvertConfigOverrides[$k]
            }
        }
    }
    $impacting['ConvertConfig'] = $filteredConvert

    # CustomAppsList / EnabledApps tracking (if store apps are filtered by profile)
    $enabledApps = if ($ProfileChain -and (Get-Command Get-ProfileEnabledApps -ErrorAction SilentlyContinue)) {
        Get-ProfileEnabledApps -ProfileChain $ProfileChain
    } else {
        @()
    }
    if ($enabledApps -and $enabledApps.Count -gt 0) {
        $sortedApps = @($enabledApps | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Sort-Object -Unique)
        $impacting['EnabledApps'] = $sortedApps
    } else {
        $impacting['EnabledApps'] = @()
    }

    return $impacting
}

function Get-UupConfigHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigInfo
    )

    $json = $ConfigInfo | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $hasher.ComputeHash($bytes)
    $hashStr = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
    return $hashStr.Substring(0, 16)
}

function Get-UupCacheDiffReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheDir,

        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigInfo
    )

    if (-not (Test-Path $CacheDir)) { return "" }

    $targetSafe = ($ConfigInfo.Target -replace '[^\w\.-]', '_')
    $manifestFiles = Get-ChildItem -Path $CacheDir -Filter "*.manifest.json" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*${targetSafe}*" } |
        Sort-Object LastWriteTime -Descending

    if (-not $manifestFiles -or $manifestFiles.Count -eq 0) { return "" }

    try {
        $prevManifest = Get-Content -Path $manifestFiles[0].FullName -Raw | ConvertFrom-Json
        $prevConfig = $prevManifest.configInfo
        if (-not $prevConfig) { return "" }

        $diffs = [System.Collections.Generic.List[string]]::new()

        if ($prevConfig.UupUuid -and $ConfigInfo.UupUuid -and $prevConfig.UupUuid -ne $ConfigInfo.UupUuid) {
            $diffs.Add("UUP build UUID changed ($($prevConfig.UupUuid) -> $($ConfigInfo.UupUuid))")
        }
        if ($prevConfig.Architecture -ne $ConfigInfo.Architecture) {
            $diffs.Add("Architecture changed ($($prevConfig.Architecture) -> $($ConfigInfo.Architecture))")
        }
        if ($prevConfig.Edition -ne $ConfigInfo.Edition) {
            $diffs.Add("Edition changed ($($prevConfig.Edition) -> $($ConfigInfo.Edition))")
        }
        if ($prevConfig.Language -ne $ConfigInfo.Language) {
            $diffs.Add("Language changed ($($prevConfig.Language) -> $($ConfigInfo.Language))")
        }
        if ($prevConfig.NetFx3 -ne $ConfigInfo.NetFx3) {
            $diffs.Add("NetFx3 changed ($($prevConfig.NetFx3) -> $($ConfigInfo.NetFx3))")
        }
        if ($prevConfig.Drivers -ne $ConfigInfo.Drivers) {
            $diffs.Add("Drivers changed ($($prevConfig.Drivers) -> $($ConfigInfo.Drivers))")
        }
        if ($prevConfig.VirtualEdition -ne $ConfigInfo.VirtualEdition) {
            $diffs.Add("VirtualEdition changed ($($prevConfig.VirtualEdition) -> $($ConfigInfo.VirtualEdition))")
        }

        # Check ConvertConfig differences
        if ($prevConfig.ConvertConfig -or $ConfigInfo.ConvertConfig) {
            $prevCC = if ($prevConfig.ConvertConfig) { $prevConfig.ConvertConfig } else { $null }
            $currCC = if ($ConfigInfo.ConvertConfig) { $ConfigInfo.ConvertConfig } else { $null }
            $prevKeys = if ($prevCC) { @($prevCC.PSObject.Properties.Name) } else { @() }
            $currKeys = if ($currCC) { @($currCC.Keys) } else { @() }
            $allKeys = @($prevKeys + $currKeys) | Select-Object -Unique
            foreach ($k in $allKeys) {
                $pv = if ($prevCC -and $prevCC.PSObject.Properties[$k]) { $prevCC.$k } else { $null }
                $cv = if ($currCC -and $currCC.Contains($k)) { $currCC[$k] } else { $null }
                if ($pv -ne $cv) {
                    $diffs.Add("ConvertConfig.$k changed ($pv -> $cv)")
                }
            }
        }

        if ($diffs.Count -gt 0) {
            return ($diffs -join ", ")
        }
    } catch {
        return ""
    }

    return ""
}

function Find-CachedUupMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheDir,

        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigInfo
    )

    if (-not (Test-Path $CacheDir)) {
        return $null
    }

    $hash = Get-UupConfigHash -ConfigInfo $ConfigInfo

    $manifestFiles = Get-ChildItem -Path $CacheDir -Filter "*.manifest.json" -File -ErrorAction SilentlyContinue
    foreach ($mFile in $manifestFiles) {
        try {
            $manifest = Get-Content -Path $mFile.FullName -Raw | ConvertFrom-Json
            if ($manifest.configHash -eq $hash) {
                $mediaPath = $manifest.mediaPath
                if (-not [System.IO.Path]::IsPathRooted($mediaPath)) {
                    $mediaPath = Join-Path $CacheDir $mediaPath
                }

                if (Test-Path $mediaPath) {
                    $isIso = -not (Test-Path $mediaPath -PathType Container)
                    if ($isIso) {
                        $item = Get-Item $mediaPath
                        if ($item.Length -gt 100MB) {
                            return [PSCustomObject]@{
                                IsValid      = $true
                                Path         = $mediaPath
                                Type         = "Iso"
                                ManifestPath = $mFile.FullName
                                Manifest     = $manifest
                                ConfigHash   = $hash
                            }
                        }
                    } else {
                        $hasWim = (Test-Path (Join-Path $mediaPath "sources\install.wim")) -or
                            (Test-Path (Join-Path $mediaPath "sources\install.esd"))
                        if ($hasWim) {
                            return [PSCustomObject]@{
                                IsValid      = $true
                                Path         = $mediaPath
                                Type         = "Directory"
                                ManifestPath = $mFile.FullName
                                Manifest     = $manifest
                                ConfigHash   = $hash
                            }
                        }
                    }
                }
            }
        } catch {
            Write-Warning "[UUP Cache] Error reading manifest '$($mFile.FullName)': $_"
        }
    }

    return $null
}

function Save-CachedUupMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildDirectory,

        [Parameter(Mandatory = $true)]
        [string]$CacheDir,

        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigInfo,

        [Parameter(Mandatory = $false)]
        [string]$RepoRoot = ""
    )

    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    $hash = Get-UupConfigHash -ConfigInfo $ConfigInfo
    $targetSafe = ($ConfigInfo.Target -replace '[^\w\.-]', '_')
    $archSafe = $ConfigInfo.Architecture
    $edSafe = $ConfigInfo.Edition
    $langSafe = $ConfigInfo.Language

    $basePrefix = "BaseIso_${targetSafe}_${edSafe}_${archSafe}_${langSafe}_${hash}"

    # 1. Check for standalone base ISO file generated by UUP dump in $BuildDirectory
    $isoFiles = Get-ChildItem -Path $BuildDirectory -Filter "*.iso" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '-Lite-' -and $_.Name -notmatch '(?i)debloat' } |
        Sort-Object Length -Descending

    $savedRelativePath = $null
    $mediaType = $null

    if ($isoFiles -and $isoFiles.Count -gt 0 -and $isoFiles[0].Length -gt 100MB) {
        $sourceIso = $isoFiles[0]
        $destIso = Join-Path $CacheDir "$basePrefix.iso"
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "[UUP Cache] Caching base Windows ISO to $destIso..."
        } else {
            Write-Host "[UUP Cache] Caching base Windows ISO to $destIso..." -ForegroundColor Green
        }
        Copy-Item -Path $sourceIso.FullName -Destination $destIso -Force
        $savedRelativePath = "$basePrefix.iso"
        $mediaType = "Iso"
    } else {
        # 2. Check for ISOFOLDER or distribution folder
        $dist = if (Get-Command Resolve-DistributionDirectory -ErrorAction SilentlyContinue) {
            try { Resolve-DistributionDirectory -BuildDirectory $BuildDirectory } catch { $null }
        } else { $null }

        if ($dist -and (Test-Path $dist)) {
            $destDir = Join-Path $CacheDir "$basePrefix"
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "[UUP Cache] Caching base Windows distribution to $destDir..."
            } else {
                Write-Host "[UUP Cache] Caching base Windows distribution to $destDir..." -ForegroundColor Green
            }
            if (Test-Path $destDir) { Remove-Item -Path $destDir -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-Item -Path $dist -Destination $destDir -Recurse -Force
            $savedRelativePath = "$basePrefix"
            $mediaType = "Directory"
        }
    }

    if ($savedRelativePath) {
        $manifest = [ordered]@{
            targetSafe   = $targetSafe
            configHash   = $hash
            mediaPath    = $savedRelativePath
            mediaType    = $mediaType
            configInfo   = $ConfigInfo
            cachedAt     = (Get-Date).ToString("o")
        }
        $manifestPath = Join-Path $CacheDir "$basePrefix.manifest.json"
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding utf8
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "[UUP Cache] Saved cache manifest to $manifestPath"
        } else {
            Write-Host "[UUP Cache] Saved cache manifest to $manifestPath" -ForegroundColor Green
        }
    } else {
        Write-Warning "[UUP Cache] No base ISO or distribution found to cache in $BuildDirectory"
    }
}

function Restore-CachedUupMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$CachedMedia,

        [Parameter(Mandatory = $true)]
        [string]$BuildDirectory,

        [Parameter(Mandatory = $false)]
        [bool]$NeedsServicing = $false,

        [Parameter(Mandatory = $false)]
        [bool]$WimOnly = $false,

        [Parameter(Mandatory = $false)]
        [string]$RepoRoot = ""
    )

    if (Test-Path $BuildDirectory) {
        Remove-Item -Path $BuildDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null

    $mediaPath = $CachedMedia.Path
    if ($CachedMedia.Type -eq "Iso") {
        # Copy base ISO into build directory for vanilla pass-through
        $stagedIso = Join-Path $BuildDirectory (Split-Path $mediaPath -Leaf)
        Copy-Item -Path $mediaPath -Destination $stagedIso -Force

        # When offline servicing or wimOnly is needed, extract the distribution directory
        if ($NeedsServicing -or $WimOnly) {
            $distDir = Join-Path $BuildDirectory "ISOFOLDER"
            New-Item -ItemType Directory -Path $distDir -Force | Out-Null

            $sevenZip = if (Get-Command Get-7zPath -ErrorAction SilentlyContinue) { Get-7zPath } else { $null }
            if ($sevenZip -and (Test-Path $sevenZip)) {
                if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                    Write-CleanLine "Extracting cached base ISO with 7z to $distDir..."
                } else {
                    Write-Host "Extracting cached base ISO with 7z to $distDir..." -ForegroundColor Cyan
                }
                & $sevenZip x -y $mediaPath "-o$distDir" | Out-Null
            } else {
                $mount = Mount-DiskImage -ImagePath $mediaPath -PassThru
                try {
                    $vol = $mount | Get-Volume
                    if (-not $vol -or -not $vol.DriveLetter) { throw "Failed to mount cached base ISO: $mediaPath" }
                    $drive = "$($vol.DriveLetter):\"
                    Copy-Item -Path "$drive*" -Destination $distDir -Recurse -Force
                } finally {
                    Dismount-DiskImage -ImagePath $mediaPath -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    } else {
        # Distribution folder
        $distDir = Join-Path $BuildDirectory "ISOFOLDER"
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Staging cached base distribution to $distDir..."
        } else {
            Write-Host "Staging cached base distribution to $distDir..." -ForegroundColor Cyan
        }
        Copy-Item -Path $mediaPath -Destination $distDir -Recurse -Force
    }
}

function Get-UupPackageCacheDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestDir,

        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigInfo
    )

    $targetSafe = ($ConfigInfo.Target -replace '[^\w\.-]', '_')
    $archSafe = $ConfigInfo.Architecture
    $edSafe = $ConfigInfo.Edition
    $langSafe = $ConfigInfo.Language
    $uupUuid = if ($ConfigInfo.UupUuid) { $ConfigInfo.UupUuid } else { "default" }

    $pkgKey = "${targetSafe}_${edSafe}_${archSafe}_${langSafe}_${uupUuid}"
    return Join-Path $DestDir "UupPackages\$pkgKey"
}

function Disconnect-UupPackageCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildDirectory
    )

    $uupDir = Join-Path $BuildDirectory "uup"
    if (Test-Path $uupDir) {
        try {
            $item = Get-Item -LiteralPath $uupDir -Force -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                cmd /c rmdir "$uupDir" 2>&1 | Out-Null
            }
        } catch {
            cmd /c rmdir "$uupDir" 2>&1 | Out-Null
        }
    }
}

function Initialize-UupPackageCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildDirectory,

        [Parameter(Mandatory = $true)]
        [string]$PackageCacheDir,

        [Parameter(Mandatory = $false)]
        [bool]$Force = $false
    )

    if ($Force -and (Test-Path $PackageCacheDir)) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "[UUP Cache] Force download: Purging raw package cache at $PackageCacheDir..."
        } else {
            Write-Host "[UUP Cache] Force download: Purging raw package cache at $PackageCacheDir..." -ForegroundColor Yellow
        }
        Remove-Item -Path $PackageCacheDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }

    if (-not (Test-Path $PackageCacheDir)) {
        New-Item -ItemType Directory -Path $PackageCacheDir -Force | Out-Null
    }

    $existingPkgs = Get-ChildItem -Path $PackageCacheDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.cab', '.esd' }
    $pkgCount = if ($existingPkgs) { $existingPkgs.Count } else { 0 }

    if ($pkgCount -gt 0) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "[UUP Cache] Found $pkgCount cached raw UUP packages in $PackageCacheDir. Aria2 will verify existing files without re-downloading."
        } else {
            Write-Host "[UUP Cache] Found $pkgCount cached raw UUP packages in $PackageCacheDir. Aria2 will verify existing files without re-downloading." -ForegroundColor Green
        }
    }

    $uupDir = Join-Path $BuildDirectory "uup"
    Disconnect-UupPackageCache -BuildDirectory $BuildDirectory

    if (Test-Path $uupDir) {
        Remove-Item -Path $uupDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # Try creating directory junction for instant zero-copy access
    $isLinked = $false
    try {
        $null = cmd /c mklink /J "$uupDir" "$PackageCacheDir" 2>&1
        if (Test-Path $uupDir) {
            $isLinked = $true
        }
    } catch {
        $isLinked = $false
    }

    if ($isLinked) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "[UUP Cache] Linked build UUP folder to raw package cache (Junction)."
        }
    } else {
        # Fallback to copy if junction is not supported
        New-Item -ItemType Directory -Path $uupDir -Force | Out-Null
        if ($pkgCount -gt 0) {
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "[UUP Cache] Staging $pkgCount cached packages to $uupDir..."
            }
            Copy-Item -Path "$PackageCacheDir\*" -Destination $uupDir -Force -ErrorAction SilentlyContinue
        }
    }

    return [PSCustomObject]@{
        PackageCacheDir = $PackageCacheDir
        UupDir          = $uupDir
        IsLinked        = $isLinked
        PackageCount    = $pkgCount
    }
}

function Sync-UupPackageCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildDirectory,

        [Parameter(Mandatory = $true)]
        [string]$PackageCacheDir
    )

    $uupDir = Join-Path $BuildDirectory "uup"
    if (-not (Test-Path $uupDir)) { return }

    # If it's already a junction, files were downloaded directly into $PackageCacheDir
    $item = Get-Item -LiteralPath $uupDir -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return
    }

    # If it was a normal directory (fallback copy mode), copy newly downloaded .cab/.esd files into cache
    if (-not (Test-Path $PackageCacheDir)) {
        New-Item -ItemType Directory -Path $PackageCacheDir -Force | Out-Null
    }
    $downloaded = Get-ChildItem -Path $uupDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.cab', '.esd' }
    foreach ($file in $downloaded) {
        $dest = Join-Path $PackageCacheDir $file.Name
        if (-not (Test-Path $dest)) {
            Copy-Item -Path $file.FullName -Destination $dest -Force
        }
    }
}
