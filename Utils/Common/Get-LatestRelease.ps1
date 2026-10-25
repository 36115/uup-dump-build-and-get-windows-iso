<#
.SYNOPSIS
    Upstream release discovery and remote archive retrieval helpers.
.DESCRIPTION
    Provides reusable functions across all tooling scripts to:
    - Query latest release tags from GitHub and upstream mirrors without rate limits.
    - Download and extract remote archives with automatic temp file cleanup and filtering.
    - Safely download standalone remote binary files.
#>

function Get-LatestGitHubTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Repository,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Fallback = ""
    )

    try {
        $req = [System.Net.HttpWebRequest]::Create("https://github.com/$Repository/releases/latest")
        $req.AllowAutoRedirect = $false
        $req.UserAgent = "Mozilla/5.0"
        $req.Timeout = 5000
        $res = $req.GetResponse()
        $loc = $res.GetResponseHeader("Location")
        $res.Close()
        if ($loc) { return ($loc -split "/")[-1] }
    } catch { }
    return $Fallback
}

function Get-LatestWimLibVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Fallback = "1.14.5"
    )

    try {
        $html = (Invoke-WebRequest -Uri "https://wimlib.net/" -UseBasicParsing -TimeoutSec 5).Content
        if ($html -match 'wimlib-([0-9]+\.[0-9]+\.[0-9]+)-windows-') { return $matches[1] }
    } catch { }
    return $Fallback
}

function Save-RemoteFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFile,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 30,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 2,

        [Parameter(Mandatory = $false)]
        [switch]$Quiet
    )

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $parent = Split-Path $DestinationFile -Parent
        if ($parent -and -not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null
        }
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Invoke-WebRequest -Uri $Uri -OutFile $DestinationFile -UseBasicParsing -TimeoutSec $TimeoutSec
                if (Test-Path $DestinationFile) { return $true }
            } catch {
                if ($attempt -ge $MaxRetries) { throw }
                Start-Sleep -Seconds 2
            }
        }
        return $false
    } catch {
        if (-not $Quiet) {
            Write-Warning "Failed to download $($Uri): $_"
        } else {
            Write-Host "      [INFO] Remote file download failed ($($Uri)): $($_.Exception.Message)" -ForegroundColor Gray
        }
        return $false
    }
}

function Expand-RemoteArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string[]]$Files = @(),

        [Parameter(Mandatory = $false)]
        [string]$PathFilter = "",

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 30,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 2,

        [Parameter(Mandatory = $false)]
        [switch]$Quiet
    )

    $tempZip = Join-Path $env:TEMP "archive_$([System.IO.Path]::GetRandomFileName()).zip"
    $tempExtract = Join-Path $env:TEMP "extract_$([System.IO.Path]::GetRandomFileName())"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $downloaded = $false
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
                Invoke-WebRequest -Uri $Uri -OutFile $tempZip -UseBasicParsing -TimeoutSec $TimeoutSec
                if (Test-Path $tempZip) {
                    $downloaded = $true
                    break
                }
            } catch {
                if ($attempt -ge $MaxRetries) { throw }
                Start-Sleep -Seconds 2
            }
        }
        if (-not $downloaded) { return $false }

        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

        if ($Files.Count -gt 0) {
            foreach ($file in $Files) {
                $found = Get-ChildItem -Path $tempExtract -Filter $file -Recurse |
                    Where-Object { -not $PathFilter -or $_.FullName -like $PathFilter } |
                    Select-Object -First 1
                if (-not $found -and $PathFilter) {
                    $found = Get-ChildItem -Path $tempExtract -Filter $file -Recurse | Select-Object -First 1
                }
                if ($found) {
                    Copy-Item -Path $found.FullName -Destination (Join-Path $DestinationPath $file) -Force
                }
            }
        } else {
            Copy-Item -Path "$tempExtract\*" -Destination $DestinationPath -Recurse -Force
        }
        return $true
    } catch {
        if (-not $Quiet) {
            Write-Warning "Failed to download/extract from $($Uri): $_"
        } else {
            Write-Host "      [INFO] Remote archive download failed ($($Uri)): $($_.Exception.Message)" -ForegroundColor Gray
        }
        return $false
    } finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
