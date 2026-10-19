#!/usr/bin/pwsh
param(
  [Parameter(Mandatory=$true)]
  [string]$WimDirectory,
  [string]$WindowsTargetName = 'windows-11',
  [string]$DestinationDirectory = 'output',
  [ValidateSet("x64", "arm64")]
  [string]$Architecture = "x64",
  [switch]$Esd,
  [string]$Base7zPath,
  [string]$Revision,
  [string]$Lang = "en-us"
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

function Write-CleanLine([string]$text) {
  Write-Host $text
}

Write-CleanLine "=== Starting All-In-One (AIO) Windows ISO Builder ==="
Write-CleanLine "Target: $WindowsTargetName | Arch: $Architecture | WimDir: $WimDirectory"

if (-not (Test-Path $WimDirectory)) {
  throw "WimDirectory '$WimDirectory' does not exist."
}

if (-not (Test-Path $DestinationDirectory)) {
  New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
}

# 1. Discover all WIM / ESD files in WimDirectory
$wimFiles = Get-ChildItem -Path $WimDirectory -Recurse -File | Where-Object {
  $_.Extension -match '^\.(wim|esd)$' -and $_.Name -notmatch '^boot\.'
}

if (-not $wimFiles -or $wimFiles.Count -eq 0) {
  throw "No .wim or .esd files found in '$WimDirectory'."
}

Write-CleanLine "Found $($wimFiles.Count) image file(s) in ${WimDirectory}:"
$wimFiles | ForEach-Object { Write-CleanLine "  - $($_.FullName)" }

# Priority sorting function for canonical edition order
function Get-EditionPriority([string]$filename) {
  $f = $filename.ToLower()
  if ($f -match 'homesl|coresinglelanguage') { return 2 }
  if ($f -match 'home|core')                 { return 1 }
  if ($f -match 'proworkstation|workstation'){ return 5 }
  if ($f -match 'proeducation')              { return 4 }
  if ($f -match 'pro|professional')          { return 3 }
  if ($f -match 'education')                 { return 6 }
  if ($f -match 'iotenterprisek')            { return 9 }
  if ($f -match 'iotenterprise')             { return 8 }
  if ($f -match 'enterprise')                { return 7 }
  if ($f -match 'serverrdsh|multisession')   { return 10 }
  return 11
}

$sortedWimFiles = $wimFiles | Sort-Object { Get-EditionPriority $_.Name }

# 2. Stage AIO install.wim
$stagingDir = Join-Path $env:TEMP "AIO_Staging_$([System.IO.Path]::GetRandomFileName())"
$stagingSources = Join-Path $stagingDir "sources"
New-Item -ItemType Directory -Path $stagingSources -Force | Out-Null

$mergedWim = Join-Path $stagingSources "install.wim"
Write-CleanLine "Merging images into $mergedWim..."

$totalMerged = 0
foreach ($wf in $sortedWimFiles) {
  Write-CleanLine "Inspecting $($wf.FullName)..."
  $images = Get-WindowsImage -ImagePath $wf.FullName
  foreach ($img in $images) {
    $idx = $img.ImageIndex
    $name = $img.ImageName
    $totalMerged++
    Write-CleanLine "Exporting index $idx ($name) from $($wf.Name) into AIO WIM (Target Index: $totalMerged)..."
    & dism.exe /Export-Image /SourceImageFile:$($wf.FullName) /SourceIndex:$idx /DestinationImageFile:$mergedWim
    if ($LASTEXITCODE -ne 0) {
      throw "dism /Export-Image failed on $($wf.FullName) index $idx with exit code $LASTEXITCODE"
    }
  }
}

Write-CleanLine "Successfully merged $totalMerged index(es) into $mergedWim."

# 3. Convert to ESD if requested
if ($Esd) {
  Write-CleanLine "Converting AIO install.wim to install.esd..."
  $mergedEsd = Join-Path $stagingSources "install.esd"
  for ($i = 1; $i -le $totalMerged; $i++) {
    Write-CleanLine "Exporting index $i of $totalMerged to install.esd /Compress:recovery..."
    & dism.exe /Export-Image /SourceImageFile:$mergedWim /SourceIndex:$i /DestinationImageFile:$mergedEsd /Compress:recovery
    if ($LASTEXITCODE -ne 0) {
      throw "dism /Export-Image to ESD failed on index $i with exit code $LASTEXITCODE"
    }
  }
  Remove-Item $mergedWim -Force
  Write-CleanLine "ESD conversion complete."
}

# 4. Integrate Base Media (base.7z)
$resolvedBase7z = if ($Base7zPath -and (Test-Path $Base7zPath)) {
  $Base7zPath
} elseif (Test-Path (Join-Path $PSScriptRoot "..\..\base.7z")) {
  Resolve-Path (Join-Path $PSScriptRoot "..\..\base.7z")
} elseif (Test-Path "base.7z") {
  Resolve-Path "base.7z"
} else {
  $null
}

if (-not $resolvedBase7z) {
  throw "base.7z could not be found to stage the bootable media structure."
}

Write-CleanLine "Extracting base media from $resolvedBase7z into $stagingDir..."
$sevenZip = if (Test-Path (Join-Path $PSScriptRoot "..\7z\windows-x64\7za.exe")) {
  (Resolve-Path (Join-Path $PSScriptRoot "..\7z\windows-x64\7za.exe")).Path
} elseif (Get-Command 7z -ErrorAction SilentlyContinue) {
  (Get-Command 7z).Source
} elseif (Get-Command 7za -ErrorAction SilentlyContinue) {
  (Get-Command 7za).Source
} else {
  throw "7-Zip binary (7z/7za) not found to extract base.7z."
}

& $sevenZip x "$resolvedBase7z" -o"$stagingDir" -y | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Failed to extract base.7z with exit code $LASTEXITCODE"
}

