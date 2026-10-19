<#
.SYNOPSIS
    Remove Windows Telemetry, Diagnostics, WinSAT, and Error Reporting
.DESCRIPTION
    Purges DiagTrack, CEIP, DeviceCensus, AppCompat, Windows Error Reporting, AeDebug, Performance Monitor, WinSAT, and Kernel Debug transports.
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

Write-Step "Deleting Telemetry Binaries and Services..."
$telemetryBinaries = @(
    "$MountDir\Windows\System32\diagtrack.dll",
    "$MountDir\Windows\System32\moshost.dll",
    "$MountDir\Windows\System32\PhoneService.dll"
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
$insightsDirs = @(
    "$MountDir\ProgramData\Microsoft\RAC",
    "$MountDir\ProgramData\Microsoft\Diagnosis\DownloadedSettings",
    "$MountDir\Windows\System32\appraiser",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Device Information",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Customer Experience Improvement Program",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Kernel\La57Cleanup",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Maintenance\WinSAT",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\RemoteAssistance\RemoteAssistanceTask",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Windows Media Sharing\UpdateLibrary",
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Work Folders"
)
foreach ($dir in $insightsDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged Quality Insights directory: $(Split-Path $dir -Leaf)"
    }
}

$insightsBinaries = @(
    "$MountDir\Windows\System32\DeviceCensus.exe",
    "$MountDir\Windows\System32\invagent.dll",
    "$MountDir\Windows\System32\appraiser.dll",
    "$MountDir\Windows\System32\appraiser.dat",
    "$MountDir\Windows\System32\compatelrunner.exe",
    "$MountDir\Windows\System32\Win32CompatibilityAppraiserCSP.dll",
    "$MountDir\Windows\SysWOW64\DeviceCensus.exe",
    "$MountDir\Windows\SysWOW64\invagent.dll",
    "$MountDir\Windows\SysWOW64\appraiser.dll",
    "$MountDir\Windows\SysWOW64\compatelrunner.exe"
)
foreach ($bin in $insightsBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Quality Insights binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern @("*DeviceCensus*.mui", "*invagent*.mui", "*appraiser*.mui", "*compatelrunner*.mui") -Recurse

$insightTaskTrees = @(
    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Device Information",
    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Customer Experience Improvement Program"
)
foreach ($tree in $insightTaskTrees) {
    Remove-RegKey $tree
}

Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableInventory" 1
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "AITEnable" 0
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceCensus" "DisableDeviceCensus" 1
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DisableOneSettingsDownloads" 1

Remove-ScheduledTask @(
    "\Microsoft\Windows\Device Information\Device",
    "\Microsoft\Windows\Device Information\Device User",
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator"
)
Write-Success "Purged Quality Insights files, tasks, and enforced telemetry policies."

Write-Step "Purging Windows Error Reporting (WER) & Neutralizing AeDebug..."
$werDirs = @(
    "$MountDir\Windows\System32\Tasks\Microsoft\Windows\Windows Error Reporting"
)
foreach ($dir in $werDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged WER directory: $(Split-Path $dir -Leaf)"
    }
}

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
Remove-ScheduledTask "\Microsoft\Windows\Windows Error Reporting"
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "DoReport" 0
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "LoggingDisabled" 1
Write-Success "Neutralized WER and AeDebug post-mortem hooks."

Write-Step "Purging Performance Monitor & System Monitor Control (sysmon.ocx)..."
$perfmonBinaries = @(
    "$MountDir\Windows\System32\sysmon.ocx",
    "$MountDir\Windows\SysWOW64\sysmon.ocx",
    "$MountDir\Windows\System32\perfmon.exe",
    "$MountDir\Windows\System32\perfmon.msc"
)
foreach ($bin in $perfmonBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Performance Monitor binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern @("sysmon.ocx.mui", "perfmon.exe.mui", "perfmon.msc.mui") -Recurse

$perfmonShortcuts = @(
    "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Performance Monitor.lnk",
    "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Windows Tools\Performance Monitor.lnk"
)
foreach ($lnk in $perfmonShortcuts) {
    if (Test-Path $lnk) {
        Remove-ForceFile $lnk
        Write-Success "Deleted shortcut: $(Split-Path $lnk -Leaf)"
    }
}

Remove-ScheduledTask "\Microsoft\Windows\PLA"

$loggers = @(
    "Diagtrack-Listener", "SQMLogger", "WiFiSession", "ReadyBoot", "WdiContextLog",
    "Circular Kernel Context Logger", "EventLog-System"
)
foreach ($l in $loggers) {
    $lKey = "HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$l"
    if ($l -ne "EventLog-System") {
        Set-RegValue $lKey "Start" 0
    }
}

Write-Success "Purged Performance Monitor, PLA tasks, and AutoLoggers."

Write-Step "Purging Windows System Assessment Tool (WinSAT)..."
$winSatDir = "$MountDir\Windows\Performance\WinSAT"
if (Test-Path $winSatDir) {
    Remove-ForceDirectory $winSatDir
    Write-Success "Purged WinSAT directory: $winSatDir"
}

$winSatBinaries = @(
    "$MountDir\Windows\System32\WinSAT.exe",
    "$MountDir\Windows\System32\winsatapi.dll",
    "$MountDir\Windows\SysWOW64\WinSAT.exe",
    "$MountDir\Windows\SysWOW64\winsatapi.dll"
)
foreach ($bin in $winSatBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted WinSAT binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern "WinSAT*.mui" -Recurse

Remove-ScheduledTask "\Microsoft\Windows\Maintenance\WinSAT"
Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinSAT"
Write-Success "Purged WinSAT registry and scheduled task."

Write-Step "Deleting Kernel Debugging Hardware Transports & KDNET..."
$kdTransports = @(
    "$MountDir\Windows\System32\kdnet.dll",
    "$MountDir\Windows\System32\kdnet_uart16550.dll",
    "$MountDir\Windows\System32\kdusb.dll",
    "$MountDir\Windows\System32\kdcpw.dll",
    "$MountDir\Windows\System32\kdhvcom.dll"
)
foreach ($bin in $kdTransports) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Kernel Debug transport: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path "$MountDir\Windows\System32" -Pattern "kd_*_*.dll"

Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control" "SystemStartOptions" "NOEXECUTE=OPTIN NODEBUG" "REG_SZ"
Write-Success "Configured offline kernel debug suppression."
