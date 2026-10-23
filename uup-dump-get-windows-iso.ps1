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
                [string]$revision
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

$preview  = $false
$ringLower = $null

trap {
                Write-Host "ERROR: $_"
                @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1') | Write-Host
                @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1') | Write-Host
                Exit 1
}

# ------------------------------
# Log helpers + DISM bucketed progress (no aria2 parsing)
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

# ------------------------------
function Get-WindowsIso($name, $destinationDirectory) {
                                $arch = Get-UupArchitecture -Architecture $architecture
                $preview = $false
                $ringLower = Get-UupTargetRing -TargetName $name
                if ($ringLower) { $preview = $true }
                $targetDef = Get-UupTargetDefinition -TargetName $name -Architecture $arch -Revision $revision -Edition $edition
                $iso = Get-UupDumpIso $name $targetDef
                if (-not $iso) { throw "Can't find UUP for $name ($($targetDef.search)), lang=$lang." }

                $edInfo = Get-EditionInfo $edition
                $hasVirtualMember = [bool]$edInfo.Virtual
                $virtualEdn = $edInfo.Virtual
                $effectiveEdition = if ($hasVirtualMember) { $virtualEdn } elseif ($iso.PSObject.Properties.Name -contains 'edition' -and $iso.edition) { $iso.edition } else { $targetDef.edition }

                $verbuild = Get-UupVersionBuild -Title $iso.title -Build $iso.build -IsPreview $preview -Ring $ringLower

                $targetDirectory = Resolve-TargetDirectory -DestinationDirectory $destinationDirectory -Architecture $architecture -Build $iso.build -FallbackVersion $verbuild

                $buildDirectory = Join-Path $destinationDirectory "build\$name"

                if (Test-Path $buildDirectory) { Remove-Item -Force -Recurse $buildDirectory | Out-Null }
                New-Item -ItemType Directory -Force $buildDirectory | Out-Null

                $edn = if ($hasVirtualMember) { $virtualEdn } else { $effectiveEdition }
                Write-CleanLine $edn
                $title = "$name $edn $($iso.build)"

                Write-CleanLine "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
                $virtualEd = if ($hasVirtualMember) { $virtualEdn } else { "" }
                Get-UupPackageZip -DownloadPackageUrl $iso.downloadPackageUrl -DestinationDirectory $buildDirectory -VirtualEdition $virtualEd

                $iniFile = Join-Path $buildDirectory 'ConvertConfig.ini'
                $tag = Set-UupConvertConfig -ConfigFile $iniFile `
                                -Esd:$esd `
                                -Drivers:$drivers `
                                -Architecture $arch `
                                -DriversSourceDir "Drivers" `
                                -DriversDestDir (Join-Path $buildDirectory 'Drivers') `
                                -NetFx3:$netfx3 `
                                -VirtualEdition $virtualEd

                Write-CleanLine "Creating the $title iso file inside the $buildDirectory directory"
                Invoke-UupDownloadProcess -BuildDirectory $buildDirectory

                                Export-IsoArtifact -BuildDirectory $buildDirectory `
                                -TargetDirectory $targetDirectory `
                                -Name $name `
                                -IsoInfo $iso `
                                -VersionBuild $verbuild `
                                -Tag $tag}

Get-WindowsIso $windowsTargetName $destinationDirectory
