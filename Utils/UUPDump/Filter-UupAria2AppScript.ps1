<#
.SYNOPSIS
    Filters UUPDump aria2 download scripts for Microsoft Store Apps.
.DESCRIPTION
    Prunes files\aria2_script.<random>.txt so aria2 only downloads whitelisted apps
    and required framework dependencies, avoiding ~3 GB of unwanted store apps.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$AriaScriptPath = "",

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "ConvertConfig.ini",

    [Parameter(Mandatory = $false)]
    [string]$CustomAppsFile = "CustomAppsList.txt",

    [Parameter(Mandatory = $false)]
    [string]$FilterConfigFile = "files\apps_filter_config.json"
)

Set-StrictMode -Off

function Write-FilterLog([string]$Message) {
    if (Get-Command Write-CleanLine -ErrorAction SilentlyContinue) {
        Write-CleanLine "[UUP Aria2 Filter] $Message"
    } else {
        Write-Host "[UUP Aria2 Filter] $Message"
    }
}

if ([string]::IsNullOrWhiteSpace($AriaScriptPath)) {
    return
}

if (-not (Test-Path $AriaScriptPath)) {
    Write-Warning "[UUP Aria2 Filter] Aria script not found at $AriaScriptPath. Skipping filter."
    exit 0
}

# 1. Resolve configuration
$enabledApps = [System.Collections.Generic.List[string]]::new()
$removeFrameworkDependencies = $false
$excludedDependencies = [System.Collections.Generic.List[string]]::new()
$configured7z = $null

if (Test-Path $FilterConfigFile) {
    try {
        $json = Get-Content -Path $FilterConfigFile -Raw | ConvertFrom-Json
        if ($json.EnabledApps) {
            foreach ($app in $json.EnabledApps) { $enabledApps.Add($app.ToString().Trim()) }
        }
        if ($json.RemoveFrameworkDependencies -eq $true) {
            $removeFrameworkDependencies = $true
        }
        if ($json.ExcludedDependencies) {
            foreach ($ex in $json.ExcludedDependencies) { $excludedDependencies.Add($ex.ToString().Trim()) }
        }
        if ($json.SevenZipPath) {
            $configured7z = $json.SevenZipPath.ToString().Trim()
        }
    } catch {
        Write-Warning "[UUP Aria2 Filter] Failed to parse $FilterConfigFile : $_"
    }
}

if ($enabledApps.Count -eq 0 -and (Test-Path $CustomAppsFile)) {
    Get-Content -Path $CustomAppsFile | ForEach-Object {
        $trimmed = $_.Trim()
        if ($trimmed -and -not $trimmed.StartsWith('#')) {
            $enabledApps.Add($trimmed)
        }
    }
}

# Check ConvertConfig.ini for SkipApps=1
if (Test-Path $ConfigFile) {
    $iniContent = Get-Content -Path $ConfigFile -Raw
    if ($iniContent -match '(?m)^\s*SkipApps\s*=\s*1\b') {
        Write-FilterLog "SkipApps=1 detected in $ConfigFile. Truncating Store Apps aria2 script to 0 downloads."
        [System.IO.File]::WriteAllText($AriaScriptPath, "")
        exit 0
    }
}

if ($enabledApps.Count -eq 0) {
    Write-FilterLog "No enabled apps configured. Keeping all apps as default."
    exit 0
}

# 2. Read and parse original aria2 script
$rawText = [System.IO.File]::ReadAllText($AriaScriptPath)
$blocks = $rawText -split '(?m)(?=^https?://)'
if ($blocks.Count -le 1) {
    Write-FilterLog "Aria script contains $($blocks.Count) blocks. Skipping filter."
    exit 0
}

# Locate AggregatedMetadata block
$metaBlock = $blocks | Where-Object { $_ -match 'AggregatedMetadata.*\.cab' } | Select-Object -First 1
$metaOutFile = $null
if ($metaBlock -and $metaBlock -match '(?m)^\s*out=(.*)$') {
    $metaOutFile = $Matches[1].Trim()
}

$allowedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if ($metaOutFile) {
    $allowedFiles.Add($metaOutFile) | Out-Null
}

$compDbSuccess = $false
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("uup_aria_filter_" + [System.IO.Path]::GetRandomFileName())

