<#
.SYNOPSIS
    Purge Windows Defender, Security Center, SmartScreen, and BrowserCore
.DESCRIPTION
    Decouples Windows Defender antivirus, SecurityHealthService, SmartScreen, and BrowserCore offline.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MountDir,

    [Parameter(Mandatory = $false)]
    [string]$CustomRegPath = "",

    [Parameter(Mandatory = $false)]
    [string]$NSudoPath = "",

    [Parameter(Mandatory = $false)]
    [hashtable]$DebloatProfile = @{}
)

$ErrorActionPreference = 'Stop'

# Guard: Allow opting out of Defender removal
$RemoveDefender = $true
if ($DebloatProfile.ContainsKey('RemoveDefender')) {
    $RemoveDefender = [bool]$DebloatProfile['RemoveDefender']
}

if ($RemoveDefender) {
    Write-Step "Purging Windows Defender and Security Center..."

    $defenderFolders = @(
        "$MountDir\Program Files\Windows Defender",
        "$MountDir\Program Files\Windows Security",
        "$MountDir\Program Files (x86)\Windows Defender",
        "$MountDir\ProgramData\Microsoft\Windows Defender",
        "$MountDir\ProgramData\Microsoft\Windows Security Health",
        "$MountDir\Windows\System32\HealthAttestationClient",
        "$MountDir\Windows\System32\SecurityHealth",
        "$MountDir\Windows\System32\WebThreatDefSvc",
        "$MountDir\Windows\System32\WindowsPowerShell\v1.0\Modules\Defender",
        "$MountDir\Windows\System32\WindowsPowerShell\v1.0\Modules\DefenderPerformance",
        "$MountDir\Windows\SysWOW64\WindowsPowerShell\v1.0\Modules\Defender",
        "$MountDir\Windows\SysWOW64\WindowsPowerShell\v1.0\Modules\DefenderPerformance"
    )
    foreach ($dir in $defenderFolders) {
        if (Test-Path $dir) {
            Remove-ForceDirectory $dir
            Write-Success "Deleted Defender directory: $dir"
        }
    }

    $appGuardWim = "$MountDir\Windows\Containers\serviced\WindowsDefenderApplicationGuard.wim"
    if (Test-Path $appGuardWim) {
        Remove-ForceFile $appGuardWim
        Write-Success "Deleted Application Guard WIM: $(Split-Path $appGuardWim -Leaf)"
    }

    $defenderBinaries = @(
        "$MountDir\Windows\System32\SecurityHealthService.exe",
        "$MountDir\Windows\System32\SecurityHealthSystray.exe",
        "$MountDir\Windows\System32\SecurityHealthHost.exe",
        "$MountDir\Windows\System32\SecurityHealthAgent.dll",
        "$MountDir\Windows\System32\SecurityHealthCore.dll",
        "$MountDir\Windows\System32\SecurityHealthProxyStub.dll",
        "$MountDir\Windows\System32\SecurityHealthSSO.dll",
        "$MountDir\Windows\System32\SecurityHealthSsoUdk.dll",
        "$MountDir\Windows\System32\SecurityHealthUdk.dll",
        "$MountDir\Windows\System32\webthreatdefsvc.dll",
        "$MountDir\Windows\System32\webthreatdefusersvc.dll",
        "$MountDir\Windows\System32\wscadminui.exe",
        "$MountDir\Windows\System32\wscui.cpl",
        "$MountDir\Windows\System32\wscisvif.dll",
        "$MountDir\Windows\System32\wscproxystub.dll",
        "$MountDir\Windows\SysWOW64\wscisvif.dll",
        "$MountDir\Windows\SysWOW64\wscproxystub.dll"
    )
    foreach ($bin in $defenderBinaries) {
        if (Test-Path $bin) {
            Remove-ForceFile $bin
            Write-Success "Deleted Defender binary: $(Split-Path $bin -Leaf)"
        }
    }

    $defenderServices = @(
        "Sense", "WdBoot", "WdFilter", "WdNisDrv", "WdNisSvc",
        "WinDefend", "SecurityHealthService", "webthreatdefsvc", "webthreatdefusersvc",
        "MDCoreSvc", "SgrmBroker", "SgrmAgent", "MsSecWfp", "MsSecFlt", "MsSecCore"
    )
    foreach ($svc in $defenderServices) {
        Remove-RegKey "HKLM\SYSTEM\CurrentControlSet\Services\$svc"
        Write-Success "Deleted Defender service: $svc"
    }

    Remove-ScheduledTask "\Microsoft\Windows\Windows Defender"
    Remove-ScheduledTask "\Microsoft\Windows\AppID\SmartScreenSpecific"
    Write-Success "Purged Windows Defender and SmartScreen scheduled tasks."

    $defenderRegKeys = @(
        "HKLM\SOFTWARE\Microsoft\Windows Defender",
        "HKLM\SOFTWARE\Microsoft\Windows Defender Security Center",
        "HKLM\SOFTWARE\Microsoft\Windows Advanced Threat Protection",
        "HKLM\SOFTWARE\Microsoft\Windows Security Health",
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows Defender",
        "HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\DefenderApiLogger",
        "HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\DefenderAuditLogger",
        "HKCR\*\shellex\ContextMenuHandlers\EPP",
        "HKCR\Directory\shellex\ContextMenuHandlers\EPP",
        "HKCR\Drive\shellex\ContextMenuHandlers\EPP",
        "HKLM\SOFTWARE\Classes\CLSID\{09A47860-11B0-4DA5-AFA5-26D86198A780}",
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Windows Defender",
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-Windows Defender/WHC",
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\NIS-Driver-WFP/Diagnostic",
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels\Microsoft-Windows-Windows Defender/Operational"
    )
    foreach ($rk in $defenderRegKeys) {
        Remove-RegKey $rk
    }

    Remove-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "SecurityHealth"
    Remove-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "WindowsDefender"
    Remove-RegValue "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" "SecurityHealth"
    Remove-RegValue "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" "WindowsDefender"
    Remove-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" "SecurityHealth"
    Remove-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" "WindowsDefender"
    Write-Success "Deleted SecurityHealth and WindowsDefender startup run values."

    $polKey = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $currVisibility = Get-RegValue -Key $polKey -ValueName "SettingsPageVisibility"
    if (-not $currVisibility) {
        Set-RegValue $polKey "SettingsPageVisibility" "hide:windowsdefender" "REG_SZ"
        Write-Success "Configured SettingsPageVisibility to hide dead Windows Security page in Settings."
    } elseif ($currVisibility -notmatch '(?i)\bwindowsdefender\b') {
        if ($currVisibility -like 'hide:*') {
            Set-RegValue $polKey "SettingsPageVisibility" "$currVisibility;windowsdefender" "REG_SZ"
        } else {
            Set-RegValue $polKey "SettingsPageVisibility" "hide:$currVisibility;windowsdefender" "REG_SZ"
        }
        Write-Success "Appended windowsdefender to existing SettingsPageVisibility list."
    } else {
        Write-Success "Windows Security is already hidden in SettingsPageVisibility."
    }

    Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*SecHealthUI*"
    Remove-OfflineProvisionedAppxPackage -MountDir $MountDir -Pattern "*SecHealthUI*"
    $inboxAppsKey = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications"
    foreach ($k in (Get-RegSubKey $inboxAppsKey "SecHealthUI")) {
        Remove-RegKey $k
    }

    Write-Step "Purging SmartScreen, AppRep, and BrowserCore..."
    $smartScreenFiles = @(
        "$MountDir\Windows\System32\smartscreen.exe",
        "$MountDir\Windows\System32\smartscreen.dll",
        "$MountDir\Windows\System32\smartscreenps.dll",
        "$MountDir\Windows\System32\en-US\smartscreen.exe.mui",
        "$MountDir\Windows\SysWOW64\smartscreen.dll",
        "$MountDir\Windows\SysWOW64\smartscreenps.dll"
    )
    foreach ($f in $smartScreenFiles) {
        if (Test-Path $f) {
            Remove-ForceFile $f
            Write-Success "Deleted SmartScreen binary: $(Split-Path $f -Leaf)"
        }
    }

    Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern "smartscreen*.mui" -Recurse

    Remove-OfflineSystemApp -MountDir $MountDir -Pattern "Microsoft.Windows.AppRep.ChxApp_*"
    $inboxAppsKey = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications"
    foreach ($k in (Get-RegSubKey $inboxAppsKey "AppRep")) {
        Remove-RegKey $k
    }

    $browserCoreDir = "$MountDir\Windows\BrowserCore"
    if (Test-Path $browserCoreDir) {
        Remove-ForceDirectory $browserCoreDir
        Write-Success "Purged BrowserCore directory: $browserCoreDir"
    }

    Set-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" "SmartScreenEnabled" "off" "REG_SZ"
    Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "EnableSmartScreen" 0
    Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "ShellSmartScreenLevel" "Off" "REG_SZ"
    Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy" "VerifiedAndReputablePolicyState" 0

    Remove-RegKey "HKCR\CLSID\{25442526-787D-42FE-AE70-BD2A56230B0B}"
    Remove-RegKey "HKCR\WOW6432Node\CLSID\{25442526-787D-42FE-AE70-BD2A56230B0B}"

    $bcHosts = @(
        "HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore",
        "HKLM\SOFTWARE\WOW6432Node\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore",
        "HKCU\Software\Google\Chrome\NativeMessagingHosts\com.microsoft.browsercore",
        "HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.microsoft.browsercore",
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Edge\NativeMessagingHosts\com.microsoft.browsercore",
        "HKLM\SOFTWARE\Mozilla\NativeMessagingHosts\com.microsoft.browsercore",
        "HKLM\SOFTWARE\WOW6432Node\Mozilla\NativeMessagingHosts\com.microsoft.browsercore"
    )
    foreach ($bh in $bcHosts) {
        Remove-RegKey $bh
    }
    Write-Success "Configured SmartScreen & BrowserCore neutralizations."
} else {
    Write-Info "Preserving Windows Defender, SecurityHealth, SmartScreen, and BrowserCore (RemoveDefender is disabled)."
}
