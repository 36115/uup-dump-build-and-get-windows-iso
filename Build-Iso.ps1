#!/usr/bin/pwsh
<#
.SYNOPSIS
    Unified Windows ISO build automation script with presets and configuration management.
.DESCRIPTION
    Provides end-to-end Windows ISO building, downloading from UUP Dump,
    applying offline servicing / debloat profiles, and producing bootable ISO images.
    Supports local interactive menus, presets, and non-interactive CI automation.
.EXAMPLE
    .\Build-Iso.ps1
    # Builds the active configuration saved in BuildConfig.psd1

    .\Build-Iso.ps1 -Menu
    # Opens the interactive Windows build preset selection menu

    .\Build-Iso.ps1 -Preset Win10-22H2-Pro-SeparateDefender
    # Selects Windows 10 22H2 Pro preset and updates BuildConfig.psd1

    .\Build-Iso.ps1 windows-11@26h2 Out -architecture x64 -edition pro -lang en-us -profileName Debloat -separateDefenderEditions
    # Direct command-line / CI execution
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    # Target Windows build / ring (positional 0 for CI compatibility)
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$windowsTargetName = "",

    # Destination directory (positional 1 for CI compatibility)
    [Parameter(Position = 1, Mandatory = $false)]
    [string]$destinationDirectory = "",

    [Parameter(Mandatory = $false)]
    [string]$architecture = "",

    [Parameter(Mandatory = $false)]
    [string]$edition = "",

    [Parameter(Mandatory = $false)]
    [string]$lang = "",

    [Parameter(Mandatory = $false)]
    [string]$profileName = "",

    [Parameter(Mandatory = $false)]
    [switch]$separateDefenderEditions,

    [switch]$esd,
    [switch]$drivers,
    [switch]$netfx3,
    [switch]$wimOnly,
    [string]$sourceIso = "",
    [string]$revision = "",

    # Interactive preset and configuration switches
    [string]$Preset = "",
    [switch]$Menu,
    [switch]$ListPresets,
    [switch]$ShowConfig,
    [string]$ConfigFile = "",
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

trap {
    Write-Host "ERROR: $_"
    @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$', 'ERROR: $1') | Write-Host
    @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$', 'ERROR EXCEPTION: $1') | Write-Host
    Exit 1
}

$RepoRoot = $PSScriptRoot

