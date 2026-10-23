#!/usr/bin/pwsh

param(
  [string]$windowsTargetName,
  [string]$destinationDirectory = 'output',
  [ValidateSet("x64", "arm64")] [string]$architecture = "x64",
  [ValidateSet("pro", "core", "multi", "home")] [string]$edition = "pro",
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
$loggingHelper = Join-Path $PSScriptRoot "Utils\Common\Logging.ps1"
if (Test-Path $loggingHelper) { . $loggingHelper }

# ------------------------------
# Initialize Environment & Helpers
# ------------------------------
$setupScript = Join-Path $PSScriptRoot "Build\Setup.ps1"
if (-not (Test-Path $setupScript)) {
  $setupScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Build\Setup.ps1"
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

  $isoHasEdition    = $iso.PSObject.Properties.Name -contains 'edition' -and $iso.edition
  $hasVirtualMember = $iso.PSObject.Properties.Name -contains 'virtualEdition' -and $iso.virtualEdition
  $effectiveEdition = if ($isoHasEdition) { $iso.edition } else { $targetDef.edition }

  $verbuild = Get-UupVersionBuild -Title $iso.title -Build $iso.build -IsPreview $preview -Ring $ringLower

  $buildDirectory               = "$destinationDirectory/$name"
  $destinationIsoPath           = "$buildDirectory.iso"
  $destinationIsoMetadataPath   = "$destinationIsoPath.json"
  $destinationIsoChecksumPath   = "$destinationIsoPath.sha256.txt"

  if (Test-Path $buildDirectory) { Remove-Item -Force -Recurse $buildDirectory | Out-Null }
  New-Item -ItemType Directory -Force $buildDirectory | Out-Null

  $edn = if ($hasVirtualMember) { $iso.virtualEdition } else { $effectiveEdition }
  Write-CleanLine $edn
  $title = "$name $edn $($iso.build)"

  Write-CleanLine "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
  $virtualEd = if ($hasVirtualMember) { $iso.virtualEdition } else { "" }
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

  $sourceIsoPath = Resolve-Path $buildDirectory/*.iso
  $IsoName = Split-Path $sourceIsoPath -leaf

  Write-CleanLine "Getting the $sourceIsoPath checksum"
  $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
  Set-Content -Encoding ascii -NoNewline -Path $destinationIsoChecksumPath -Value $isoChecksum

  $windowsImages = Get-IsoWindowsImages $sourceIsoPath
  Set-Content -Path $destinationIsoMetadataPath -Value (
    ([PSCustomObject]@{
      name    = $name
      title   = $iso.title
      build   = $iso.build
      version = $verbuild
      tags    = $tag
      checksum = $isoChecksum
      images  = @($windowsImages)
      uupDump = @{
        id                 = $iso.id
        apiUrl             = $iso.apiUrl
        downloadUrl        = $iso.downloadUrl
        downloadPackageUrl = $iso.downloadPackageUrl
      }
    } | ConvertTo-Json -Depth 99) -replace '\\u0026','&'
  )

  Write-CleanLine "Moving the created $sourceIsoPath to $destinationDirectory/$IsoName"
  Move-Item -Force $sourceIsoPath "$destinationDirectory/$IsoName"

  Write-Output "ISO_NAME=$IsoName" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
  Write-CleanLine 'All Done.'
}

Get-WindowsIso $windowsTargetName $destinationDirectory
