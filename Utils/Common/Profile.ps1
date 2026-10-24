<#
.SYNOPSIS
    Profile management and resolution helpers for Windows ISO builds.
.DESCRIPTION
    Provides functions to resolve profile directories, traverse inheritance hierarchies
    defined by Extends in profile.psd1, and extract merged ConvertConfig.ini settings.
#>

function Get-OfflineWindowsVersion {
    <#
    .SYNOPSIS
        Detects the Windows operating system version and family from an offline mounted image.
    .DESCRIPTION
        Inspects the mounted image at MountDir using loaded offline registry hives (OFFLINE_SOFTWARE)
        and file version information from System32\ntoskrnl.exe.
        Returns properties including TargetOS, Family, Build, UBR, Major, Minor,
        FullVersion, ProductName, DisplayVersion, and EditionId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$MountDir = "",

        [Parameter(Mandatory = $false)]
        [string]$OsFamily = ""
    )

    if (-not $MountDir) {
        if (Test-Path variable:script:MountDir) { $MountDir = $script:MountDir }
        elseif (Test-Path variable:global:MountDir) { $MountDir = $global:MountDir }
    }
    if (-not $OsFamily) {
        if (Test-Path variable:script:OsFamily) { $OsFamily = $script:OsFamily }
        elseif (Test-Path variable:global:OsFamily) { $OsFamily = $global:OsFamily }
    }

    $major = 10
    $minor = 0
    $build = 0
    $ubr = 0
    $productName = ""
    $displayVersion = ""
    $editionId = ""

    # Strategy 1: Loaded offline SOFTWARE registry hive
    $regOut = cmd /c "reg query `"HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion`" 2>&1"
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in ($regOut -split "\r?\n")) {
            $t = $line.Trim()
            if ($t -match '^CurrentBuild\s+REG_SZ\s+(\d+)') {
                $build = [int]$Matches[1]
            } elseif ($t -match '^CurrentBuildNumber\s+REG_SZ\s+(\d+)' -and $build -eq 0) {
                $build = [int]$Matches[1]
            } elseif ($t -match '^UBR\s+REG_DWORD\s+0x([0-9a-fA-F]+)') {
                $ubr = [convert]::ToInt32($Matches[1], 16)
            } elseif ($t -match '^ProductName\s+REG_SZ\s+(.+)$') {
                $productName = $Matches[1].Trim()
            } elseif ($t -match '^DisplayVersion\s+REG_SZ\s+(.+)$') {
                $displayVersion = $Matches[1].Trim()
            } elseif ($t -match '^EditionID\s+REG_SZ\s+(.+)$') {
                $editionId = $Matches[1].Trim()
            } elseif ($t -match '^CurrentMajorVersionNumber\s+REG_DWORD\s+0x([0-9a-fA-F]+)') {
                $major = [convert]::ToInt32($Matches[1], 16)
            } elseif ($t -match '^CurrentMinorVersionNumber\s+REG_DWORD\s+0x([0-9a-fA-F]+)') {
                $minor = [convert]::ToInt32($Matches[1], 16)
            }
        }
    }

    # Strategy 2: FileVersionInfo from ntoskrnl.exe or system32 binary if MountDir is provided
    if ($build -eq 0 -and $MountDir -and (Test-Path "$MountDir\Windows\System32\ntoskrnl.exe")) {
        try {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo("$MountDir\Windows\System32\ntoskrnl.exe")
            $major = $vi.FileMajorPart
            $minor = $vi.FileMinorPart
            $build = $vi.FileBuildPart
            $ubr = $vi.FilePrivatePart
        } catch {}
    }

    # Strategy 3: Direct registry hive query via temporary mount if offline hive is not loaded yet
    if ($build -eq 0 -and $MountDir -and (Test-Path "$MountDir\Windows\System32\config\SOFTWARE")) {
        $tmpHiveKey = "HKLM\TMP_DETECT_SOFTWARE_$([System.IO.Path]::GetRandomFileName() -replace '[^a-zA-Z0-9]','')"
        $sofPath = "$MountDir\Windows\System32\config\SOFTWARE"
        cmd /c "reg load `"$tmpHiveKey`" `"$sofPath`" >nul 2>&1"
        if ($LASTEXITCODE -eq 0) {
            $tmpReg = cmd /c "reg query `"$tmpHiveKey\Microsoft\Windows NT\CurrentVersion`" 2>&1"
            if ($LASTEXITCODE -eq 0) {
                foreach ($line in ($tmpReg -split "\r?\n")) {
                    $t = $line.Trim()
                    if ($t -match '^CurrentBuild\s+REG_SZ\s+(\d+)') {
                        $build = [int]$Matches[1]
                    } elseif ($t -match '^UBR\s+REG_DWORD\s+0x([0-9a-fA-F]+)') {
                        $ubr = [convert]::ToInt32($Matches[1], 16)
                    } elseif ($t -match '^ProductName\s+REG_SZ\s+(.+)$') {
                        $productName = $Matches[1].Trim()
                    } elseif ($t -match '^DisplayVersion\s+REG_SZ\s+(.+)$') {
                        $displayVersion = $Matches[1].Trim()
                    } elseif ($t -match '^EditionID\s+REG_SZ\s+(.+)$') {
                        $editionId = $Matches[1].Trim()
                    }
                }
            }
            cmd /c "reg unload `"$tmpHiveKey`" >nul 2>&1"
        }
    }

    # Extract xx version number from registry key value (e.g. ProductName "Windows 10 ...", "Windows 11 ...")
    $targetOS = ""
    if ($productName -match 'Windows\s*(\d+)') {
        $targetOS = $Matches[1]
    }

    # If build is 22000 or higher, target is Windows 11 even if registry ProductName retains legacy "Windows 10" string
    if ($build -ge 22000) {
        $targetOS = "11"
    } elseif ($build -gt 0 -and $build -lt 22000 -and -not $targetOS) {
        $targetOS = "10"
    }

    # Fallback to OsFamily parameter if MountDir is not mounted yet
    if (-not $targetOS -and $OsFamily) {
        if ($OsFamily -match '(\d+)') {
            $targetOS = $Matches[1]
        }
    }

    # Fallback to host OS if build is still 0
    if (-not $targetOS) {
        if ($build -eq 0) {
            $hostVer = [System.Environment]::OSVersion.Version
            $build = $hostVer.Build
            $major = $hostVer.Major
            $minor = $hostVer.Minor
            $ubr = if ($hostVer.Revision -gt 0) { $hostVer.Revision } else { 0 }
        }
        $targetOS = if ($build -ge 22000) { "11" } else { "10" }
    }

    $family = "Win$targetOS"

    if (-not $productName -or $productName -notmatch "Windows\s*$targetOS") {
        $productName = "Windows $targetOS"
        if ($editionId) { $productName += " $editionId" }
    }

    # Expose $targetOS (number xx e.g. 10 or 11) globally so all servicing scripts and profile manifests can access it directly
    $global:targetOS = $targetOS
    $global:targetFamily = $family

    return [PSCustomObject]@{
        TargetOS       = $targetOS
        Family         = $family
        Build          = $build
        UBR            = $ubr
        Major          = $major
        Minor          = $minor
        FullVersion    = "$major.$minor.$build.$ubr"
        ProductName    = $productName
        DisplayVersion = $displayVersion
        EditionId      = $editionId
    }
}
Set-Alias -Name Get-WindowsVersion -Value Get-OfflineWindowsVersion -ErrorAction SilentlyContinue