try {
    if (-not $metaBlock) {
        throw "AggregatedMetadata block not found in aria2 script."
    }
    $metaUrl = ($metaBlock -split "`r?`n")[0].Trim()
    if (-not $metaUrl) {
        throw "AggregatedMetadata download URL could not be resolved."
    }

    # Locate 7z
    $candidate7z = @(
        $configured7z,
        (Join-Path $PWD "bin\7z.exe"),
        (Join-Path $PWD "bin64\7z.exe"),
        (Join-Path $PSScriptRoot "..\..\External\7za\7z.exe"),
        (Join-Path $PSScriptRoot "..\..\External\7z\7z.exe")
    )
    $cmd7z = Get-Command 7z, 7za, 7zr -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd7z) { $candidate7z += $cmd7z.Source }

    $sevenZip = $candidate7z | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $sevenZip) {
        throw "7z.exe with CAB support not found in bin\ or PATH."
    }

    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $tempCab = Join-Path $tempDir "AggregatedMetadata.cab"

    # Download AggregatedMetadata.cab (~2.5 MB)
    $aria2Bin = @(
        (Join-Path $PWD "files\aria2c.exe"),
        (Join-Path $PWD "bin\aria2c.exe")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    $downloaded = $false
    if ($aria2Bin) {
        try {
            & $aria2Bin --no-conf --console-log-level=error --allow-overwrite=true -d $tempDir -o "AggregatedMetadata.cab" $metaUrl 2>&1 | Out-Null
            if ((Test-Path $tempCab) -and (Get-Item $tempCab).Length -gt 0) { $downloaded = $true }
        } catch {}
    }
    if (-not $downloaded) {
        Invoke-WebRequest -Uri $metaUrl -OutFile $tempCab -UseBasicParsing
    }

    if (-not (Test-Path $tempCab) -or (Get-Item $tempCab).Length -eq 0) {
        throw "Failed to download $metaOutFile"
    }

    # Fast targeted extraction of App CompDB
    & $sevenZip e "$tempCab" -o"$tempDir" "*CompDB_App*.xml.cab" -y > $null
    Get-ChildItem -Path $tempDir -Filter "*CompDB_App*.xml.cab" | ForEach-Object {
        & $sevenZip e $_.FullName -o"$tempDir" "*.xml" -y > $null
    }

    $xmlFiles = Get-ChildItem -Path $tempDir -Filter "*.xml"
    if ($xmlFiles.Count -eq 0) {
        throw "No App CompDB XML found inside metadata cab."
    }

    foreach ($xmlFile in $xmlFiles) {
        $xml = [xml](Get-Content -Path $xmlFile.FullName)
        $packMap = @{}
        foreach ($pkg in $xml.CompDB.Packages.Package) {
            $packMap[$pkg.ID] = (Split-Path ($pkg.Payload.PayloadItem.Path) -Leaf)
        }

        foreach ($feat in $xml.CompDB.Features.Feature) {
            $fid = $feat.FeatureID
            $isFw = ($feat.Type -eq 'MSIXFramework')

            $keep = $false
            if ($isFw) {
                if (-not $removeFrameworkDependencies) {
                    $isExcluded = $false
                    foreach ($ex in $excludedDependencies) {
                        if ($fid -like "$ex*" -or $fid -eq $ex) { $isExcluded = $true; break }
                    }
                    if (-not $isExcluded) { $keep = $true }
                }
            } else {
                foreach ($app in $enabledApps) {
                    if ($fid -like "$app*" -or $fid -eq $app) {
                        $keep = $true
                        break
                    }
                }
            }

            if ($keep) {
                foreach ($pkg in $feat.Packages.Package) {
                    if ($packMap.ContainsKey($pkg.ID)) {
                        $allowedFiles.Add($packMap[$pkg.ID]) | Out-Null
                    }
                }
            }
        }
    }

    $compDbSuccess = $true
    Write-FilterLog "Resolved $($allowedFiles.Count) required package files using AggregatedMetadata CompDB."
}
catch {
    Write-Warning "[UUP Aria2 Filter] CompDB resolution failed: $_. Falling back to regex whitelist filter."
}
finally {
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 3. Filter blocks in aria2 script
$filteredBlocks = [System.Collections.Generic.List[string]]::new()
$droppedCount = 0

foreach ($b in $blocks) {
    $trimmed = $b.Trim()
    if (-not $trimmed) { continue }

    if ($b -match '(?m)^\s*out=(.*)$') {
        $outName = $Matches[1].Trim()
        $keep = $false

        if ($compDbSuccess) {
            $keep = $allowedFiles.Contains($outName)
        } else {
            # Regex fallback
            if ($outName -eq $metaOutFile) {
                $keep = $true
            } else {
                foreach ($app in $enabledApps) {
                    if ($outName -like "*$app*") { $keep = $true; break }
                }
                if (-not $keep -and -not $removeFrameworkDependencies) {
                    if ($outName -match '(?i)(VCLibs|UI\.Xaml|NET\.Native|WindowsAppRuntime)') {
                        $isExcluded = $false
                        foreach ($ex in $excludedDependencies) {
                            if ($outName -like "*$ex*") { $isExcluded = $true; break }
                        }
                        if (-not $isExcluded) { $keep = $true }
                    }
                }
            }
        }

        if ($keep) {
            $filteredBlocks.Add($b.TrimEnd())
        } else {
            $droppedCount++
        }
    }
}

[System.IO.File]::WriteAllText($AriaScriptPath, ($filteredBlocks -join "`n`n") + "`n")
Write-FilterLog "Filtering complete: Retained $($filteredBlocks.Count) packages, skipped $droppedCount unneeded packages."
