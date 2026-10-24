<#
.SYNOPSIS
    Windows image servicing orchestration utilities.
.DESCRIPTION
    Provides functions to mount, service, and dismount Windows WIM image indices
    with resilient retry loops, garbage collection, and Defender exclusions.
#>

function Mount-WindowsImageIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $true)]
        [int]$Index,
        [Parameter(Mandatory = $true)]
        [string]$MountDir
    )
    if (-not (Test-Path $MountDir)) {
        New-Item -ItemType Directory -Path $MountDir -Force | Out-Null
    }
    Add-MpPreference -ExclusionPath $MountDir -ErrorAction SilentlyContinue
    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Mounting $ImagePath index $Index to $MountDir..."
    }
    & dism.exe /Mount-Wim /WimFile:$ImagePath /Index:$Index /MountDir:$MountDir
    if ($LASTEXITCODE -ne 0) {
        throw "dism /Mount-Wim failed on index $Index with exit code $LASTEXITCODE"
    }
}

function Dismount-WindowsImageIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountDir,
        [switch]$Commit,
        [switch]$Discard,
        [int]$MaxAttempts = 5
    )
    $repoRoot = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) { Get-RepoRoot } else { (Get-Location).Path }
    Set-Location $repoRoot

    if ($Commit) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Unmounting and committing image at $MountDir..."
        }
        $unmountSuccess = $false
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            & dism.exe /Unmount-Wim /MountDir:$MountDir /Commit
            if ($LASTEXITCODE -eq 0) {
                $unmountSuccess = $true
                break
            }
            Write-Warning "dism /Unmount-Wim /Commit attempt $attempt failed with exit code $LASTEXITCODE. Retrying in $($attempt * 3) seconds..."
            Start-Sleep -Seconds ($attempt * 3)
        }
        if (-not $unmountSuccess) {
            throw "dism /Unmount-Wim /Commit failed after $MaxAttempts attempts with exit code $LASTEXITCODE"
        }
    } else {
        for ($discardAttempt = 1; $discardAttempt -le 3; $discardAttempt++) {
            & dism.exe /Unmount-Wim /MountDir:$MountDir /Discard *> $null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2
        }
    }

    Remove-MpPreference -ExclusionPath $MountDir -ErrorAction SilentlyContinue
    if (Test-Path $MountDir) {
        Remove-Item $MountDir -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Invoke-ImageServicing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$installWim = "",
        [Parameter(Mandatory = $false)]
        [string]$distDir = "",
        [switch]$esd,
        [switch]$wimOnly,
        [string]$wimlib = "",
        [string]$profileName = "",
        [string]$RepoRoot = "",
        [switch]$separateDefenderEditions,

        # Legacy parameters for backward compatibility with 2239d3f/5cd021a
        [string]$buildDirectory = "",
        [string]$title = "",
        [string]$finalIsoName = "",
        [string]$architecture = "x64"
    )
    if (-not $RepoRoot) {
        $RepoRoot = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) { Get-RepoRoot } else { (Get-Location).Path }
    }

    # If invoked via legacy buildDirectory signature
    if ($buildDirectory -and -not $distDir) {
        $distDir = if (Get-Command Resolve-DistributionDirectory -ErrorAction SilentlyContinue) {
            Resolve-DistributionDirectory -BuildDirectory $buildDirectory
        } else {
            Join-Path $buildDirectory "ISOFOLDER"
        }
    }
    if (-not $installWim -and $distDir) {
        $installWim = Join-Path $distDir "sources\install.wim"
        if (-not (Test-Path $installWim)) {
            $installEsd = Join-Path $distDir "sources\install.esd"
            if (Test-Path $installEsd) {
                if (Get-Command ConvertTo-WindowsWim -ErrorAction SilentlyContinue) {
                    ConvertTo-WindowsWim -SourcePath $installEsd -DestinationPath $installWim -WimLibPath $wimlib
                } else {
                    & dism.exe /Export-Image /SourceImageFile:$installEsd /SourceIndex:1 /DestinationImageFile:$installWim
                }
                Remove-Item $installEsd -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $wimImages = @(Get-WindowsImage -ImagePath $installWim)
    $imageCount = $wimImages.Count
    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Found $imageCount image index(es) in $installWim to service."
    }

    $servicingScript = Join-Path $RepoRoot "Utils\Servicing\Invoke-Servicing.ps1"
    $nsudoHelper = Join-Path $RepoRoot "Utils\NSudo\Invoke-NSudo.ps1"
    if (-not (Test-Path $nsudoHelper)) { $nsudoHelper = Join-Path $RepoRoot "Utils\NSudo\NSudo.ps1" }
    if (Test-Path $nsudoHelper) { . $nsudoHelper }
    $nsudo = if (Get-Command Get-NSudoPath -ErrorAction SilentlyContinue) { Get-NSudoPath } else { "" }

    for ($idx = 1; $idx -le $imageCount; $idx++) {
        $imgObj = $wimImages | Where-Object { $_.ImageIndex -eq $idx }
        $currentImageName = if ($imgObj) { $imgObj.ImageName } else { "Index $idx" }
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "=== Servicing index $idx of ${imageCount}: $currentImageName ==="
        }

        $targetNameForOs = if ($currentImageName -and $currentImageName -ne "Index $idx") { $currentImageName } elseif ($title) { $title } else { "Win11" }
        $osFamily = if ($targetNameForOs -match '(?i)win(dows)?[-_\s]?10') { 'Win10' } else { 'Win11' }
        $targetProfile = if ($profileName) { $profileName } else { "$osFamily/Default" }
        $profileDir = if (Get-Command Resolve-ProfileDir -ErrorAction SilentlyContinue) {
            Resolve-ProfileDir -ProfileName $targetProfile -OsFamily $osFamily -RepoRoot $RepoRoot
        } else {
            Join-Path $RepoRoot "Config\$targetProfile"
        }

        $profileChain = if ($profileDir -and (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue)) {
            Get-ProfileHierarchy -ProfileDir $profileDir -RepoRoot $RepoRoot -OsFamily $osFamily
        } else {
            @()
        }

        $isSeparateDefender = $separateDefenderEditions.IsPresent
        if (-not $isSeparateDefender -and $profileChain -and (Get-Command Get-ProfileSeparateDefenderEditions -ErrorAction SilentlyContinue)) {
            $isSeparateDefender = Get-ProfileSeparateDefenderEditions -ProfileChain $profileChain
        }

        $mountDir = Join-Path $env:TEMP "Mount_Servicing_$([System.IO.Path]::GetRandomFileName())"
        Mount-WindowsImageIndex -ImagePath $installWim -Index $idx -MountDir $mountDir
        $isMounted = $true

        try {
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Running Invoke-Servicing.ps1 with profile '$targetProfile' against mounted image index $idx..."
            }
            & powershell -ExecutionPolicy Bypass -File $servicingScript `
                -MountDir $mountDir `
                -ProfileName $targetProfile `
                -ProfileDir $profileDir `
                -NSudoPath $nsudo
            if ($LASTEXITCODE -ne 0) { throw "Invoke-Servicing.ps1 failed on index $idx with exit code $LASTEXITCODE" }

            Dismount-WindowsImageIndex -MountDir $mountDir -Commit
            $isMounted = $false
        }
        finally {
            if ($isMounted) {
                Dismount-WindowsImageIndex -MountDir $mountDir -Discard
            }
        }

        if ($isSeparateDefender) {
            $defName = if ($currentImageName -match '\(Defender\)') { $currentImageName } else { "$currentImageName (Defender)" }
            $defDesc = "$currentImageName with Windows Defender"
            $noDefName = if ($currentImageName -match '\(Defender\)') { $currentImageName -replace '\(Defender\)', '(No Defender)' } else { "$currentImageName (No Defender)" }
            $noDefDesc = "$currentImageName without Windows Defender"

            if (Get-Command Set-WimImageInfo -ErrorAction SilentlyContinue) {
                Set-WimImageInfo -ImagePath $installWim -Index $idx -NewName $defName -NewDescription $defDesc -WimLibPath $wimlib
            }

            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Cloning index $idx ($defName) -> $noDefName for Separate-Defender ISO..."
            } else {
                Write-Host "Cloning index $idx ($defName) -> $noDefName for Separate-Defender ISO..."
            }

            if (Get-Command Clone-WindowsWimImage -ErrorAction SilentlyContinue) {
                Clone-WindowsWimImage -ImagePath $installWim -SourceIndex $idx -DestinationName $noDefName -DestinationDescription $noDefDesc -WimLibPath $wimlib
            } else {
                & $wimlib export $installWim $idx $installWim "$noDefName" "$noDefDesc" --check
            }

            $noDefIdx = @(Get-WindowsImage -ImagePath $installWim).Count
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Servicing cloned index $noDefIdx to purge Windows Defender & SecHealthUI..."
            } else {
                Write-Host "Servicing cloned index $noDefIdx to purge Windows Defender & SecHealthUI..."
            }

            $mountDirNoDef = Join-Path $env:TEMP "Mount_Servicing_NoDef_$([System.IO.Path]::GetRandomFileName())"
            Mount-WindowsImageIndex -ImagePath $installWim -Index $noDefIdx -MountDir $mountDirNoDef
            $isMountedNoDef = $true
            try {
                & powershell -ExecutionPolicy Bypass -File $servicingScript `
                    -MountDir $mountDirNoDef `
                    -ProfileName $targetProfile `
                    -ProfileDir $profileDir `
                    -NSudoPath $nsudo `
                    -ForceRemoveDefender

                if ($LASTEXITCODE -ne 0) { throw "Servicing cloned index $noDefIdx failed with exit code $LASTEXITCODE" }
                Dismount-WindowsImageIndex -MountDir $mountDirNoDef -Commit
                $isMountedNoDef = $false
            } finally {
                if ($isMountedNoDef) {
                    Dismount-WindowsImageIndex -MountDir $mountDirNoDef -Discard
                }
            }

            if (Get-Command Set-WimImageInfo -ErrorAction SilentlyContinue) {
                Set-WimImageInfo -ImagePath $installWim -Index $noDefIdx -NewName $noDefName -NewDescription $noDefDesc -WimLibPath $wimlib
            }
        }
    }

    $finalImageCount = @(Get-WindowsImage -ImagePath $installWim).Count
    if (-not $esd -or $wimOnly) {
        if (Get-Command Optimize-WindowsWim -ErrorAction SilentlyContinue) {
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Compacting serviced install.wim ($finalImageCount index(es)) to purge orphaned streams..."
            }
            Optimize-WindowsWim -ImagePath $installWim -ImageCount $finalImageCount -WimLibPath $wimlib
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Compaction complete. New install.wim size: $((Get-Item $installWim).Length) bytes"
            }
        }
    }

    # Legacy fallback: if called with buildDirectory & finalIsoName/title, handle ISO creation
    if ($buildDirectory -and ($finalIsoName -or $title)) {
        if ($esd) {
            if (Get-Command ConvertTo-DistributionEsd -ErrorAction SilentlyContinue) {
                ConvertTo-DistributionEsd -DistributionDirectory $distDir -InstallWim $installWim -WimLibPath $wimlib
            } else {
                & dism.exe /Export-Image /SourceImageFile:$installWim /SourceIndex:1 /DestinationImageFile:(Join-Path $distDir "sources\install.esd") /Compress:recovery
                Remove-Item $installWim -Force -ErrorAction SilentlyContinue
            }
        }
        $isoLabel = if ($finalIsoName) { $finalIsoName } else { $title }
        $isoDest = Join-Path $buildDirectory "$isoLabel.iso"
        if (Get-Command New-IsoImage -ErrorAction SilentlyContinue) {
            New-IsoImage -SourceDir $distDir -DestinationIsoPath $isoDest -VolumeLabel $isoLabel -Architecture $architecture -SearchDir $buildDirectory
        }
    }
}