function Import-ProfileManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$MountDir = "",

        [Parameter(Mandatory = $false)]
        [string]$OsFamily = ""
    )

    if (-not $MountDir) {
        if (Test-Path variable:script:MountDir) { $MountDir = $script:MountDir }
        elseif (Test-Path variable:global:MountDir) { $MountDir = $global:MountDir }
    }
    if (-not $OsFamily) {
        if (Test-Path variable:script:OsFamily) { $OsFamily = $script:OsFamily }
        elseif (Test-Path variable:global:OsFamily) { $OsFamily = $global:OsFamily }
    }

    # Expose $targetOS from Get-OfflineWindowsVersion
    $ver = Get-OfflineWindowsVersion -MountDir $MountDir -OsFamily $OsFamily
    $targetOS = $ver.TargetOS
    $global:targetOS = $targetOS

    try {
        return Import-PowerShellDataFile -Path $Path -ErrorAction Stop
    } catch {
        try {
            $content = Get-Content -Path $Path -Raw
            $sb = [scriptblock]::Create($content)
            return & {
                param($targetOS, $MountDir, $OsFamily)
                . $sb
            } $targetOS $MountDir $OsFamily
        } catch {
            throw "Failed to load profile manifest '$Path': $_"
        }
    }
}

function Resolve-ProfileDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProfileName = "",

        [Parameter(Mandatory = $false)]
        [string]$ProfileDir = "",

        [Parameter(Mandatory = $false)]
        [string]$RepoRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$OsFamily = ""
    )

    if ($ProfileDir -and (Test-Path $ProfileDir)) {
        return (Resolve-Path $ProfileDir).Path
    }

    if (-not $RepoRoot) {
        $RepoRoot = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) {
            Get-RepoRoot
        } else {
            $PSScriptRoot
        }
    }

    if ($ProfileName) {
        $candidates = [System.Collections.Generic.List[string]]::new()
        if ($OsFamily) {
            $candidates.Add((Join-Path $RepoRoot "Config\$OsFamily\$ProfileName"))
        }
        $candidates.Add((Join-Path $RepoRoot "Config\$ProfileName"))

        # Strip any leading Win10/, Win11/, All/ prefix (e.g. 'Win11/Debloat' -> 'Debloat')
        $stripped = $ProfileName -replace '^(?:Win10|Win11|All)[/\\]', ''
        if ($stripped -and $stripped -ne $ProfileName) {
            $candidates.Add((Join-Path $RepoRoot "Config\$stripped"))
        }

        $candidates.Add((Join-Path $RepoRoot "Config\All\$ProfileName"))
        $candidates.Add((Join-Path $RepoRoot "Config\Win11\$ProfileName"))
        $candidates.Add((Join-Path $RepoRoot "Config\Win10\$ProfileName"))

        foreach ($cand in $candidates) {
            if (Test-Path $cand) {
                return (Resolve-Path $cand).Path
            }
        }
    }

    $defaultCandidates = @(
        (Join-Path $RepoRoot "Config\Default"),
        (Join-Path $RepoRoot "Config\All\Default")
    )
    if ($OsFamily) {
        $defaultCandidates = @(Join-Path $RepoRoot "Config\$OsFamily\Default") + $defaultCandidates
    }
    foreach ($cand in $defaultCandidates) {
        if (Test-Path $cand) {
            return (Resolve-Path $cand).Path
        }
    }

    return ""
}