# 5. Locate cdimage.exe
$cdimageExe = (Get-ChildItem -Path $WimDirectory -Filter "cdimage.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $cdimageExe) {
  $cdimageExe = (Get-ChildItem -Path $PSScriptRoot -Filter "cdimage.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if (-not $cdimageExe) {
  $cdimageExe = (Get-Command cdimage.exe -ErrorAction SilentlyContinue).Source
}
if (-not $cdimageExe) {
  # Look in Runner temp or choco
  $cdimageCandidate = Join-Path $env:RUNNER_TEMP "cdimage.exe"
  if (Test-Path $cdimageCandidate) { $cdimageExe = $cdimageCandidate }
}
if (-not $cdimageExe) {
  throw "cdimage.exe could not be found to build the AIO ISO."
}

# 6. Read build metadata from JSON files if available
$firstJson = Get-ChildItem -Path $WimDirectory -Filter "*.json" -Recurse -File | Select-Object -First 1
$buildNumber = "UnknownBuild"
$verbuild = "AIO"
if ($firstJson) {
  try {
    $meta = Get-Content $firstJson.FullName -Raw | ConvertFrom-Json
    if ($meta.build)   { $buildNumber = $meta.build }
    if ($meta.version) { $verbuild = $meta.version }
  } catch {}
}

$osPrefix = if ($WindowsTargetName -match '^windows-10') { 'Win10' } else { 'Win11' }
$finalIsoName = "$osPrefix-AIO-$verbuild-Lite-$buildNumber"
$createdIsoPath = Join-Path $DestinationDirectory "$finalIsoName.iso"
$dvdLabel = ($finalIsoName -replace '[^A-Za-z0-9_]','_')
if ($dvdLabel.Length -gt 32) { $dvdLabel = $dvdLabel.Substring(0, 32) }

Write-CleanLine "Packaging AIO ISO: $createdIsoPath (DVD Label: $dvdLabel)..."

$bootEtfs = Join-Path $stagingDir "boot\etfsboot.com"
$bootEfi  = Join-Path $stagingDir "efi\Microsoft\boot\efisys.bin"

if ($Architecture -ne "arm64" -and (Test-Path $bootEtfs)) {
  & $cdimageExe "-bootdata:2#p0,e,b$bootEtfs#pEF,e,b$bootEfi" -o -m -u2 -udfver102 -l$dvdLabel $stagingDir $createdIsoPath
} else {
  & $cdimageExe "-bootdata:1#pEF,e,b$bootEfi" -o -m -u2 -udfver102 -l$dvdLabel $stagingDir $createdIsoPath
}

if ($LASTEXITCODE -ne 0) {
  throw "cdimage.exe failed with exit code $LASTEXITCODE"
}
Write-CleanLine "AIO ISO generated successfully: $createdIsoPath"

# 7. Checksum & Metadata
$isoChecksum = (Get-FileHash -Algorithm SHA256 $createdIsoPath).Hash.ToLowerInvariant()
Set-Content -Encoding ascii -NoNewline -Path "$createdIsoPath.sha256.txt" -Value $isoChecksum

$finalMediaFile = if ($Esd) { Join-Path $stagingSources "install.esd" } else { Join-Path $stagingSources "install.wim" }
$finalImages = Get-WindowsImage -ImagePath $finalMediaFile

$isoMetadata = [PSCustomObject]@{
  name       = $WindowsTargetName
  edition    = "AIO"
  build      = $buildNumber
  version    = $verbuild
  checksum   = $isoChecksum
  images     = @($finalImages | ForEach-Object { [PSCustomObject]@{ index = $_.ImageIndex; name = $_.ImageName; version = $_.Version } })
}
$isoMetadata | ConvertTo-Json -Depth 5 | Set-Content -Path "$createdIsoPath.json"

# Clean staging
Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

if ($env:GITHUB_ENV) {
  Write-Output "ISO_NAME=$finalIsoName" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

Write-CleanLine "All Done. AIO ISO Ready: $createdIsoPath"
