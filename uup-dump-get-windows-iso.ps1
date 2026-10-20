#!/usr/bin/pwsh

param(
  [string]$windowsTargetName,
  [string]$destinationDirectory = 'output',
  [ValidateSet("x64", "arm64")] [string]$architecture = "x64",
  [ValidateSet("pro", "core", "multi", "home", "homesinglelanguage", "enterprise", "education", "professionalworkstation", "proworkstation", "professionaleducation", "proeducation", "iotenterprise", "iotenterprisek", "serverrdsh")] [string]$edition = "home",
  [ValidateSet("nb-no", "fr-ca", "fi-fi", "lv-lv", "es-es", "en-gb", "zh-tw", "th-th", "sv-se", "en-us", "es-mx", "bg-bg", "hr-hr", "pt-br", "el-gr", "cs-cz", "it-it", "sk-sk", "pl-pl", "sl-si", "neutral", "ja-jp", "et-ee", "ro-ro", "fr-fr", "pt-pt", "ar-sa", "lt-lt", "hu-hu", "da-dk", "zh-cn", "uk-ua", "tr-tr", "ru-ru", "nl-nl", "he-il", "ko-kr", "sr-latn-rs", "de-de")]
  [string]$lang = "en-us",
  [switch]$esd,
  [switch]$drivers,
  [switch]$netfx3,
  [switch]$debloat,
  [switch]$wimOnly,
  [string]$base7zPath,
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
$script:reAnsi = [regex]'\x1B\[[0-9;]*[A-Za-z]'
$script:LastPrintedLine = $null
function Write-CleanLine([string]$text) {
  $clean = if ($text) { $script:reAnsi.Replace($text, '') } else { '' }
  if ($clean -eq $script:LastPrintedLine) { return }
  $script:LastPrintedLine = $clean
  Write-Host $clean
}

# DISM buckets (0/10/.../100)
$script:DismLastBucket = -1
$script:DismEveryPercent = if ($env:DISM_PROGRESS_STEP) { [int]$env:DISM_PROGRESS_STEP } else { 10 }
$script:DismNormalizeOutput = if ($env:DISM_PROGRESS_RAW -eq '1') { $false } else { $true }

$script:reArchiving = [regex]'Archiving file data:\s+.*?\((\d+)%\)\s+done'
$script:reBracket   = [regex]'\[\s*[= \-]*\s*(\d+(?:[.,]\d+)?)%\s*[= \-]*\s*\]'
$script:reLoosePct  = [regex]'(^|\s)(\d{1,3})(?:[.,]\d+)?%(\s|$)'

function Get-PercentFromText([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return $null }
  $t = $script:reAnsi.Replace($text, '')

  $m = $script:reArchiving.Match($t)
  if ($m.Success) { return [int]$m.Groups[1].Value }

  $m = $script:reBracket.Match($t)
  if ($m.Success) {
    $pct = $m.Groups[1].Value -replace ',', '.'
    return [int][math]::Floor([double]$pct)
  }

  $m = $script:reLoosePct.Match($t)
  if ($m.Success) {
    $n = [int]$m.Groups[2].Value
    if ($n -ge 0 -and $n -le 100) { return $n }
  }
  return $null
}

function Reset-ProgressSession { $script:DismLastBucket = -1 }

function Emit-ProgressBucket([int]$pct) {
  $bucket = [int]([math]::Floor($pct / $script:DismEveryPercent) * $script:DismEveryPercent)
  if ($bucket -le $script:DismLastBucket) { return $false }
  $script:DismLastBucket = $bucket

  if ($script:DismNormalizeOutput) { Write-CleanLine ("[DISM] Progress: {0}%" -f $bucket) }
  else { Write-CleanLine ("Progress: {0}%" -f $bucket) }

  if ($bucket -ge 100) {
    Write-CleanLine "[DISM] Progress: 100% (done)"
    Reset-ProgressSession
  }
  return $true
}

function Process-ProgressLine([string]$line) {
  $pct = Get-PercentFromText $line
  if ($pct -eq $null) { return $false }
  if ($script:DismLastBucket -ge 0 -and $pct -lt $script:DismLastBucket) { Reset-ProgressSession }
  [void](Emit-ProgressBucket $pct)
  return $true
}

# ------------------------------
# Basic metadata helpers
# ------------------------------
$arch = if ($architecture -eq "x64") { "amd64" } else { "arm64" }

if ($windowsTargetName -match 'beta|dev|wif|canary') {
  $preview = $true
  $ringLower = @('beta','dev','wif','canary').Where({$windowsTargetName -match $_})[0]
}

function Get-EditionInfo([string]$e) {
  switch ($e.ToLower()) {
    { $_ -in "core", "home" }                                           { [PSCustomObject]@{ Base = "Core"; Virtual = $null; Short = "Home"; Fancy = "Windows Home" } }
    { $_ -in "homesinglelanguage", "coresinglelanguage", "homesl" }     { [PSCustomObject]@{ Base = "Core"; Virtual = "CoreSingleLanguage"; Short = "HomeSL"; Fancy = "Windows Home Single Language" } }
    { $_ -in "pro", "professional" }                                    { [PSCustomObject]@{ Base = "Professional"; Virtual = $null; Short = "Pro"; Fancy = "Windows Pro" } }
    { $_ -in "professionalworkstation", "proworkstation" }              { [PSCustomObject]@{ Base = "Professional"; Virtual = "ProfessionalWorkstation"; Short = "ProWorkstation"; Fancy = "Windows Pro for Workstations" } }
    { $_ -in "professionaleducation", "proeducation" }                  { [PSCustomObject]@{ Base = "Professional"; Virtual = "ProfessionalEducation"; Short = "ProEducation"; Fancy = "Windows Pro Education" } }
    "education"                                                         { [PSCustomObject]@{ Base = "Professional"; Virtual = "Education"; Short = "Education"; Fancy = "Windows Education" } }
    "enterprise"                                                        { [PSCustomObject]@{ Base = "Professional"; Virtual = "Enterprise"; Short = "Enterprise"; Fancy = "Windows Enterprise" } }
    "iotenterprise"                                                     { [PSCustomObject]@{ Base = "Professional"; Virtual = "IoTEnterprise"; Short = "IoTEnterprise"; Fancy = "Windows IoT Enterprise" } }
    "iotenterprisek"                                                    { [PSCustomObject]@{ Base = "Professional"; Virtual = "IoTEnterpriseK"; Short = "IoTEnterpriseK"; Fancy = "Windows IoT Enterprise K" } }
    "serverrdsh"                                                        { [PSCustomObject]@{ Base = "Professional"; Virtual = "ServerRdsh"; Short = "ServerRdsh"; Fancy = "Windows Enterprise multi-session" } }
    "multi"                                                             { [PSCustomObject]@{ Base = "Multi"; Virtual = $null; Short = "Multi"; Fancy = "Windows Multi-Edition" } }
    default                                                             { [PSCustomObject]@{ Base = "Professional"; Virtual = $null; Short = $e; Fancy = "Windows $e" } }
  }
}

function Get-EditionName($e) {
  return (Get-EditionInfo $e).Base
}

$dotSystemRevision = if ([string]::IsNullOrWhiteSpace($revision)) { '' } else { ".$revision" }
$systemRevision = if ([string]::IsNullOrWhiteSpace($revision)) { '' } else { " $revision" }

$script:CurrentEditionInfo = Get-EditionInfo $edition

$TARGETS = @{
  "windows-10"           = @{ search="windows 10 19045$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-11old"        = @{ search="windows 11 22631$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-11"           = @{ search="windows 11 26100$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-11new"        = @{ search="windows 11 26200$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-11beta"       = @{ search="windows 11 26120$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; ring="Beta"; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-11dev"        = @{ search="windows 11 26220$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; ring="Wif"; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-1126h1"       = @{ search="windows 11 28000$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-1126h2"       = @{ search="windows 11 26300$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-1126h2beta"   = @{ search="windows 11 26340$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-dev"          = @{ search="windows 11 26300$dotSystemRevision $arch"; edition=$script:CurrentEditionInfo.Base; ring="Dev"; virtualEdition=$script:CurrentEditionInfo.Virtual }
  "windows-canary"       = @{ search="windows 11$systemRevision $arch"; edition=$script:CurrentEditionInfo.Base; ring="Canary"; virtualEdition=$script:CurrentEditionInfo.Virtual }
}

function New-QueryString([hashtable]$parameters) {
  @($parameters.GetEnumerator() | ForEach-Object { "$($_.Key)=$([System.Net.WebUtility]::UrlEncode([string]$_.Value))" }) -join '&'
}

function Invoke-UupDumpApi([string]$name, [hashtable]$body) {
  for ($n = 0; $n -lt 15; ++$n) {
    if ($n) {
      Write-CleanLine "Waiting a bit before retrying the uup-dump api ${name} request #$n"
      Start-Sleep -Seconds 10
      Write-CleanLine "Retrying the uup-dump api ${name} request #$n"
    }
    try {
      $qs = if ($body) { '?' + (New-QueryString $body) } else { '' }
      return Invoke-RestMethod -Method Get -Uri ("https://api.uupdump.net/{0}.php{1}" -f $name, $qs)
    } catch {
      Write-CleanLine "WARN: failed the uup-dump api $name request: $_"
    }
  }
  throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpIso($name, $target) {
  Write-CleanLine "Getting the $name metadata"
  $result = Invoke-UupDumpApi listid @{ search = $target.search }

  $result.response.builds.PSObject.Properties |
    ForEach-Object {
      $id = $_.Value.uuid
      $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{ id = $id })
      Write-CleanLine "Processing $name $id ($uupDumpUrl)"
      $_
    } |
    Where-Object {
      if ($_.Value.title -match '\.NET Framework') {
            Write-CleanLine "Skipping, ignore .NET Framework update."
            return $false
        }
      if ($_.Value.title -match 'Windows CPC OS') {
            Write-CleanLine "Skipping, ignore Windows CPC OS."
            return $false
        }
      if (!$preview) {
        $ok = ($target.search -like '*preview*') -or ($_.Value.title -notlike '*preview*')
        if (-not $ok) {
          Write-CleanLine "Skipping.
L1: Expected preview=false.
L2: Got preview=true."
        }
        return $ok
      }
      $true
    } |
    ForEach-Object {
      $id = $_.Value.uuid
      Write-CleanLine "Getting the $name $id langs metadata"
      $result = Invoke-UupDumpApi listlangs @{ id = $id }
      if ($result.response.updateInfo.build -ne $_.Value.build) {
        throw 'for some reason listlangs returned an unexpected build'
      }
      $_.Value | Add-Member -NotePropertyMembers @{ langs = $result.response.langFancyNames; info = $result.response.updateInfo }

      $langs = $_.Value.langs.PSObject.Properties.Name
      $eds = if ($langs -contains $lang) {
        Write-CleanLine "Getting the $name $id editions metadata"
        $result = Invoke-UupDumpApi listeditions @{ id = $id; lang = $lang }
        $result.response.editionFancyNames
      } else {
        Write-CleanLine "Skipping.
L3: Expected langs=$lang.
L4: Got langs=$($langs -join ',')."
        [PSCustomObject]@{}
      }
      $_.Value | Add-Member -NotePropertyMembers @{ editions = $eds }
      $_
    } |
    Where-Object {
      $langs = $_.Value.langs.PSObject.Properties.Name
      $editions = $_.Value.editions.PSObject.Properties.Name
      $res = $true

      if ($ringLower) {
        $actual = ($_.Value.info.ring).ToUpper()
        $allowedRings = switch ($ringLower) {
          'canary' { 'CANARY', 'WIF' }
          'dev'    { 'DEV', 'WIF', 'WIS' }
          'beta'   { 'BETA', 'WIF', 'WIS' }
          default { $ringLower.ToUpper() }
        }

        if ($actual -notin $allowedRings) {
          Write-CleanLine "Skipping. Expected ring: $($allowedRings -join ', '). Got ring=$actual."
          $res = $false
        }
      }

      if ($langs -notcontains $lang) {
        Write-CleanLine "Skipping. Expected langs=$lang. Got langs=$($langs -join ',')."
        $res = $false
      }

      if ((Get-EditionName $edition) -eq "Multi") {
        if (($editions -notcontains "Professional") -and ($editions -notcontains "Core")) {
          Write-CleanLine "Skipping.
L6: Expected editions=Multi (Professional/Core). Got editions=$($editions -join ',')."
          $res = $false
        }
      } elseif ($editions -notcontains (Get-EditionName $edition)) {
        Write-CleanLine ("Skipping. Expected editions={0}.
L7: Got editions={1}." -f (Get-EditionName $edition), ($editions -join ','))
        $res = $false
      }

      if (!$preview -and -not ($_.Value.title -match 'version')) {
        Write-CleanLine "Skipping. Unexpected title format: missing 'version'."
        $res = $false
      }

      $res
    } |
    Select-Object -First 1 |
    ForEach-Object {
      $id = $_.Value.uuid
      [PSCustomObject]@{
        name               = $name
        title              = $_.Value.title
        build              = $_.Value.build
        id                 = $id
        edition            = $target.edition
        virtualEdition     = $target['virtualEdition']
        apiUrl             = 'https://api.uupdump.net/get.php?' + (New-QueryString @{ id = $id; lang = $lang; edition = if ($edition -eq "multi") { "core;professional" } else { $target.edition } })
        downloadUrl        = 'https://uupdump.net/download.php?' + (New-QueryString @{ id = $id; pack = $lang; edition = if ($edition -eq "multi") { "core;professional" } else { $target.edition } })
        downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{ id = $id; pack = $lang; edition = if ($edition -eq "multi") { "core;professional" } else { $target.edition } })
      }
    }
}

function Get-IsoWindowsImages($isoPath) {
  $isoPath = Resolve-Path $isoPath
  Write-CleanLine "Mounting $isoPath"
  $isoImage = Mount-DiskImage $isoPath -PassThru
  try {
    $isoVolume = $isoImage | Get-Volume
    $installPath = if ($esd) { "$($isoVolume.DriveLetter):\sources\install.esd" } else { "$($isoVolume.DriveLetter):\sources\install.wim" }
    Write-CleanLine "Getting Windows images from $installPath"
    Get-WindowsImage -ImagePath $installPath | ForEach-Object {
      $image = Get-WindowsImage -ImagePath $installPath -Index $_.ImageIndex
      $imgVer = if ($image.PSObject.Properties['MajorVersion'] -and $image.MajorVersion) {
        "$($image.MajorVersion).$($image.MinorVersion).$($image.Build).$($image.SPBuild)"
      } elseif ($image.PSObject.Properties['Version'] -and $image.Version) {
        $image.Version
      } else { "" }
      [PSCustomObject]@{ index = $image.ImageIndex; name = $image.ImageName; version = $imgVer }
    }
  }
  finally {
    Write-CleanLine "Dismounting $isoPath"
    Dismount-DiskImage $isoPath | Out-Null
  }
}

# ------------------------------
# Patch uup_download_windows.cmd with sed - quiet aria2 flags
# ------------------------------
function Patch-Aria2-Flags {
  param([string]$CmdPath)
  if (-not (Test-Path $CmdPath)) { return }

  $sed = Get-Command sed -ErrorAction SilentlyContinue
  if ($sed) {
    Write-CleanLine "Patching aria2 flags in $CmdPath using sed."
    # Remove conflicting flags first
    & $sed.Path -ri 's/\s--console-log-level=\w+\b//g; s/\s--summary-interval=\d+\b//g; s/\s--download-result=\w+\b//g; s/\s--enable-color=\w+\b//g; s/\s-(q|quiet(=\w+)?)\b//g' $CmdPath
    # Inject quiet set right after "%aria2%"
    & $sed.Path -ri 's@("%aria2%"\s+)@\1--quiet=true --console-log-level=error --summary-interval=0 --download-result=hide --enable-color=false @g' $CmdPath
    return
  }

  # Fallback: PowerShell regex (preserves UTF-16LE)
  Write-CleanLine "sed not found. Patching aria2 flags in $CmdPath using PowerShell fallback."
  $bytes   = [System.IO.File]::ReadAllBytes($CmdPath)
  $content = [System.Text.Encoding]::Unicode.GetString($bytes)

  $patternsToRemove = @(
    '\s--console-log-level=\w+\b',
    '\s--summary-interval=\d+\b',
    '\s--download-result=\w+\b',
    '\s--enable-color=\w+\b',
    '\s-(?:q|quiet(?:=\w+)?)\b'
  )
  foreach ($re in $patternsToRemove) {
    $content = [regex]::Replace($content, $re, '', 'IgnoreCase, CultureInvariant')
  }
  $inject = '--quiet=true --console-log-level=error --summary-interval=0 --download-result=hide --enable-color=false '
  $content = [regex]::Replace($content, '("%aria2%"\s+)', ('$1' + $inject), 'IgnoreCase, CultureInvariant')

  $newBytes = [System.Text.Encoding]::Unicode.GetBytes($content)
  [System.IO.File]::WriteAllBytes($CmdPath, $newBytes)
}

function Get-WindowsIso($name, $destinationDirectory) {
  $iso = Get-UupDumpIso $name $TARGETS.$name
  if (-not $iso) { throw "Can't find UUP for $name ($($TARGETS.$name.search)), lang=$lang." }

  $edInfo = Get-EditionInfo $edition
  $hasVirtualMember = [bool]$edInfo.Virtual
  $virtualEdn = $edInfo.Virtual
  $effectiveEdition = if ($hasVirtualMember) { $virtualEdn } elseif ($iso.PSObject.Properties.Name -contains 'edition' -and $iso.edition) { $iso.edition } else { $TARGETS.$name.edition }

  if (!$preview) {
    if ($iso.title -match 'version') {
      $parts = @($iso.title -split 'version\s*')
      if ($parts.Count -lt 2) { throw "Unexpected title format, split resulted in less than 2 parts: $($parts -join '|')" }
      $verbuild = $parts[1] -split '[\s\(]' | Select-Object -First 1
    } else {
      Write-CleanLine "WARN: Unexpected title format: missing 'version'. Using build number fallback."
      $verbuild = $iso.build
    }
  } else {
    $verbuild = $ringLower.ToUpper()
  }

  $buildDirectory               = "$destinationDirectory/$name"
  $destinationIsoPath           = "$buildDirectory.iso"
  $destinationIsoMetadataPath   = "$destinationIsoPath.json"
  $destinationIsoChecksumPath   = "$destinationIsoPath.sha256.txt"

  if (Test-Path $buildDirectory) { Remove-Item -Force -Recurse $buildDirectory | Out-Null }
  New-Item -ItemType Directory -Force $buildDirectory | Out-Null

  $edn = if ($hasVirtualMember) { $virtualEdn } else { $effectiveEdition }
  Write-CleanLine $edn
  $title = "$name $edn $($iso.build)"

  Write-CleanLine "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
  $downloadPackageBody = if ($hasVirtualMember) { @{ autodl=3; updates=1; cleanup=1; 'virtualEditions[]'=$virtualEdn } } else { @{ autodl=2; updates=1; cleanup=1 } }
  Invoke-WebRequest -Method Post -Uri $iso.downloadPackageUrl -Body $downloadPackageBody -OutFile "$buildDirectory.zip" | Out-Null
  Expand-Archive "$buildDirectory.zip" $buildDirectory

  $convertConfig = (Get-Content $buildDirectory/ConvertConfig.ini) `
    -replace '^(AutoExit\s*)=.*','$1=1' `
    -replace '^(ResetBase\s*)=.*','$1=1' `
    -replace '^(Cleanup\s*)=.*','$1=1'

  $tag = ""
  if ($esd -and -not $debloat) { $convertConfig = $convertConfig -replace '^(wim2esd\s*)=.*', '$1=1'; $tag += ".E" }
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
      -replace '^(vAutoEditions\s*)=.*',"`$1=$virtualEdn"
  }
  if ($wimOnly) {
    $convertConfig = $convertConfig `
      -replace '^(SkipISO\s*)=.*', '$1=1' `
      -replace '^(vSkipISO\s*)=.*', '$1=1' `
      -replace '^(wim2esd\s*)=.*', '$1=0' `
      -replace '^(vwim2esd\s*)=.*', '$1=0'
  }
  if ($debloat) {
    $convertConfig = $convertConfig `
      -replace '^(wim2esd\s*)=.*', '$1=0' `
      -replace '^(vwim2esd\s*)=.*', '$1=0' `
      -replace '^(SkipISO\s*)=.*', '$1=1' `
      -replace '^(vSkipISO\s*)=.*', '$1=1' `
      -replace '^(SkipEdge\s*)=.*', '$1=2' `
      -replace '^(SkipWinRE\s*)=.*', '$1=0' `
      -replace '^(CustomList\s*)=.*', '$1=1' `
      -replace '^(vDeleteSource\s*)=.*', '$1=1'
    if ($esd) { $tag += ".E" }
    $tag += ".Debloat"

    $customAppsPath = Join-Path $buildDirectory "CustomAppsList.txt"
    if (Test-Path $customAppsPath) {
      $calContent = Get-Content $customAppsPath -Raw
      # Comment out SecHealthUI (remove Defender app)
      $calContent = [regex]::Replace($calContent, '(?m)^\s*Microsoft\.SecHealthUI', '# Microsoft.SecHealthUI')
      # Uncomment XboxIdentityProvider (keep Xbox sign-in functional)
      $calContent = [regex]::Replace($calContent, '(?m)^\s*#\s*(Microsoft\.XboxIdentityProvider.*)', '$1')
      Set-Content -Path $customAppsPath -Value $calContent -Encoding UTF8
      Write-CleanLine "Configured CustomAppsList.txt (SecHealthUI removed, XboxIdentityProvider retained)"
    }
  }
  Set-Content -Encoding ascii -Path $buildDirectory/ConvertConfig.ini -Value $convertConfig

  Write-CleanLine "Creating the $title iso file inside the $buildDirectory directory"
  Push-Location $buildDirectory

  # Patch aria2 flags in the batch before running it
  Patch-Aria2-Flags -CmdPath (Join-Path $buildDirectory 'uup_download_windows.cmd')

  # Raw log path
  $tempDir = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
  $rawLog = Join-Path $tempDir "uup_dism_aria2_raw.log"

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

  if ($debloat -or $wimOnly) {
    Write-CleanLine "Locating distribution folder..."
    $distDir = Get-ChildItem -Path $buildDirectory -Directory | Where-Object { 
      (Test-Path (Join-Path $_.FullName "sources\install.wim")) -or (Test-Path (Join-Path $_.FullName "sources\install.esd"))
    } | Select-Object -First 1 -ExpandProperty FullName

    if (-not $distDir) {
      if (Test-Path (Join-Path $buildDirectory "ISOFOLDER\sources\install.wim")) {
        $distDir = Join-Path $buildDirectory "ISOFOLDER"
      } elseif (Test-Path (Join-Path $buildDirectory "ISOFOLDER\sources\install.esd")) {
        $distDir = Join-Path $buildDirectory "ISOFOLDER"
      } else {
        throw "Could not locate distribution folder with sources\install.wim in $buildDirectory"
      }
    }
    Write-CleanLine "Distribution folder located: $distDir"

    $installWim = Join-Path $distDir "sources\install.wim"
    if (-not (Test-Path $installWim)) {
      $installEsd = Join-Path $distDir "sources\install.esd"
      if (Test-Path $installEsd) {
        Write-CleanLine "Exporting install.esd to install.wim for servicing..."
        $esdImages = @(Get-WindowsImage -ImagePath $installEsd)
        for ($i = 1; $i -le $esdImages.Count; $i++) {
          & dism.exe /Export-Image /SourceImageFile:$installEsd /SourceIndex:$i /DestinationImageFile:$installWim
        }
        Remove-Item $installEsd -Force
      } else {
        throw "Neither install.wim nor install.esd found in $distDir\sources"
      }
    }

    if ($debloat) {
      $wimImages = @(Get-WindowsImage -ImagePath $installWim)
      $imageCount = $wimImages.Count
      Write-CleanLine "Found $imageCount image index(es) in $installWim to service."

      $debloatScript = Join-Path $PSScriptRoot "Utils\Debloat\Invoke-Debloat.ps1"
      $regPack = Join-Path $PSScriptRoot "Utils\Debloat\Windows-11-REG-Pack-(NoDefender).reg"
      if (-not (Test-Path $regPack)) {
        $regPack = Join-Path $PSScriptRoot "UUPDump Debloat\Windows-11-REG-Pack-(NoDefender).reg"
      }
      $nsudo = Join-Path $PSScriptRoot "Utils\NSudo\x64\NSudoLC.exe"

      for ($idx = 1; $idx -le $imageCount; $idx++) {
        $imgObj = $wimImages | Where-Object { $_.ImageIndex -eq $idx }
        $currentImageName = if ($imgObj) { $imgObj.ImageName } else { "Index $idx" }
        Write-CleanLine "=== Servicing index $idx of ${imageCount}: $currentImageName ==="

        $mountDir = Join-Path $env:TEMP "Mount_Debloat_$([System.IO.Path]::GetRandomFileName())"
        New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
        Add-MpPreference -ExclusionPath $mountDir -ErrorAction SilentlyContinue
        Write-CleanLine "Mounting $installWim index $idx to $mountDir..."
        & dism.exe /Mount-Wim /WimFile:$installWim /Index:$idx /MountDir:$mountDir
        if ($LASTEXITCODE -ne 0) { throw "dism /Mount-Wim failed on index $idx with exit code $LASTEXITCODE" }
        $isMounted = $true

        try {
          Write-CleanLine "Running Invoke-Debloat.ps1 against mounted image index $idx..."
          & powershell -ExecutionPolicy Bypass -File $debloatScript `
              -MountDir $mountDir `
              -RegPackPath $regPack `
              -NSudoPath $nsudo
          if ($LASTEXITCODE -ne 0) { throw "Invoke-Debloat.ps1 failed on index $idx with exit code $LASTEXITCODE" }

          Set-Location $PSScriptRoot
          [System.GC]::Collect()
          [System.GC]::WaitForPendingFinalizers()
          Start-Sleep -Seconds 2

          Write-CleanLine "Unmounting and committing image at $mountDir..."
          $unmountSuccess = $false
          for ($attempt = 1; $attempt -le 5; $attempt++) {
              [System.GC]::Collect()
              [System.GC]::WaitForPendingFinalizers()
              & dism.exe /Unmount-Wim /MountDir:$mountDir /Commit
              if ($LASTEXITCODE -eq 0) {
                  $unmountSuccess = $true
                  $isMounted = $false
                  break
              }
              Write-Warning "dism /Unmount-Wim /Commit attempt $attempt failed with exit code $LASTEXITCODE. Retrying in $($attempt * 3) seconds..."
              Start-Sleep -Seconds ($attempt * 3)
          }
          if (-not $unmountSuccess) {
              throw "dism /Unmount-Wim /Commit failed after 5 attempts with exit code $LASTEXITCODE on index $idx"
          }
        }
        finally {
          if ($isMounted) {
            for ($discardAttempt = 1; $discardAttempt -le 3; $discardAttempt++) {
              & dism.exe /Unmount-Wim /MountDir:$mountDir /Discard *> $null
              if ($LASTEXITCODE -eq 0) { break }
              Start-Sleep -Seconds 2
            }
          }
          Remove-MpPreference -ExclusionPath $mountDir -ErrorAction SilentlyContinue
          if (Test-Path $mountDir) {
            Remove-Item $mountDir -Force -Recurse -ErrorAction SilentlyContinue
          }
        }
      }

      # If WIM will remain (not being converted to ESD) or wimOnly mode, compact to purge orphaned streams
      if (-not $esd -or $wimOnly) {
        Write-CleanLine "Compacting serviced install.wim ($imageCount index(es)) to purge orphaned streams..."
        $tempCompactWim = Join-Path $distDir "sources\install_compact.wim"
        if (Test-Path $tempCompactWim) { Remove-Item $tempCompactWim -Force }
        try {
          for ($idx = 1; $idx -le $imageCount; $idx++) {
            Write-CleanLine "Exporting index $idx of $imageCount to compacted WIM..."
            & dism.exe /Export-Image /SourceImageFile:$installWim /SourceIndex:$idx /DestinationImageFile:$tempCompactWim /Compress:max /CheckIntegrity
            if ($LASTEXITCODE -ne 0) { throw "dism /Export-Image compaction failed on index $idx with exit code $LASTEXITCODE" }
          }
          Remove-Item $installWim -Force
          Move-Item $tempCompactWim $installWim -Force
          Write-CleanLine "Compaction complete. New install.wim size: $((Get-Item $installWim).Length) bytes"
        }
        catch {
          if (Test-Path $tempCompactWim) { Remove-Item $tempCompactWim -Force -ErrorAction SilentlyContinue }
          throw
        }
      }
    }

    # If ESD was requested (and not wimOnly mode)
    if ($esd -and -not $wimOnly) {
      $wimImages = @(Get-WindowsImage -ImagePath $installWim)
      $imageCount = $wimImages.Count
      Write-CleanLine "Converting install.wim ($imageCount index(es)) to install.esd..."
      $installEsd = Join-Path $distDir "sources\install.esd"
      if (Test-Path $installEsd) { Remove-Item $installEsd -Force }
      for ($idx = 1; $idx -le $imageCount; $idx++) {
        Write-CleanLine "Exporting index $idx of $imageCount to install.esd..."
        & dism.exe /Export-Image /SourceImageFile:$installWim /SourceIndex:$idx /DestinationImageFile:$installEsd /Compress:recovery
        if ($LASTEXITCODE -ne 0) { throw "dism /Export-Image failed on index $idx with exit code $LASTEXITCODE" }
      }
      Remove-Item $installWim -Force
    }

    if ($wimOnly) {
      Write-CleanLine "wimOnly mode active. Staging serviced WIM artifact..."
      $finalArtifact = Join-Path $distDir "sources\install.wim"
      $targetExt = ".wim"
      $outWimName = "$name-$($edInfo.Short)$targetExt"
      $outWimPath = Join-Path $destinationDirectory $outWimName

      if (-not (Test-Path $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
      }

      Copy-Item -Path $finalArtifact -Destination $outWimPath -Force
      Write-CleanLine "Serviced image saved to $outWimPath"

      # Also preserve cdimage.exe if available so assembly jobs don't need to re-fetch
      $cdimageExe = Get-ChildItem -Path $buildDirectory -Filter "cdimage.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
      if ($cdimageExe -and (Test-Path $cdimageExe)) {
        Copy-Item -Path $cdimageExe -Destination (Join-Path $destinationDirectory "cdimage.exe") -Force
      }

      # Write JSON metadata
      $wimImages = @(Get-WindowsImage -ImagePath $outWimPath)
      $wimMetadata = [PSCustomObject]@{
        name       = $name
        edition    = $edInfo.Short
        build      = $iso.build
        version    = $verbuild
        tags       = $tag
        wimFile    = $outWimName
        images     = @($wimImages | ForEach-Object {
          $imgVer = $verbuild
          try {
            $detailed = Get-WindowsImage -ImagePath $outWimPath -Index $_.ImageIndex
            if ($detailed.PSObject.Properties['MajorVersion'] -and $detailed.MajorVersion) {
              $imgVer = "$($detailed.MajorVersion).$($detailed.MinorVersion).$($detailed.Build).$($detailed.SPBuild)"
            }
          } catch {}
          [PSCustomObject]@{ index = $_.ImageIndex; name = $_.ImageName; version = $imgVer }
        })
      }
      $wimMetadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $destinationDirectory "$name-$($edInfo.Short).json")

      if ($env:GITHUB_ENV) {
        Write-Output "WIM_FILE=$outWimPath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
        Write-Output "EDITION_NAME=$($edInfo.Short)" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
        Write-Output "ISO_NAME=$name-$($edInfo.Short)" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
      }

      # Clean up build scratch directory so runner disk is freed and artifacts aren't bloated
      if (Test-Path $buildDirectory) {
        Write-CleanLine "Cleaning build scratch directory: $buildDirectory..."
        Remove-Item -Path $buildDirectory -Recurse -Force -ErrorAction SilentlyContinue
      }

      Write-CleanLine "wimOnly completed successfully for $($edInfo.Short)."
      return
    }

    # Check for custom base media (base.7z)
    $finalMediaDir = $distDir
    $resolvedBase7z = if ($base7zPath -and (Test-Path $base7zPath)) { 
      $base7zPath 
    } elseif (Test-Path "E:\ISO\Win11-HomeSL-25H2-Lite-26200.7921\base.7z") { 
      "E:\ISO\Win11-HomeSL-25H2-Lite-26200.7921\base.7z" 
    } elseif (Test-Path (Join-Path $PSScriptRoot "base.7z")) { 
      Join-Path $PSScriptRoot "base.7z" 
    } else { 
      $null 
    }

    if ($resolvedBase7z) {
      Write-CleanLine "Integrating custom base media from $resolvedBase7z..."
      $baseExtractDir = Join-Path $buildDirectory "BaseMedia"
      New-Item -ItemType Directory -Path $baseExtractDir -Force | Out-Null
      & 7z x $resolvedBase7z -o"$baseExtractDir" -y | Out-Null
      if (-not (Test-Path "$baseExtractDir\sources")) { New-Item -ItemType Directory -Path "$baseExtractDir\sources" -Force | Out-Null }
      if ($esd) {
        Copy-Item -Path (Join-Path $distDir "sources\install.esd") -Destination "$baseExtractDir\sources\install.esd" -Force
      } else {
        Copy-Item -Path (Join-Path $distDir "sources\install.wim") -Destination "$baseExtractDir\sources\install.wim" -Force
      }
      $finalMediaDir = $baseExtractDir
      Write-CleanLine "Base media integration complete. Using $finalMediaDir for ISO creation."
    }

    # Build ISO with cdimage.exe
    $cdimageExe = Join-Path $buildDirectory "bin\cdimage.exe"
    if (-not (Test-Path $cdimageExe)) {
      $cdimageExe = Get-ChildItem -Path $buildDirectory -Filter "cdimage.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
    }
    if (-not $cdimageExe) {
      $cdCmd = Get-Command cdimage.exe -ErrorAction SilentlyContinue
      if ($cdCmd) { $cdimageExe = $cdCmd.Source }
    }
    if (-not $cdimageExe) {
      throw "cdimage.exe could not be found to build the ISO."
    }

    $finalIsoName = if ($debloat) {
      $osPrefix = if ($name -match '^windows-10') { 'Win10' } else { 'Win11' }
      $ednShort = $edInfo.Short
      "$osPrefix-$ednShort-$verbuild-Lite-$($iso.build)"
    } else {
      $title
    }

    $createdIsoPath = "$buildDirectory\$finalIsoName.iso"
    $dvdLabel = ($finalIsoName -replace '[^A-Za-z0-9_]','_')
    if ($dvdLabel.Length -gt 32) { $dvdLabel = $dvdLabel.Substring(0, 32) }
    Write-CleanLine "Packaging final ISO with cdimage: $createdIsoPath (Label: $dvdLabel)..."
    
    $bootEtfs = Join-Path $finalMediaDir "boot\etfsboot.com"
    $bootEfi  = Join-Path $finalMediaDir "efi\Microsoft\boot\efisys.bin"
    
    if ($architecture -ne "arm64" -and (Test-Path $bootEtfs)) {
      & $cdimageExe "-bootdata:2#p0,e,b$bootEtfs#pEF,e,b$bootEfi" -o -m -u2 -udfver102 -l$dvdLabel $finalMediaDir $createdIsoPath
    } else {
      & $cdimageExe "-bootdata:1#pEF,e,b$bootEfi" -o -m -u2 -udfver102 -l$dvdLabel $finalMediaDir $createdIsoPath
    }
    if ($LASTEXITCODE -ne 0) { throw "cdimage.exe failed with exit code $LASTEXITCODE" }
    Write-CleanLine "ISO generated successfully: $createdIsoPath"
  }

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