# -----------------------------------------------------------------------------
# Pre-defined Windows Build Presets
# -----------------------------------------------------------------------------
$script:Presets = [ordered]@{
    'Win11-26H2-Pro-SeparateDefender' = @{
        Description              = 'Windows 11 26H2 Pro (x64) + Debloat + Separate Defender Editions'
        Target                   = 'windows-11@26h2'
        Edition                  = 'pro'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $true
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win11-26H2-Pro-Debloat' = @{
        Description              = 'Windows 11 26H2 Pro (x64) + Debloat'
        Target                   = 'windows-11@26h2'
        Edition                  = 'pro'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $false
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win11-26H2-Home-Debloat' = @{
        Description              = 'Windows 11 26H2 Home (x64) + Debloat'
        Target                   = 'windows-11@26h2'
        Edition                  = 'core'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $false
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win11-24H2-Pro-SeparateDefender' = @{
        Description              = 'Windows 11 24H2 Pro (x64) + Debloat + Separate Defender Editions'
        Target                   = 'windows-11@24h2'
        Edition                  = 'pro'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $true
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win11-24H2-Pro-Debloat' = @{
        Description              = 'Windows 11 24H2 Pro (x64) + Debloat'
        Target                   = 'windows-11@24h2'
        Edition                  = 'pro'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $false
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win11-24H2-Home-Debloat' = @{
        Description              = 'Windows 11 24H2 Home (x64) + Debloat'
        Target                   = 'windows-11@24h2'
        Edition                  = 'core'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $false
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win11-23H2-Pro-SeparateDefender' = @{
        Description              = 'Windows 11 23H2 Pro (x64) + Debloat + Separate Defender Editions'
        Target                   = 'windows-11@23h2'
        Edition                  = 'pro'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $true
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win10-22H2-Pro-SeparateDefender' = @{
        Description              = 'Windows 10 22H2 Pro (x64) + Debloat + Separate Defender Editions'
        Target                   = 'windows-10'
        Edition                  = 'pro'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $true
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win10-22H2-Pro-Debloat' = @{
        Description              = 'Windows 10 22H2 Pro (x64) + Debloat'
        Target                   = 'windows-10'
        Edition                  = 'pro'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $false
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win11-Canary-Pro-Debloat' = @{
        Description              = 'Windows 11 Canary Pro (x64) + Debloat'
        Target                   = 'windows-canary'
        Edition                  = 'pro'
        Architecture             = 'x64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $false
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
    'Win11-24H2-Arm64-Pro-Debloat' = @{
        Description              = 'Windows 11 24H2 Pro (ARM64) + Debloat'
        Target                   = 'windows-11@24h2'
        Edition                  = 'pro'
        Architecture             = 'arm64'
        Language                 = 'en-us'
        ProfileName              = 'Debloat'
        SeparateDefenderEditions = $false
        Esd                      = $false
        NetFx3                   = $false
        Drivers                  = $false
    }
}

# -----------------------------------------------------------------------------
# Configuration File Resolution
# -----------------------------------------------------------------------------
function Resolve-ActiveConfigFile {
    param([string]$SpecifiedPath)
    if ($SpecifiedPath -and (Test-Path $SpecifiedPath)) {
        return (Resolve-Path $SpecifiedPath).Path
    }
    $localConfig = Join-Path $RepoRoot "BuildConfig.local.psd1"
    if (Test-Path $localConfig) { return $localConfig }

    $defaultConfig = Join-Path $RepoRoot "BuildConfig.psd1"
    if (Test-Path $defaultConfig) { return $defaultConfig }

    $exampleConfig = Join-Path $RepoRoot "Build\BuildConfig.example.psd1"
    if (Test-Path $exampleConfig) { return $exampleConfig }

    return $defaultConfig
}

function Get-ActiveBuildConfig {
    param([string]$Path)
    $cfgFile = Resolve-ActiveConfigFile $Path
    $cfg = @{}
    if (Test-Path $cfgFile) {
        try {
            $raw = Import-PowerShellDataFile -Path $cfgFile
            foreach ($k in $raw.Keys) { $cfg[$k] = $raw[$k] }
        } catch {
            Write-Warning "Could not parse config file $cfgFile : $_"
        }
    }
    # Apply baseline defaults if keys are missing
    if (-not $cfg.ContainsKey('Target') -or -not $cfg.Target) { $cfg.Target = 'windows-11@26h2' }
    if (-not $cfg.ContainsKey('Architecture') -or -not $cfg.Architecture) { $cfg.Architecture = 'x64' }
    if (-not $cfg.ContainsKey('Edition') -or -not $cfg.Edition) { $cfg.Edition = 'pro' }
    if (-not $cfg.ContainsKey('Language') -or -not $cfg.Language) { $cfg.Language = 'en-us' }
    if (-not $cfg.ContainsKey('ProfileName')) { $cfg.ProfileName = 'Debloat' }
    if (-not $cfg.ContainsKey('SeparateDefenderEditions')) { $cfg.SeparateDefenderEditions = $true }
    if (-not $cfg.ContainsKey('OutDir') -or -not $cfg.OutDir) { $cfg.OutDir = 'Out' }
    if (-not $cfg.ContainsKey('Esd')) { $cfg.Esd = $false }
    if (-not $cfg.ContainsKey('Drivers')) { $cfg.Drivers = $false }
    if (-not $cfg.ContainsKey('NetFx3')) { $cfg.NetFx3 = $false }
    if (-not $cfg.ContainsKey('WimOnly')) { $cfg.WimOnly = $false }
    if (-not $cfg.ContainsKey('Revision')) { $cfg.Revision = '' }
    return $cfg
}

function Set-ActiveBuildConfig {
    param(
        [hashtable]$Config,
        [string]$TargetFile = (Join-Path $RepoRoot "BuildConfig.psd1")
    )
    $valSeparate = if ($Config.SeparateDefenderEditions) { '$true' } else { '$false' }
    $valEsd = if ($Config.Esd) { '$true' } else { '$false' }
    $valDrivers = if ($Config.Drivers) { '$true' } else { '$false' }
    $valNetFx3 = if ($Config.NetFx3) { '$true' } else { '$false' }
    $valWimOnly = if ($Config.WimOnly) { '$true' } else { '$false' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("@{")
    [void]$sb.AppendLine("    # =========================================================================")
    [void]$sb.AppendLine("    # Windows ISO Build Configuration (BuildConfig.psd1)")
    [void]$sb.AppendLine("    # Updated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("    # =========================================================================")
    [void]$sb.AppendLine("    Target       = '$($Config.Target)'")
    [void]$sb.AppendLine("    Architecture = '$($Config.Architecture)'")
    [void]$sb.AppendLine("    Edition      = '$($Config.Edition)'")
    [void]$sb.AppendLine("    Language     = '$($Config.Language)'")
    [void]$sb.AppendLine("    ProfileName  = '$($Config.ProfileName)'")
    [void]$sb.AppendLine("    SeparateDefenderEditions = $valSeparate")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("    Esd          = $valEsd")
    [void]$sb.AppendLine("    Drivers      = $valDrivers")
    [void]$sb.AppendLine("    NetFx3       = $valNetFx3")
    [void]$sb.AppendLine("    WimOnly      = $valWimOnly")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("    OutDir       = '$($Config.OutDir)'")
    [void]$sb.AppendLine("    Revision     = '$($Config.Revision)'")
    [void]$sb.AppendLine("}")
    [System.IO.File]::WriteAllText($TargetFile, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

function Show-ActiveBuildConfig {
    param([hashtable]$Config)
    $profText = if ($Config.ProfileName) { $Config.ProfileName } else { '(None - Vanilla)' }
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host "                   Windows ISO Build Environment" -ForegroundColor Cyan
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host ("  Windows Target:    {0}" -f $Config.Target) -ForegroundColor Yellow
    Write-Host ("  Architecture:      {0}" -f $Config.Architecture) -ForegroundColor Yellow
    Write-Host ("  Edition:           {0}" -f $Config.Edition) -ForegroundColor Yellow
    Write-Host ("  Language:          {0}" -f $Config.Language) -ForegroundColor Yellow
    Write-Host ("  Servicing Profile: {0}" -f $profText) -ForegroundColor Yellow
    Write-Host ("  Separate Defender Editions: {0}" -f $Config.SeparateDefenderEditions) -ForegroundColor Yellow
    Write-Host ("  Output Directory:  {0}" -f $Config.OutDir) -ForegroundColor Yellow
    if ($Config.Esd)     { Write-Host "  Compression:       ESD" -ForegroundColor DarkYellow }
    if ($Config.Drivers) { Write-Host "  Drivers:           Enabled" -ForegroundColor DarkYellow }
    if ($Config.NetFx3)  { Write-Host "  .NET 3.5:          Enabled" -ForegroundColor DarkYellow }
    if ($Config.Revision){ Write-Host ("  Revision:          {0}" -f $Config.Revision) -ForegroundColor DarkYellow }
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Interactive Preset Selection Menu
# -----------------------------------------------------------------------------
function Show-BuildPresetMenu {
    param([string]$RequestedPreset = "")

    $presetKeys = @($script:Presets.Keys)

    if ($RequestedPreset) {
        $found = $presetKeys | Where-Object { $_ -eq $RequestedPreset -or $_ -like "*$RequestedPreset*" }
        if ($found) {
            $selectedKey = if ($found -is [array]) { $found[0] } else { $found }
            Write-Host "Selected Preset: $selectedKey" -ForegroundColor Green
            $presetData = $script:Presets[$selectedKey]
            $cfg = Get-ActiveBuildConfig
            foreach ($k in $presetData.Keys) {
                if ($k -ne 'Description') { $cfg[$k] = $presetData[$k] }
            }
            Set-ActiveBuildConfig -Config $cfg
            Show-ActiveBuildConfig -Config $cfg
            return $cfg
        } else {
            Write-Warning "Unknown preset '$RequestedPreset'. Showing preset menu..."
        }
    }

    Write-Host ""
    Write-Host "Select a Windows Build Preset:" -ForegroundColor Cyan
    Write-Host ""

    $index = 1
    foreach ($key in $presetKeys) {
        $p = $script:Presets[$key]
        $tag = if ($index -eq 1) { " [Default]" } else { "" }
        Write-Host ("  {0,2}. {1,-32} - {2}{3}" -f $index, $key, $p.Description, $tag) -ForegroundColor White
        $index++
    }
    Write-Host ("  {0,2}. {1,-32} - {2}" -f $index, "Custom", "Configure step-by-step custom wizard") -ForegroundColor Gray
    Write-Host ""

    $choice = Read-Host "Which preset would you like? [1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

    $cfg = Get-ActiveBuildConfig

    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $presetKeys.Count) {
        $selectedKey = $presetKeys[[int]$choice - 1]
        $presetData = $script:Presets[$selectedKey]
        foreach ($k in $presetData.Keys) {
            if ($k -ne 'Description') { $cfg[$k] = $presetData[$k] }
        }
        Write-Host "Configured preset: $selectedKey" -ForegroundColor Green
    } elseif ($choice -match '^\d+$' -and [int]$choice -eq ($presetKeys.Count + 1)) {
        # Custom interactive wizard
        Write-Host ""
        Write-Host "--- Custom Build Configuration ---" -ForegroundColor Cyan
        $inTarget = Read-Host "Target (e.g. windows-11@26h2, windows-10, windows-11@24h2) [$($cfg.Target)]"
        if ($inTarget) { $cfg.Target = $inTarget }

        $inArch = Read-Host "Architecture (x64, arm64) [$($cfg.Architecture)]"
        if ($inArch) { $cfg.Architecture = $inArch }

        $inEd = Read-Host "Edition (pro, core, multi, enterprise, iotenterprise) [$($cfg.Edition)]"
        if ($inEd) { $cfg.Edition = $inEd }

        $inLang = Read-Host "Language [$($cfg.Language)]"
        if ($inLang) { $cfg.Language = $inLang }

        $inProf = Read-Host "Profile name (Debloat, or empty for none) [$($cfg.ProfileName)]"
        if ($inProf -ne $null -and $inProf -ne '') { $cfg.ProfileName = $inProf }

        $sepPromptDef = if ($cfg.SeparateDefenderEditions) { 'y' } else { 'n' }
        $inSep = Read-Host "Separate Defender installer editions? (y/n) [$sepPromptDef]"
        if ($inSep) { $cfg.SeparateDefenderEditions = ($inSep -match '^[Yy]') }

        $inOut = Read-Host "Output directory [$($cfg.OutDir)]"
        if ($inOut) { $cfg.OutDir = $inOut }
    } else {
        $matched = $presetKeys | Where-Object { $_ -eq $choice -or $_ -like "*$choice*" }
        if ($matched) {
            $selectedKey = if ($matched -is [array]) { $matched[0] } else { $matched }
            $presetData = $script:Presets[$selectedKey]
            foreach ($k in $presetData.Keys) {
                if ($k -ne 'Description') { $cfg[$k] = $presetData[$k] }
            }
            Write-Host "Configured preset: $selectedKey" -ForegroundColor Green
        } else {
            Write-Warning "Unrecognized selection '$choice', keeping default preset."
            $presetData = $script:Presets[$presetKeys[0]]
            foreach ($k in $presetData.Keys) {
                if ($k -ne 'Description') { $cfg[$k] = $presetData[$k] }
            }
        }
    }

    Set-ActiveBuildConfig -Config $cfg
    Write-Host "[OK] Saved configuration to BuildConfig.psd1" -ForegroundColor Green
    Show-ActiveBuildConfig -Config $cfg
    return $cfg
}

# -----------------------------------------------------------------------------
# Core Windows ISO Build Engine
# -----------------------------------------------------------------------------
function Invoke-WindowsIsoBuild {
    param([hashtable]$BuildCfg)

    # Logging helper
    $loggingHelper = Join-Path $RepoRoot "Utils\Common\Write-Log.ps1"
    if (Test-Path $loggingHelper) { . $loggingHelper }

    # Setup environment
    $setupScript = Join-Path $RepoRoot "Build\Initialize-Environment.ps1"
    if (Test-Path $setupScript) { . $setupScript }

    # Image Servicing helper
    $imageServicingHelper = Join-Path $RepoRoot "Utils\Servicing\Invoke-ImageServicing.ps1"
    if (Test-Path $imageServicingHelper) { . $imageServicingHelper }

    $name = $BuildCfg.Target
    $destDir = $BuildCfg.OutDir
    $archInput = $BuildCfg.Architecture
    $edInput = $BuildCfg.Edition
    $langInput = $BuildCfg.Language
    $profInput = $BuildCfg.ProfileName
    $separateDefenderVal = [bool]$BuildCfg.SeparateDefenderEditions
    $esdVal = [bool]$BuildCfg.Esd
    $driversVal = [bool]$BuildCfg.Drivers
    $netfx3Val = [bool]$BuildCfg.NetFx3
    $wimOnlyVal = [bool]$BuildCfg.WimOnly
    $revInput = $BuildCfg.Revision
    $srcIso = $BuildCfg.SourceIso

    $arch = if (Get-Command Get-UupArchitecture -ErrorAction SilentlyContinue) {
        Get-UupArchitecture -Architecture $archInput
    } else {
        if ($archInput -eq "x64") { "amd64" } else { "arm64" }
    }

    $preview = $false
    $ringLower = if (Get-Command Get-UupTargetRing -ErrorAction SilentlyContinue) {
        Get-UupTargetRing -TargetName $name
    } else {
        if ($name -match 'beta|dev|wif|canary') { @('beta','dev','wif','canary').Where({$name -match $_})[0] } else { $null }
    }
    if ($ringLower) { $preview = $true }

    $targetDef = if (Get-Command Get-UupTargetDefinition -ErrorAction SilentlyContinue) {
        Get-UupTargetDefinition -TargetName $name -Architecture $arch -Revision $revInput -Edition $edInput
    } else {
        throw "Get-UupTargetDefinition not found."
    }

    $iso = Get-UupDumpIso $name $targetDef
    if (-not $iso) { throw "Can't find UUP for $name ($($targetDef.search)), lang=$langInput." }

    $edInfo = Get-EditionInfo $edInput
    $hasVirtualMember = [bool]$edInfo.Virtual
    $virtualEdn = $edInfo.Virtual
    $effectiveEdition = if ($hasVirtualMember) { $virtualEdn } elseif ($iso.PSObject.Properties.Name -contains 'edition' -and $iso.edition) { $iso.edition } else { $targetDef.edition }

    $verbuild = if (Get-Command Get-UupVersionBuild -ErrorAction SilentlyContinue) {
        Get-UupVersionBuild -Title $iso.title -Build $iso.build -IsPreview $preview -Ring $ringLower
    } else {
        if (!$preview) { ($iso.title -split 'version\s*')[1] -split '[\s\(]' | Select-Object -First 1 } else { $ringLower.ToUpper() }
    }

    $targetDirectory = if (Get-Command Resolve-TargetDirectory -ErrorAction SilentlyContinue) {
        Resolve-TargetDirectory -DestinationDirectory $destDir -Architecture $archInput -Build $iso.build -FallbackVersion $verbuild
    } else {
        Join-Path $destDir "Target\x86_64\$($iso.build)"
    }

    $buildDirectory = Join-Path $destDir "build\$name"
    if (Test-Path $buildDirectory) { Remove-Item -Force -Recurse $buildDirectory | Out-Null }
    New-Item -ItemType Directory -Force $buildDirectory | Out-Null

    $edn = if ($hasVirtualMember) { $virtualEdn } else { $effectiveEdition }
    Write-CleanLine $edn
    $title = "$name $edn $($iso.build)"

    Write-CleanLine "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
    $virtualEd = if ($hasVirtualMember) { $virtualEdn } else { "" }
    Get-UupPackageZip -DownloadPackageUrl $iso.downloadPackageUrl -DestinationDirectory $buildDirectory -VirtualEdition $virtualEd

    $osFamily = if ($name -match '(?i)win(dows)?[-_\s]?10') { 'Win10' } else { 'Win11' }
    $resolvedProfile = if ($profInput) { $profInput } else { "$osFamily/Default" }
    $resolvedProfileDir = if (Get-Command Resolve-ProfileDir -ErrorAction SilentlyContinue) {
        Resolve-ProfileDir -ProfileName $resolvedProfile -OsFamily $osFamily -RepoRoot $RepoRoot
    } else {
        Join-Path $RepoRoot "Config\$resolvedProfile"
    }
    $profileChain = if ($resolvedProfileDir -and (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue)) {
        Get-ProfileHierarchy -ProfileDir $resolvedProfileDir -RepoRoot $RepoRoot -OsFamily $osFamily
    } else {
        @()
    }
    $convertConfigOverrides = if (Get-Command Get-ProfileConvertConfig -ErrorAction SilentlyContinue) {
        Get-ProfileConvertConfig -ProfileChain $profileChain
    } else {
        @{}
    }

    $iniFile = Join-Path $buildDirectory 'ConvertConfig.ini'
    $tag = Set-UupConvertConfig -ConfigFile $iniFile `
        -Esd:$esdVal `
        -Drivers:$driversVal `
        -Architecture $arch `
        -DriversSourceDir (Join-Path $RepoRoot "Drivers") `
        -DriversDestDir (Join-Path $buildDirectory 'Drivers') `
        -NetFx3:$netfx3Val `
        -VirtualEdition $virtualEd `
        -WimOnly:$wimOnlyVal `
        -ConvertConfigOverrides $convertConfigOverrides

    if ($profileChain -and (Get-Command Get-ProfileIsoTag -ErrorAction SilentlyContinue)) {
        $profileIsoTag = Get-ProfileIsoTag -ProfileChain $profileChain
        if ($profileIsoTag) { $tag += $profileIsoTag }
    }

    if ($profileChain -and (Get-Command Initialize-UupCustomAppsList -ErrorAction SilentlyContinue)) {
        Initialize-UupCustomAppsList -BuildDirectory $buildDirectory -ProfileChain $profileChain
    }

    Write-CleanLine "Creating the $title iso file inside the $buildDirectory directory"
    Invoke-UupDownloadProcess -BuildDirectory $buildDirectory

    $needsServicing = [bool]$profInput -and ($resolvedProfile -notmatch '(?i)default$')
    if ($needsServicing -or $wimOnlyVal) {
        Write-CleanLine "Locating distribution folder..."
        $distDir = Resolve-DistributionDirectory -BuildDirectory $buildDirectory
        Write-CleanLine "Distribution folder located: $distDir"

        $wimlibHelper = Join-Path $RepoRoot "Utils\WimLib\Invoke-WimLib.ps1"
        if (Test-Path $wimlibHelper) { . $wimlibHelper }
        $wimlib = if (Get-Command Get-WimLibPath -ErrorAction SilentlyContinue) { Get-WimLibPath } else { $null }
        if ($wimlib) {
            Write-CleanLine "wimlib-imagex detected: $wimlib"
        }

        $installWim = Resolve-ServicingWim -DistributionDirectory $distDir -WimLibPath $wimlib

        if ($needsServicing) {
            Invoke-ImageServicing -installWim $installWim -distDir $distDir -esd:$esdVal -wimOnly:$wimOnlyVal -wimlib $wimlib -profileName $resolvedProfile -RepoRoot $RepoRoot -separateDefenderEditions:$separateDefenderVal
        }

        if ($esdVal -and -not $wimOnlyVal) {
            ConvertTo-DistributionEsd -DistributionDirectory $distDir -InstallWim $installWim -WimLibPath $wimlib
        }

        $baseInput = if ($srcIso -and (Test-Path $srcIso)) { $srcIso } else { $distDir }
        Write-CleanLine "Extracting and servicing clean base media from $baseInput..."
        $cleanSourceIsoDir = Join-Path $buildDirectory "CleanSourceIso"
        New-BaseIsoMedia -SourceIsoPath $baseInput -OutputDirectory $cleanSourceIsoDir -OsFamily $osFamily -ProfileName $resolvedProfile

        Sync-ServicedImageToMedia -SourceDistribution $distDir -TargetMedia $cleanSourceIsoDir
        $finalMediaDir = $cleanSourceIsoDir

        if ($wimOnlyVal) {
            Export-WimOnlyArtifact -distDir $distDir -cleanSourceIsoDir $cleanSourceIsoDir -targetDirectory $targetDirectory -buildDirectory $buildDirectory `
                -name $name -editionShort $edInfo.Short -build $iso.build -verbuild $verbuild -tag $tag
            return
        }

        $finalIsoName = if ($needsServicing) {
            Get-IsoName -TargetName $name -EditionShort $edInfo.Short -VersionBuild $verbuild -BuildNumber $iso.build
        } else {
            $title
        }

        $createdIsoPath = "$buildDirectory\$finalIsoName.iso"
        New-IsoImage -SourceDir $finalMediaDir -DestinationIsoPath $createdIsoPath -VolumeLabel $finalIsoName -Architecture $archInput -SearchDir $buildDirectory
    }

    Export-IsoArtifact -BuildDirectory $buildDirectory `
        -TargetDirectory $targetDirectory `
        -Name $name `
        -IsoInfo $iso `
        -VersionBuild $verbuild `
        -Tag $tag
}

# -----------------------------------------------------------------------------
# Main Execution Entry Point
# -----------------------------------------------------------------------------
if ($ListPresets) {
    Write-Host ""
    Write-Host "Available Windows Build Presets:" -ForegroundColor Cyan
    foreach ($k in $script:Presets.Keys) {
        Write-Host ("  {0,-32} - {1}" -f $k, $script:Presets[$k].Description) -ForegroundColor White
    }
    Write-Host ""
    return
}

# Check if direct arguments were passed (CI or CLI invocation)
$hasDirectArgs = ($PSBoundParameters.ContainsKey('windowsTargetName') -and $windowsTargetName) -or
    ($PSBoundParameters.ContainsKey('destinationDirectory') -and $destinationDirectory) -or
    ($PSBoundParameters.ContainsKey('architecture') -and $architecture) -or
    ($PSBoundParameters.ContainsKey('edition') -and $edition)

if ($Menu -or ($Preset -and -not $hasDirectArgs)) {
    $cfg = Show-BuildPresetMenu -RequestedPreset $Preset
    if (-not $NonInteractive) {
        $buildNow = Read-Host "Build now using this configuration? [Y/n]"
        if ($buildNow -and $buildNow -notmatch '^[Yy]') {
            Write-Host "Configuration saved. To start build later, run: .\Build-Iso.ps1" -ForegroundColor Yellow
            return
        }
    } else {
        return
    }
} else {
    $targetFile = Resolve-ActiveConfigFile $ConfigFile
    $cfg = Get-ActiveBuildConfig -Path $targetFile
}

# Apply command-line overrides
if ($PSBoundParameters.ContainsKey('windowsTargetName') -and $windowsTargetName) { $cfg.Target = $windowsTargetName }
if ($PSBoundParameters.ContainsKey('destinationDirectory') -and $destinationDirectory) { $cfg.OutDir = $destinationDirectory }
if ($PSBoundParameters.ContainsKey('architecture') -and $architecture) { $cfg.Architecture = $architecture }
if ($PSBoundParameters.ContainsKey('edition') -and $edition) { $cfg.Edition = $edition }
if ($PSBoundParameters.ContainsKey('lang') -and $lang) { $cfg.Language = $lang }
if ($PSBoundParameters.ContainsKey('profileName')) { $cfg.ProfileName = $profileName }
if ($PSBoundParameters.ContainsKey('separateDefenderEditions')) { $cfg.SeparateDefenderEditions = $separateDefenderEditions.IsPresent }
if ($PSBoundParameters.ContainsKey('revision') -and $revision) { $cfg.Revision = $revision }
if ($sourceIso) { $cfg.SourceIso = $sourceIso }
if ($esd) { $cfg.Esd = $true }
if ($drivers) { $cfg.Drivers = $true }
if ($netfx3) { $cfg.NetFx3 = $true }
if ($wimOnly) { $cfg.WimOnly = $true }

if ($ShowConfig) {
    Show-ActiveBuildConfig -Config $cfg
    return
}

# Display build banner
Show-ActiveBuildConfig -Config $cfg

# Ensure output directory exists
if (-not (Test-Path $cfg.OutDir)) {
    New-Item -ItemType Directory -Path $cfg.OutDir -Force | Out-Null
}

# Execute build
Invoke-WindowsIsoBuild -BuildCfg $cfg