function Get-ProfileHierarchy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('dir')]
        [string]$ProfileDir,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$RepoRoot = "",

        [Parameter(Mandatory = $false)]
        [string]$OsFamily = "",

        [Parameter(Mandatory = $false)]
        [string]$MountDir = ""
    )

    if (-not $RepoRoot) {
        $RepoRoot = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) {
            Get-RepoRoot $ProfileDir
        } else {
            $PSScriptRoot
        }
    }

    $chain = [System.Collections.Generic.List[psobject]]::new()
    $currDir = if (Test-Path $ProfileDir) { (Resolve-Path $ProfileDir).Path } else { "" }

    while ($currDir -and (Test-Path (Join-Path $currDir "profile.psd1"))) {
        $manifestPath = Join-Path $currDir "profile.psd1"
        $cfg = Import-ProfileManifest -Path $manifestPath -MountDir $MountDir -OsFamily $OsFamily
        $chain.Insert(0, [PSCustomObject]@{ Dir = $currDir; Config = $cfg })
        if ($cfg.ContainsKey('Extends') -and $cfg.Extends) {
            $parent = Join-Path $RepoRoot "Config\$($cfg.Extends)"
            if (-not (Test-Path (Join-Path $parent "profile.psd1"))) {
                $parent = Join-Path $RepoRoot "Config\All\$($cfg.Extends)"
            }
            if (Test-Path (Join-Path $parent "profile.psd1")) {
                $currDir = (Resolve-Path $parent).Path
            } else {
                break
            }
        } else {
            break
        }
    }

    return $chain.ToArray()
}

