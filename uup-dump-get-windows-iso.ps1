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
$loggingHelper = Join-Path $PSScriptRoot "Utils\Common\Write-Log.ps1"
if (Test-Path $loggingHelper) { . $loggingHelper }

# ------------------------------
# Load Helpers
# ------------------------------
$uupDumpHelper = Join-Path $PSScriptRoot "Utils\UUPDump\Get-UupDumpIso.ps1"
if (-not (Test-Path $uupDumpHelper)) {
        $uupDumpHelper = Join-Path (Split-Path $PSScriptRoot -Parent) "Utils\UUPDump\Get-UupDumpIso.ps1"
}

if (Test-Path $uupDumpHelper) { . $uupDumpHelper }

$isoHelper = Join-Path $PSScriptRoot "Utils\ISO\New-IsoImage.ps1"
if (-not (Test-Path $isoHelper)) {
        $isoHelper = Join-Path (Split-Path $PSScriptRoot -Parent) "Utils\ISO\New-IsoImage.ps1"
}

if (Test-Path $isoHelper) { . $isoHelper }

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
        $downloadPackageBody = if ($hasVirtualMember) { @{ autodl=3; updates=1; cleanup=1; 'virtualEditions[]'=$iso.virtualEdition } } else { @{ autodl=2; updates=1; cleanup=1 } }
        Invoke-WebRequest -Method Post -Uri $iso.downloadPackageUrl -Body $downloadPackageBody -OutFile "$buildDirectory.zip" | Out-Null
        Expand-Archive "$buildDirectory.zip" $buildDirectory

        $convertConfig = (Get-Content $buildDirectory/ConvertConfig.ini) `
    -replace '^(AutoExit\s*)=.*','$1=1' `
    -replace '^(ResetBase\s*)=.*','$1=1' `
    -replace '^(Cleanup\s*)=.*','$1=1'

        $tag = ""
        if ($esd) { $convertConfig = $convertConfig -replace '^(wim2esd\s*)=.*', '$1=1'; $tag += ".E" }
        if ($drivers -and $arch -ne "arm64") {
    $convertConfig = $convertConfig -replace '^(AddDrivers\s*)=.*', '$1=1'
    $tag += ".D"
    Write-CleanLine "Copy Dell drivers to $buildDirectory directory"
    Copy-Item -Path Drivers -Destination $buildDirectory/Drivers -Recurse
        }
        if ($netfx3) { $convertConfig = $convertConfig -replace '^(NetFx3\s*)=.*', '$1=1'; $tag += ".N" }
        if ($hasVirtualMember) {
    $convertConfig = $convertConfig `
                        -replace '^(StartVirtual\s*)=.*','$1=1' `
                        -replace '^(vDeleteSource\s*)=.*','$1=1' `
                        -replace '^(vAutoEditions\s*)=.*',"`$1=$($iso.virtualEdition)"
        }
        Set-Content -Encoding ascii -Path $buildDirectory/ConvertConfig.ini -Value $convertConfig

        Write-CleanLine "Creating the $title iso file inside the $buildDirectory directory"
        Push-Location $buildDirectory

        # Patch aria2 flags in the batch before running it
        Patch-Aria2-Flags -CmdPath (Join-Path $buildDirectory 'uup_download_windows.cmd')

        # Raw log path
        $rawLog = Join-Path $env:RUNNER_TEMP "uup_dism_aria2_raw.log"

        choco install aria2 /y *> $null

        & {
    powershell cmd /c uup_download_windows.cmd 2>&1 |
                        Tee-Object -FilePath $rawLog |
                        ForEach-Object {
        $raw = [string]$_
        if ([string]::IsNullOrEmpty($raw)) { return }
        foreach ($crChunk in ($raw -split "`r")) {
                                        foreach ($line in ($crChunk -split "`n")) {
            if ($line -eq $null) { continue }
            # DISM progress buckets; aria2 is not parsed here
            if (-not (Process-ProgressLine $line)) {
                                                        if ($line -match '^\s*(Mounting image|Saving image|Applying image|Exporting image|Unmounting image|Deployment Image Servicing and Management tool|^=== )') {
                Reset-ProgressSession
                                                        }
                                                        Write-CleanLine $line
            }
                                        }
        }
                        }
        }

        if ($LASTEXITCODE) {
    Write-Host "::warning title=Build failed::Dumping last 1500 raw log lines"
    Get-Content $rawLog -Tail 1500 | Write-Host
    throw "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
        }

        Pop-Location

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
