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
        [ValidateSet('Both', 'Remove', 'Keep', '')][string]$defenderBuild = "",
        [switch]$separateDefenderEditions
    )
    if (-not $RepoRoot) {
        $RepoRoot = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) { Get-RepoRoot } else { (Get-Location).Path }
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
    if (Test-Path $nsudoHelper) { . $nsudoHelper }
    $nsudo = if (Get-Command Get-NSudoPath -ErrorAction SilentlyContinue) { Get-NSudoPath } else { "" }

    $wimlibHelper = Join-Path $RepoRoot "Utils\WimLib\Invoke-WimLib.ps1"
    if (Test-Path $wimlibHelper) { . $wimlibHelper }
    if (-not $wimlib -and (Get-Command Get-WimLibPath -ErrorAction SilentlyContinue)) {
        $wimlib = Get-WimLibPath
    }

    $profileHelper = Join-Path $RepoRoot "Utils\Common\Resolve-Profile.ps1"
    if (Test-Path $profileHelper) { . $profileHelper }

    for ($idx = 1; $idx -le $imageCount; $idx++) {
        $imgObj = $wimImages | Where-Object { $_.ImageIndex -eq $idx }
        $currentImageName = if ($imgObj) { $imgObj.ImageName } else { "Index $idx" }
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "=== Servicing index $idx of ${imageCount}: $currentImageName ==="
        }

        $imgBuild = 0
        if ($imgObj -and $imgObj.PSObject.Properties['Version'] -and $imgObj.Version) {
            $parts = $imgObj.Version -split '\.'
            if ($parts.Count -ge 3 -and $parts[2] -match '^\d+$') {
                $imgBuild = [int]$parts[2]
            }
        }

        $targetNameForOs = if ($currentImageName -and $currentImageName -ne "Index $idx") { $currentImageName }  else { "" }
        $targetOS = if (Test-Path variable:global:targetOS) {
            $global:targetOS
        } elseif ($imgBuild -gt 0) {
            if ($imgBuild -lt 22000) { '10' } else { '11' }
        } elseif ($targetNameForOs -match '(?i)win(dows)?[-_\s]?10') {
            '10'
        } else {
            '11'
        }
        $targetOS = ($targetOS -replace '\D', '')
        $global:targetOS = $targetOS
        $targetProfile = if ($profileName) { $profileName } else { "Default" }
        $profileDir = if (Get-Command Resolve-ProfileDir -ErrorAction SilentlyContinue) {
            Resolve-ProfileDir -ProfileName $targetProfile -TargetOS $targetOS -RepoRoot $RepoRoot
        } else {
            Join-Path $RepoRoot "Config\$targetProfile"
        }

        $profileChain = if ($profileDir -and (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue)) {
            Get-ProfileHierarchy -ProfileDir $profileDir -RepoRoot $RepoRoot -TargetOS $targetOS
        } else {
            @()
        }

        $mode = if ($PSBoundParameters.ContainsKey('defenderBuild') -and $defenderBuild) { $defenderBuild } else { $null }
        $isSeparate = if ($mode) { ($mode -match '(?i)^(both|dual)$') } else { $separateDefenderEditions.IsPresent }
        if (-not $isSeparate -and -not $mode -and $profileChain -and (Get-Command Get-ProfileSeparateDefenderEditions -ErrorAction SilentlyContinue)) {
            $isSeparate = Get-ProfileSeparateDefenderEditions -ProfileChain $profileChain
        }

        $singleRemoveDefender = if ($mode) {
            ($mode -match '(?i)^(both|dual|remove|true)$')
        } elseif ($profileChain -and (Get-Command Get-ProfileRemoveDefender -ErrorAction SilentlyContinue)) {
            Get-ProfileRemoveDefender -ProfileChain $profileChain
        } else {
            $false
        }

        if ($isSeparate) {
            $baseImageName = ($currentImageName -replace '\s*\((?:No\s+|With\s+)?Defender\)\s*', '').Trim()
            $noDefName = $baseImageName
            $noDefDesc = "$baseImageName without Windows Defender"
            $withDefName = "$baseImageName (With Defender)"
            $withDefDesc = "$baseImageName with Windows Defender"

            # Pass 1: Service index $idx with Defender preserved
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "=== Pass 1/2: Servicing $withDefName (Defender Preserved) ==="
            } else {
                Write-Host "=== Pass 1/2: Servicing $withDefName (Defender Preserved) ==="
            }

            $mountDir = Join-Path $env:TEMP "Mount_Servicing_WithDef_$([System.IO.Path]::GetRandomFileName())"
            Mount-WindowsImageIndex -ImagePath $installWim -Index $idx -MountDir $mountDir
            $isMounted = $true

            try {
                & powershell -ExecutionPolicy Bypass -File $servicingScript `
                    -MountDir $mountDir `
                    -ProfileName $targetProfile `
                    -ProfileDir $profileDir `
                    -NSudoPath $nsudo `
                    -RemoveDefender:$false `
                    -SkipCleanup `
                    -TargetOS $targetOS
                if ($LASTEXITCODE -ne 0) { throw "Pass 1 servicing failed on index $idx with exit code $LASTEXITCODE" }

                Dismount-WindowsImageIndex -MountDir $mountDir -Commit
                $isMounted = $false
            }
            finally {
                if ($isMounted) {
                    Dismount-WindowsImageIndex -MountDir $mountDir -Discard
                }
            }

            # Clone index $idx to Index 2 as the 'With Defender' edition
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "Cloning index $idx -> $withDefName for Separate-Defender ISO..."
            } else {
                Write-Host "Cloning index $idx -> $withDefName for Separate-Defender ISO..."
            }

            if (Get-Command Clone-WindowsWimImage -ErrorAction SilentlyContinue) {
                Clone-WindowsWimImage -ImagePath $installWim -SourceIndex $idx -DestinationName $withDefName -DestinationDescription $withDefDesc -WimLibPath $wimlib
            } else {
                & dism.exe /Export-Image /SourceImageFile:$installWim /SourceIndex:$idx /DestinationImageFile:$installWim /DestinationName:"$withDefName"
            }

            $withDefIdx = @(Get-WindowsImage -ImagePath $installWim).Count
            if (Get-Command Set-WimImageInfo -ErrorAction SilentlyContinue) {
                Set-WimImageInfo -ImagePath $installWim -Index $withDefIdx -NewName $withDefName -NewDescription $withDefDesc -WimLibPath $wimlib
            }

            # Pass 2: Mount index $idx (Index 1) and service with Defender purged
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "=== Pass 2/2: Servicing $noDefName (Defender Purged) ==="
            } else {
                Write-Host "=== Pass 2/2: Servicing $noDefName (Defender Purged) ==="
            }

            $mountDirNoDef = Join-Path $env:TEMP "Mount_Servicing_NoDef_$([System.IO.Path]::GetRandomFileName())"
            Mount-WindowsImageIndex -ImagePath $installWim -Index $idx -MountDir $mountDirNoDef
            $isMountedNoDef = $true
            try {
                & powershell -ExecutionPolicy Bypass -File $servicingScript `
                    -MountDir $mountDirNoDef `
                    -ProfileName $targetProfile `
                    -ProfileDir $profileDir `
                    -NSudoPath $nsudo `
                    -RemoveDefender:$true `
                    -TargetOS $targetOS

                if ($LASTEXITCODE -ne 0) { throw "Pass 2 servicing failed on index $idx with exit code $LASTEXITCODE" }
                Dismount-WindowsImageIndex -MountDir $mountDirNoDef -Commit
                $isMountedNoDef = $false
            }
            finally {
                if ($isMountedNoDef) {
                    Dismount-WindowsImageIndex -MountDir $mountDirNoDef -Discard
                }
            }

            if (Get-Command Set-WimImageInfo -ErrorAction SilentlyContinue) {
                Set-WimImageInfo -ImagePath $installWim -Index $idx -NewName $noDefName -NewDescription $noDefDesc -WimLibPath $wimlib
            }
        } else {
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
                    -NSudoPath $nsudo `
                    -RemoveDefender:$singleRemoveDefender `
                    -TargetOS $targetOS
                if ($LASTEXITCODE -ne 0) { throw "Invoke-Servicing.ps1 failed on index $idx with exit code $LASTEXITCODE" }

                Dismount-WindowsImageIndex -MountDir $mountDir -Commit
                $isMounted = $false
            }
            finally {
                if ($isMounted) {
                    Dismount-WindowsImageIndex -MountDir $mountDir -Discard
                }
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
}
