<#
.SYNOPSIS
    Purge Telemetry, Diagnostic Tracking, and Error Reporting Services
.DESCRIPTION
    Purges DiagTrack, MapsBroker, PhoneSvc, Microsoft Usage Insights (DeviceCensus/CompatTelRunner),
    Windows Error Reporting (WER/WerFault), Performance Monitor, and WinSAT.
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

Write-Step "Purging Telemetry Services and Kernel Tracing Binaries..."
$telemetryBinaries = @(
    "$MountDir\Windows\System32\diagtrack.dll",
    "$MountDir\Windows\System32\diagtrackrunner.exe",
    "$MountDir\Windows\System32\utcutil.dll"
)
foreach ($bin in $telemetryBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted telemetry binary: $(Split-Path $bin -Leaf)"
    }
}

$telemetryServices = @("DiagTrack", "MapsBroker", "PhoneSvc")
foreach ($svc in $telemetryServices) {
    Remove-RegKey "HKLM\SYSTEM\CurrentControlSet\Services\$svc"
    Write-Success "Deleted telemetry service: $svc"
}

Write-Step "Purging Microsoft Usage and Quality Insights..."
$insightsDir = "$MountDir\Windows\System32\appraiser"
if (Test-Path $insightsDir) {
    Remove-ForceDirectory $insightsDir
    Write-Success "Purged Quality Insights directory: $(Split-Path $insightsDir -Leaf)"
}

$insightsBinaries = @(
    "$MountDir\Windows\System32\DeviceCensus.exe",
    "$MountDir\Windows\System32\invagent.dll",
    "$MountDir\Windows\System32\appraiser.dll",
    "$MountDir\Windows\System32\CompatTelRunner.exe",
    "$MountDir\Windows\System32\Win32CompatibilityAppraiserCSP.dll"
)
foreach ($bin in $insightsBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted insights binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path "$MountDir\Windows\System32" -Pattern @("*DeviceCensus*.mui", "*invagent*.mui", "*appraiser*.mui", "*CompatTelRunner*.mui") -Recurse

$insightTaskTrees = @(
    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Device Information",
    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Customer Experience Improvement Program"
)
foreach ($tree in $insightTaskTrees) {
    Remove-RegKey $tree
}

Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "MaxTelemetryAllowed" 0
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "CommercialDataOptIn" 0
Set-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 0
Set-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "MaxTelemetryAllowed" 0

Remove-ScheduledTask @(
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "\Microsoft\Windows\Application Experience\StartupAppTask",
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"
)
Write-Success "Purged Quality Insights files, tasks, and enforced telemetry policies."

Write-Step "Purging Windows Error Reporting (WER) & Neutralizing AeDebug..."
$werBinaries = @(
    "$MountDir\Windows\System32\WerFault.exe",
    "$MountDir\Windows\System32\WerFaultSecure.exe",
    "$MountDir\Windows\System32\wermgr.exe",
    "$MountDir\Windows\System32\wersvc.dll",
    "$MountDir\Windows\System32\werconcpl.dll",
    "$MountDir\Windows\System32\faultrep.dll",
    "$MountDir\Windows\SysWOW64\WerFault.exe",
    "$MountDir\Windows\SysWOW64\WerFaultSecure.exe",
    "$MountDir\Windows\SysWOW64\wermgr.exe",
    "$MountDir\Windows\SysWOW64\faultrep.dll"
)
foreach ($bin in $werBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted WER binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern @("WerFault*.mui", "wermgr*.mui", "werconcpl*.mui", "wersvc*.mui", "faultrep*.mui") -Recurse

Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Services\WerSvc" "Start" 4
Remove-RegValue "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug" "Debugger"
Set-RegValue "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AeDebug" "Auto" "0" "REG_SZ"
Remove-RegValue "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug" "Debugger"
Set-RegValue "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug" "Auto" "0" "REG_SZ"

Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "DoReport" 0
Set-RegValue "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
Remove-ScheduledTask "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
Write-Success "Purged WER binaries, suppressed WerSvc, neutralized AeDebug, and disabled error reporting."

Write-Step "Purging Performance Logs & Alerts (PLA) / PerfMon..."
$perfmonBinaries = @(
    "$MountDir\Windows\System32\perfmon.exe",
    "$MountDir\Windows\System32\perfmon.msc",
    "$MountDir\Windows\System32\sysmon.ocx",
    "$MountDir\Windows\SysWOW64\perfmon.exe",
    "$MountDir\Windows\SysWOW64\perfmon.msc",
    "$MountDir\Windows\SysWOW64\sysmon.ocx"
)
foreach ($bin in $perfmonBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted PerfMon binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern @("sysmon.ocx.mui", "perfmon.exe.mui", "perfmon.msc.mui") -Recurse

$perfmonShortcut = "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Performance Monitor.lnk"
if (Test-Path $perfmonShortcut) {
    Remove-ForceFile $perfmonShortcut
    Write-Success "Deleted shortcut: $(Split-Path $perfmonShortcut -Leaf)"
}

Remove-ScheduledTask "\Microsoft\Windows\PLA"

$loggers = @("Circular Kernel Context Logger", "EventLog-System", "Diagtrack-Listener")
foreach ($log in $loggers) {
    Remove-RegKey "HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$log"
}
Write-Success "Purged PerfMon binaries, shortcuts, PLA tasks, and WMI AutoLoggers."

Write-Step "Purging Windows System Assessment Tool (WinSAT)..."
$winSatDir = "$MountDir\Windows\System32\WinSAT"
if (Test-Path $winSatDir) {
    Remove-ForceDirectory $winSatDir
    Write-Success "Purged WinSAT directory: $winSatDir"
}

$winSatBinaries = @(
    "$MountDir\Windows\System32\WinSAT.exe",
    "$MountDir\Windows\System32\winsatapi.dll",
    "$MountDir\Windows\SysWOW64\winsatapi.dll"
)
foreach ($bin in $winSatBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted WinSAT binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern @("WinSAT*.mui", "winsatapi*.mui") -Recurse
Remove-ScheduledTask "\Microsoft\Windows\Maintenance\WinSAT"
Write-Success "Purged WinSAT binaries, directory, and maintenance task."
