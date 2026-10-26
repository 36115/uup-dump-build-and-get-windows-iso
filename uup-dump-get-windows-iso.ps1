#!/usr/bin/pwsh

param(
        [string]$windowsTargetName,
        [string]$destinationDirectory = 'Out',
        [ValidateSet("x64", "arm64")] [string]$architecture = "x64",
        [ValidateSet("pro", "core", "multi", "home", "homesinglelanguage", "enterprise", "education", "professionalworkstation", "proworkstation", "professionaleducation", "proeducation", "iotenterprise", "iotenterprisek", "serverrdsh")] [string]$edition = "pro",
        [ValidateSet("nb-no", "fr-ca", "fi-fi", "lv-lv", "es-es", "en-gb", "zh-tw", "th-th", "sv-se", "en-us", "es-mx", "bg-bg", "hr-hr", "pt-br", "el-gr", "cs-cz", "it-it", "sk-sk", "pl-pl", "sl-si", "neutral", "ja-jp", "et-ee", "ro-ro", "fr-fr", "pt-pt", "ar-sa", "lt-lt", "hu-hu", "da-dk", "zh-cn", "uk-ua", "tr-tr", "ru-ru", "nl-nl", "he-il", "ko-kr", "sr-latn-rs", "de-de")]
        [string]$lang = "en-us",
        [switch]$esd,
        [switch]$drivers,
        [switch]$netfx3,
        [switch]$wimOnly,
        [string]$sourceIso,
        [string]$revision,
        [string]$profileName,
        [ValidateSet('Both', 'Remove', 'Keep', '')][string]$defenderBuild = "",
        [switch]$separateDefenderEditions
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

trap {
        Write-Host "ERROR: $_"
        @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1') | Write-Host
        @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1') | Write-Host
        Exit 1
}

# ------------------------------
# Log helpers + DISM bucketed progress
# ------------------------------
$loggingHelper = Join-Path $PSScriptRoot "Utils\Common\Write-Log.ps1"
if (Test-Path $loggingHelper) { . $loggingHelper }

# ------------------------------
# Initialize Environment & Helpers
# ------------------------------
$setupScript = Join-Path $PSScriptRoot "Build\Initialize-Environment.ps1"
if (-not (Test-Path $setupScript)) {
        $setupScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Build\Initialize-Environment.ps1"
}

if (Test-Path $setupScript) { . $setupScript }

$imageServicingHelper = Join-Path $PSScriptRoot "Utils\Servicing\Invoke-ImageServicing.ps1"
if (Test-Path $imageServicingHelper) { . $imageServicingHelper }

function Get-WindowsIso($name, $destinationDirectory) {
        $arch = if (Get-Command Get-UupArchitecture -ErrorAction SilentlyContinue) {
    Get-UupArchitecture -Architecture $architecture
        } else {
    if ($architecture -eq "x64") { "amd64" } else { "arm64" }
        }

        $preview = $false
        $ringLower = if (Get-Command Get-UupTargetRing -ErrorAction SilentlyContinue) {
    Get-UupTargetRing -TargetName $name
        } else {
    if ($name -match 'beta|dev|wif|canary') { @('beta','dev','wif','canary').Where({$name -match $_})[0] } else { $null }
        }
        if ($ringLower) { $preview = $true }

        $targetDef = if (Get-Command Get-UupTargetDefinition -ErrorAction SilentlyContinue) {
    Get-UupTargetDefinition -TargetName $name -Architecture $arch -Revision $revision -Edition $edition
        } else {
    throw "Get-UupTargetDefinition not found."
        }

        $iso = Get-UupDumpIso $name $targetDef
        if (-not $iso) { throw "Can't find UUP for $name ($($targetDef.search)), lang=$lang." }

        $edInfo = Get-EditionInfo $edition
        $hasVirtualMember = [bool]$edInfo.Virtual
        $virtualEdn = $edInfo.Virtual
        $effectiveEdition = if ($hasVirtualMember) { $virtualEdn } elseif ($iso.PSObject.Properties.Name -contains 'edition' -and $iso.edition) { $iso.edition } else { $targetDef.edition }

        $verbuild = if (Get-Command Get-UupVersionBuild -ErrorAction SilentlyContinue) {
    Get-UupVersionBuild -Title $iso.title -Build $iso.build -IsPreview $preview -Ring $ringLower
        } else {
    if (!$preview) { ($iso.title -split 'version\s*')[1] -split '[\s\(]' | Select-Object -First 1 } else { $ringLower.ToUpper() }
        }

        $targetDirectory = if (Get-Command Resolve-TargetDirectory -ErrorAction SilentlyContinue) {
    Resolve-TargetDirectory -DestinationDirectory $destinationDirectory -Architecture $architecture -Build $iso.build -FallbackVersion $verbuild
        } else {
    Join-Path $destinationDirectory "Target\x86_64\$($iso.build)"
        }

        $buildDirectory = Join-Path $destinationDirectory "build\$name"
        if (Test-Path $buildDirectory) { Remove-Item -Force -Recurse $buildDirectory | Out-Null }
        New-Item -ItemType Directory -Force $buildDirectory | Out-Null

        $edn = if ($hasVirtualMember) { $virtualEdn } else { $effectiveEdition }
        Write-CleanLine $edn
        $title = "$name $edn $($iso.build)"

        Write-CleanLine "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
        $virtualEd = if ($hasVirtualMember) { $virtualEdn } else { "" }
        Get-UupPackageZip -DownloadPackageUrl $iso.downloadPackageUrl -DestinationDirectory $buildDirectory -VirtualEdition $virtualEd

        $osFamily = if ($name -match '(?i)win(dows)?[-_\s]?10') { 'Win10' } else { 'Win11' }
        $resolvedProfile = if ($profileName) { $profileName } else { "$osFamily/Default" }
        $resolvedProfileDir = if (Get-Command Resolve-ProfileDir -ErrorAction SilentlyContinue) {
    Resolve-ProfileDir -ProfileName $resolvedProfile -OsFamily $osFamily -RepoRoot $PSScriptRoot
        } else {
    Join-Path $PSScriptRoot "Config\$resolvedProfile"
        }
        $profileChain = if ($resolvedProfileDir -and (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue)) {
    Get-ProfileHierarchy -ProfileDir $resolvedProfileDir -RepoRoot $PSScriptRoot -OsFamily $osFamily
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
    -Esd:$esd `
    -Drivers:$drivers `
    -Architecture $arch `
    -DriversSourceDir "Drivers" `
    -DriversDestDir (Join-Path $buildDirectory 'Drivers') `
    -NetFx3:$netfx3 `
    -VirtualEdition $virtualEd `
    -WimOnly:$wimOnly `
    -ConvertConfigOverrides $convertConfigOverrides

        # Append profile IsoTag (e.g. .Debloat) if configured in profile hierarchy
        $profileIsoTag = if ($profileChain -and (Get-Command Get-ProfileIsoTag -ErrorAction SilentlyContinue)) {
    Get-ProfileIsoTag -ProfileChain $profileChain
        } else {
    ""
        }
        if ($profileIsoTag) { $tag += $profileIsoTag }

        # Patch CustomAppsList.txt if profile hierarchy specifies EnabledApps
        if ($profileChain -and (Get-Command Initialize-UupCustomAppsList -ErrorAction SilentlyContinue)) {
    Initialize-UupCustomAppsList -BuildDirectory $buildDirectory -ProfileChain $profileChain
        }

        Write-CleanLine "Creating the $title iso file inside the $buildDirectory directory"
        Invoke-UupDownloadProcess -BuildDirectory $buildDirectory

        $needsServicing = [bool]$profileName -and ($resolvedProfile -notmatch '(?i)default$')
        if ($needsServicing -or $wimOnly) {
    Write-CleanLine "Locating distribution folder..."
    $distDir = Resolve-DistributionDirectory -BuildDirectory $buildDirectory
    Write-CleanLine "Distribution folder located: $distDir"

    $wimlibHelper = Join-Path $PSScriptRoot "Utils\WimLib\Invoke-WimLib.ps1"
    if (Test-Path $wimlibHelper) { . $wimlibHelper }
    $wimlib = if (Get-Command Get-WimLibPath -ErrorAction SilentlyContinue) { Get-WimLibPath } else { $null }
    if ($wimlib) {
                        Write-CleanLine "wimlib-imagex detected: $wimlib"
    }

    $installWim = Resolve-ServicingWim -DistributionDirectory $distDir -WimLibPath $wimlib

    if ($needsServicing) {
                        Invoke-ImageServicing -installWim $installWim -distDir $distDir -esd:$esd -wimOnly:$wimOnly -wimlib $wimlib -profileName $resolvedProfile -RepoRoot $PSScriptRoot -separateDefenderEditions:$separateDefenderEditions
    }

    # If ESD was requested (and not wimOnly mode)
    if ($esd -and -not $wimOnly) {
                        ConvertTo-DistributionEsd -DistributionDirectory $distDir -InstallWim $installWim -WimLibPath $wimlib
    }

    # Clean SourceIso media and service boot.wim using New-BaseIsoMedia on uupdump's distribution folder
    $baseInput = if ($sourceIso -and (Test-Path $sourceIso)) { $sourceIso } else { $distDir }
    Write-CleanLine "Extracting and servicing clean base media from $baseInput..."
    $cleanSourceIsoDir = Join-Path $buildDirectory "CleanSourceIso"
    New-BaseIsoMedia -SourceIsoPath $baseInput -OutputDirectory $cleanSourceIsoDir -OsFamily $osFamily -ProfileName $resolvedProfile

    # Copy serviced install image into the clean SourceIso media
    Sync-ServicedImageToMedia -SourceDistribution $distDir -TargetMedia $cleanSourceIsoDir
    $finalMediaDir = $cleanSourceIsoDir

    if ($wimOnly) {
                        Export-WimOnlyArtifact -distDir $distDir -cleanSourceIsoDir $cleanSourceIsoDir -targetDirectory $targetDirectory -buildDirectory $buildDirectory `
        -name $name -editionShort $edInfo.Short -build $iso.build -verbuild $verbuild -tag $tag
                        return
    }

    # Build ISO with cdimage.exe
    $finalIsoName = if ($needsServicing) {
                        Get-IsoName -TargetName $name -EditionShort $edInfo.Short -VersionBuild $verbuild -BuildNumber $iso.build
    } else {
                        $title
    }

    $createdIsoPath = "$buildDirectory\$finalIsoName.iso"
    New-IsoImage -SourceDir $finalMediaDir -DestinationIsoPath $createdIsoPath -VolumeLabel $finalIsoName -Architecture $architecture -SearchDir $buildDirectory
        }

        Export-IsoArtifact -BuildDirectory $buildDirectory `
    -TargetDirectory $targetDirectory `
    -Name $name `
    -IsoInfo $iso `
    -VersionBuild $verbuild `
    -Tag $tag
}

Get-WindowsIso $windowsTargetName $destinationDirectory
