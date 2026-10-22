<#
.SYNOPSIS
    UUP Dump API client, metadata resolver, and aria2 patch utilities.
#>

function New-QueryString([hashtable]$parameters) {
  @($parameters.GetEnumerator() | ForEach-Object { "$($_.Key)=$([System.Net.WebUtility]::UrlEncode([string]$_.Value))" }) -join '&'
}

function Invoke-UupDumpApi([string]$name, [hashtable]$body) {
  for ($n = 0; $n -lt 15; ++$n) {
    if ($n) {
      if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Waiting a bit before retrying the uup-dump api ${name} request #$n"
      } else {
        Write-Host "Waiting a bit before retrying the uup-dump api ${name} request #$n"
      }
      Start-Sleep -Seconds 10
      if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Retrying the uup-dump api ${name} request #$n"
      } else {
        Write-Host "Retrying the uup-dump api ${name} request #$n"
      }
    }
    try {
      $qs = if ($body) { '?' + (New-QueryString $body) } else { '' }
      return Invoke-RestMethod -Method Get -Uri ("https://api.uupdump.net/{0}.php{1}" -f $name, $qs)
    } catch {
      if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "WARN: failed the uup-dump api $name request: $_"
      } else {
        Write-Warning "WARN: failed the uup-dump api $name request: $_"
      }
    }
  }
  throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpIso($name, $target) {
  if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
    Write-CleanLine "Getting the $name metadata"
  } else {
    Write-Host "Getting the $name metadata"
  }
  $result = Invoke-UupDumpApi listid @{ search = $target.search }

  $result.response.builds.PSObject.Properties |
    ForEach-Object {
      $id = $_.Value.uuid
      $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{ id = $id })
      if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Processing $name $id ($uupDumpUrl)"
      } else {
        Write-Host "Processing $name $id ($uupDumpUrl)"
      }
      $_
    } |
    Where-Object {
      if ($_.Value.title -match '\.NET Framework') {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
          Write-CleanLine "Skipping, ignore .NET Framework update."
        }
        return $false
      }
      if ($_.Value.title -match 'Windows CPC OS') {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
          Write-CleanLine "Skipping, ignore Windows CPC OS."
        }
        return $false
      }
      if (!$preview) {
        $ok = ($target.search -like '*preview*') -or ($_.Value.title -notlike '*preview*')
        if (-not $ok) {
          if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Skipping.`nL1: Expected preview=false.`nL2: Got preview=true."
          }
        }
        return $ok
      }
      $true
    } |
    ForEach-Object {
      $id = $_.Value.uuid
      if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "Getting the $name $id langs metadata"
      } else {
        Write-Host "Getting the $name $id langs metadata"
      }
      $result = Invoke-UupDumpApi listlangs @{ id = $id }
      if ($result.response.updateInfo.build -ne $_.Value.build) {
        throw 'for some reason listlangs returned an unexpected build'
      }
      $_.Value | Add-Member -NotePropertyMembers @{ langs = $result.response.langFancyNames; info = $result.response.updateInfo }

      $langs = $_.Value.langs.PSObject.Properties.Name
      $eds = if ($langs -contains $lang) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
          Write-CleanLine "Getting the $name $id editions metadata"
        } else {
          Write-Host "Getting the $name $id editions metadata"
        }
        $result = Invoke-UupDumpApi listeditions @{ id = $id; lang = $lang }
        $result.response.editionFancyNames
      } else {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
          Write-CleanLine "Skipping.`nL3: Expected langs=$lang.`nL4: Got langs=$($langs -join ',')."
        }
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
          if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Skipping. Expected ring: $($allowedRings -join ', '). Got ring=$actual."
          }
          $res = $false
        }
      }

      if ($langs -notcontains $lang) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
          Write-CleanLine "Skipping. Expected langs=$lang. Got langs=$($langs -join ',')."
        }
        $res = $false
      }

      $effectiveEditionName = if (Get-Command Get-EditionInfo -ErrorAction SilentlyContinue) {
        (Get-EditionInfo $edition).Base
      } elseif (Get-Command Get-EditionName -ErrorAction SilentlyContinue) {
        Get-EditionName $edition
      } else {
        $edition
      }

      if ($effectiveEditionName -eq "Multi") {
        if (($editions -notcontains "Professional") -and ($editions -notcontains "Core")) {
          if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
            Write-CleanLine "Skipping.`nL6: Expected editions=Multi (Professional/Core). Got editions=$($editions -join ',')."
          }
          $res = $false
        }
      } elseif ($editions -notcontains $effectiveEditionName) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
          Write-CleanLine ("Skipping. Expected editions={0}.`nL7: Got editions={1}." -f $effectiveEditionName, ($editions -join ','))
        }
        $res = $false
      }

      if (!$preview -and -not ($_.Value.title -match 'version')) {
        if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
          Write-CleanLine "Skipping. Unexpected title format: missing 'version'."
        }
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

