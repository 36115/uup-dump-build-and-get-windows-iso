<#
.SYNOPSIS
    Logging and stream progress helpers.
.DESCRIPTION
    Provides reusable terminal output functions including ANSI cleaning,
    line deduplication, and DISM bucketed progress parsing.
#>

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
