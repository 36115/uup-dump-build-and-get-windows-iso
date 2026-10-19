<#
.SYNOPSIS
    Optimize Disk Footprint, Compress Filesystem, and Purge Caches
.DESCRIPTION
    Enforces CompactOS LZX compression, eliminates hiberfil.sys, purges .NET NGEN cache, temp files, and WinSxS backup manifests.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MountDir,

    [Parameter(Mandatory = $false)]
    [string]$CustomRegPath = "",

    [Parameter(Mandatory = $false)]
    [string]$NSudoPath = ""
)

$ErrorActionPreference = 'Stop'

Write-Step "Enforcing CompactOS & Post-Install LZX Compression..."
Set-RegValue "HKLM\SYSTEM\Setup" "CompactOS" 1

Write-Success "Enforced CompactOS in offline registry."

Write-Step "Disabling Hibernation to Eliminate hiberfil.sys..."
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power" "HibernateEnabled" 0
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power" "HiberFileType" 0

Write-Success "Disabled Hibernation in offline registry."

Write-Step "Purging .NET Framework Native Image Cache (NGEN) & Suppressing Tasks..."
$ngenFolders = @(
    "$MountDir\Windows\assembly\NativeImages_v4.0.30319_64",
    "$MountDir\Windows\assembly\NativeImages_v4.0.30319_32",
    "$MountDir\Windows\assembly\NativeImages_v2.0.50727_64",
    "$MountDir\Windows\assembly\NativeImages_v2.0.50727_32",
    "$MountDir\Windows\assembly\temp",
    "$MountDir\Windows\assembly\tmp"
)
foreach ($dir in $ngenFolders) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Deleted .NET Native Image Cache: $(Split-Path $dir -Leaf)"
    }
}

$ngenRegPaths = @(
    "HKLM\SOFTWARE\Microsoft\.NETFramework\v4.0.30319\NGEN\Repositories",
    "HKLM\SOFTWARE\Microsoft\.NETFramework\v2.0.50727\NGEN\Repositories",
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319\NGEN\Repositories",
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v2.0.50727\NGEN\Repositories",
    "HKLM\SOFTWARE\Microsoft\Fusion\NativeImagesIndex",
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\Fusion\NativeImagesIndex"
)
foreach ($rp in $ngenRegPaths) {
    Remove-RegKey $rp
}

Remove-ScheduledTask "\Microsoft\Windows\.NET Framework"
Write-Success "Reset .NET NGEN registry and eradicated scheduled tasks offline."

Write-Step "Purging Offline Cache and Temporary Files..."
$swDistDirs = @(
    "$MountDir\Windows\SoftwareDistribution\Download",
    "$MountDir\Windows\SoftwareDistribution\DataStore",
    "$MountDir\Windows\SoftwareDistribution\PostRebootEventCache.V2",
    "$MountDir\Windows\SoftwareDistribution\SLS"
)
foreach ($sdd in $swDistDirs) {
    if (Test-Path $sdd) { Clear-ForceDirectoryContents $sdd }
}

if (Test-Path "$MountDir\Windows\SoftwareDistribution") {
    $swDownload = "$MountDir\Windows\SoftwareDistribution\Download"
    if (-not (Test-Path $swDownload)) {
        New-Item -ItemType Directory -Path $swDownload -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

$doDirs = @(
    "$MountDir\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache",
    "$MountDir\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Logs"
)
foreach ($dod in $doDirs) {
    if (Test-Path $dod) { Clear-ForceDirectoryContents $dod }
}

$servicingLogFiles = @(
    "$MountDir\Windows\Logs\CBS\CBS.log",
    "$MountDir\Windows\Logs\DISM\dism.log"
)
foreach ($slf in $servicingLogFiles) {
    Remove-ForceFile $slf
}

Remove-ForceFilesByPattern -Path "$MountDir\Windows\Logs\CBS" -Pattern "CbsPersist_*"
$servicingLogDirs = @(
    "$MountDir\Windows\Logs\DPX",
    "$MountDir\Windows\Logs\MoSetup"
)
foreach ($sld in $servicingLogDirs) {
    Remove-ForceDirectory $sld
}

Remove-ForceDirectory "$MountDir\Windows\System32\sysprep\Panther"

Remove-ForceFilesByPattern -Path "$MountDir\Windows\inf" -Pattern "setupapi*.log"
Remove-ForceFilesByPattern -Path "$MountDir\Windows\Prefetch" -Pattern "*.pf"
Remove-ForceFilesByPattern -Path "$MountDir\Windows\Prefetch\ReadyBoot" -Pattern "*.fx"
Remove-ForceFilesByPattern -Path "$MountDir\Windows\ServiceProfiles\LocalService\AppData\Local" -Pattern "FontCache*" -Recurse
Remove-ForceFilesByPattern -Path "$MountDir\Users\Default\AppData\Local\Microsoft\Windows\Explorer" -Pattern "*cache*.db"
$werDirs = @(
    "$MountDir\ProgramData\Microsoft\Windows\WER\ReportQueue",
    "$MountDir\ProgramData\Microsoft\Windows\WER\ReportArchive",
    "$MountDir\ProgramData\Microsoft\Windows\WER\Temp"
)
foreach ($wd in $werDirs) {
    if (Test-Path $wd) { Clear-ForceDirectoryContents $wd }
}

$dumpItems = @("$MountDir\Windows\MEMORY.DMP", "$MountDir\Windows\Minidump")
foreach ($di in $dumpItems) {
    if (Test-Path $di) {
        if ((Get-Item $di).PSIsContainer) { Remove-ForceDirectory $di } else { Remove-ForceFile $di }
    }
}

Clear-ForceDirectoryContents "$MountDir\Windows\Temp"
Clear-ForceDirectoryContents "$MountDir\Users\Default\AppData\Local\Temp"
Write-Success "Purged offline cache and temp files."

Write-Step "Purging WinSxS\Backup Manifest Store..."
Clear-ForceDirectoryContents "$MountDir\Windows\WinSxS\Backup"
Write-Success "WinSxS\Backup files purged; directory anchor preserved."