# ------------------------------
# Patch uup_download_windows.cmd with sed - quiet aria2 flags
# ------------------------------
function Patch-Aria2-Flags {
  param([string]$CmdPath)
  if (-not (Test-Path $CmdPath)) { return }

  $sed = Get-Command sed -ErrorAction SilentlyContinue
  if ($sed) {
    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
      Write-CleanLine "Patching aria2 flags in $CmdPath using sed."
    }
    # Remove conflicting flags first
    & $sed.Path -ri 's/\s--console-log-level=\w+\b//g; s/\s--summary-interval=\d+\b//g; s/\s--download-result=\w+\b//g; s/\s--enable-color=\w+\b//g; s/\s-(q|quiet(=\w+)?)\b//g' $CmdPath
    # Inject quiet set right after "%aria2%"
    & $sed.Path -ri 's@("%aria2%"\s+)@\1--quiet=true --console-log-level=error --summary-interval=0 --download-result=hide --enable-color=false @g' $CmdPath
    return
  }

  # Fallback: PowerShell regex (preserves UTF-16LE)
  if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
    Write-CleanLine "sed not found. Patching aria2 flags in $CmdPath using PowerShell fallback."
  }
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


function Get-UupArchitecture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )
    if ($Architecture -eq "x64") { "amd64" } else { "arm64" }
}

function Get-UupTargetRing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetName
    )
    if ($TargetName -match 'beta|dev|wif|canary') {
        return @('beta','dev','wif','canary').Where({$TargetName -match $_})[0]
    }
    return $null
}

function Get-UupTargetDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetName,
        [Parameter(Mandatory = $false)]
        [string]$Architecture = "amd64",
        [Parameter(Mandatory = $false)]
        [string]$Revision = "",
        [Parameter(Mandatory = $false)]
        [string]$Edition = "pro"
    )

    $edInfo = if (Get-Command Get-EditionInfo -ErrorAction SilentlyContinue) {
        Get-EditionInfo $Edition
    } elseif (Get-Command Get-EditionName -ErrorAction SilentlyContinue) {
        [PSCustomObject]@{ Base = (Get-EditionName $Edition); Virtual = "" }
    } else {
        [PSCustomObject]@{ Base = $Edition; Virtual = "" }
    }

    $dotRev = if ([string]::IsNullOrWhiteSpace($Revision)) { '' } else { ".$Revision" }
    $spaceRev = if ([string]::IsNullOrWhiteSpace($Revision)) { '' } else { " $Revision" }

    $targets = @{
        "windows-10"           = @{ search="windows 10 19045$dotRev $Architecture"; edition=$edInfo.Base; virtualEdition=$edInfo.Virtual }
        "windows-11old"        = @{ search="windows 11 22631$dotRev $Architecture"; edition=$edInfo.Base; virtualEdition=$edInfo.Virtual }
        "windows-11"           = @{ search="windows 11 26100$dotRev $Architecture"; edition=$edInfo.Base; virtualEdition=$edInfo.Virtual }
        "windows-11new"        = @{ search="windows 11 26200$dotRev $Architecture"; edition=$edInfo.Base; virtualEdition=$edInfo.Virtual }
        "windows-11beta"       = @{ search="windows 11 26120$dotRev $Architecture"; edition=$edInfo.Base; ring="Beta"; virtualEdition=$edInfo.Virtual }
        "windows-11dev"        = @{ search="windows 11 26220$dotRev $Architecture"; edition=$edInfo.Base; ring="Wif"; virtualEdition=$edInfo.Virtual }
        "windows-1126h1"       = @{ search="windows 11 28000$dotRev $Architecture"; edition=$edInfo.Base; virtualEdition=$edInfo.Virtual }
        "windows-1126h2"       = @{ search="windows 11 26300$dotRev $Architecture"; edition=$edInfo.Base; virtualEdition=$edInfo.Virtual }
        "windows-1126h2beta"   = @{ search="windows 11 26340$dotRev $Architecture"; edition=$edInfo.Base; virtualEdition=$edInfo.Virtual }
        "windows-dev"          = @{ search="windows 11 26300$dotRev $Architecture"; edition=$edInfo.Base; ring="Dev"; virtualEdition=$edInfo.Virtual }
        "windows-canary"       = @{ search="windows 11$spaceRev $Architecture"; edition=$edInfo.Base; ring="Canary"; virtualEdition=$edInfo.Virtual }
    }

    if ($targets.ContainsKey($TargetName)) {
        return $targets[$TargetName]
    }
    throw "Target '$TargetName' not found in known UUPDump target definitions."
}

function Get-UupVersionBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $false)]
        [string]$Build = "",
        [Parameter(Mandatory = $false)]
        [bool]$IsPreview = $false,
        [Parameter(Mandatory = $false)]
        [string]$Ring = ""
    )
    if (-not $IsPreview) {
        if ($Title -match 'version') {
            $parts = @($Title -split 'version\s*')
            if ($parts.Count -lt 2) { throw "Unexpected title format, split resulted in less than 2 parts: $($parts -join '|')" }
            return ($parts[1] -split '[\s\(]' | Select-Object -First 1)
        } else {
            if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
                Write-CleanLine "WARN: Unexpected title format: missing 'version'. Using build number fallback."
            }
            return $Build
        }
    } else {
        if ($Ring) { return $Ring.ToUpper() }
        return $Build
    }
}