function Get-ProfileConvertConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('chain')]
        [psobject[]]$ProfileChain
    )

    $merged = @{}
    foreach ($item in $ProfileChain) {
        $cfg = $item.Config
        if ($cfg.ContainsKey('ConvertConfig') -and $cfg.ConvertConfig) {
            foreach ($key in $cfg.ConvertConfig.Keys) {
                $merged[$key] = [string]$cfg.ConvertConfig[$key]
            }
        }

        # Check for profile-local ConvertConfig.ini overlay file
        $iniPath = Join-Path $item.Dir "ConvertConfig.ini"
        if (Test-Path $iniPath) {
            $iniContent = Get-Content -Path $iniPath -ErrorAction SilentlyContinue
            foreach ($line in $iniContent) {
                $trimmed = $line.Trim()
                if ($trimmed -match '^\s*([^#;=\s]+)\s*=\s*(.*)$') {
                    $k = $Matches[1]
                    $v = $Matches[2].Trim()
                    $merged[$k] = $v
                }
            }
        }
    }

    return $merged
}

function Get-ProfileIsoTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('chain')]
        [psobject[]]$ProfileChain
    )

    for ($i = $ProfileChain.Count - 1; $i -ge 0; $i--) {
        $cfg = $ProfileChain[$i].Config
        if ($cfg.ContainsKey('IsoTag') -and $cfg.IsoTag) {
            return [string]$cfg.IsoTag
        }
    }
    return ""
}

function Get-ProfileIsoNameFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('chain')]
        [psobject[]]$ProfileChain
    )

    for ($i = $ProfileChain.Count - 1; $i -ge 0; $i--) {
        $cfg = $ProfileChain[$i].Config
        if ($cfg.ContainsKey('IsoNameFormat') -and $cfg.IsoNameFormat) {
            return [string]$cfg.IsoNameFormat
        }
    }
    return "{TargetName}-{Edition}-{Version}"
}

function Get-ProfileEnabledApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('chain')]
        [psobject[]]$ProfileChain
    )

    $removeDefender = if (Get-Command Get-ProfileRemoveDefender -ErrorAction SilentlyContinue) {
        Get-ProfileRemoveDefender -ProfileChain $ProfileChain
    } else {
        $false
    }

    $apps = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $ProfileChain) {
        $cfg = $item.Config
        if ($cfg.ContainsKey('EnabledApps') -and $cfg.EnabledApps) {
            foreach ($app in $cfg.EnabledApps) {
                if ($removeDefender -and ($app -like '*SecHealthUI*' -or $app -eq 'Microsoft.SecHealthUI')) {
                    continue
                }
                if ($app -and -not $apps.Contains($app)) {
                    $apps.Add($app)
                }
            }
        }
    }

    if (-not $removeDefender -and $apps.Count -gt 0) {
        if (-not $apps.Contains('Microsoft.SecHealthUI')) {
            $apps.Add('Microsoft.SecHealthUI')
        }
    }

    return $apps.ToArray()
}

function Get-ProfileRemoveFrameworkDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('chain')]
        [psobject[]]$ProfileChain
    )

    foreach ($item in $ProfileChain) {
        $cfg = $item.Config
        if ($cfg.ContainsKey('RemoveFrameworkDependencies') -and $cfg.RemoveFrameworkDependencies) {
            return [bool]$cfg.RemoveFrameworkDependencies
        }
    }
    return $false
}

function Get-ProfileExcludedDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('chain')]
        [psobject[]]$ProfileChain
    )

    $excluded = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $ProfileChain) {
        $cfg = $item.Config
        if ($cfg.ContainsKey('ExcludedDependencies') -and $cfg.ExcludedDependencies) {
            foreach ($dep in $cfg.ExcludedDependencies) {
                if ($dep -and -not $excluded.Contains($dep)) {
                    $excluded.Add($dep)
                }
            }
        }
    }
    return $excluded.ToArray()
}

function Get-ProfileRemoveDefender {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('chain')]
        [psobject[]]$ProfileChain
    )

    foreach ($item in $ProfileChain) {
        $cfg = $item.Config
        if ($cfg.ContainsKey('RemoveDefender')) {
            return [bool]$cfg.RemoveDefender
        }
    }
    return $false
}
