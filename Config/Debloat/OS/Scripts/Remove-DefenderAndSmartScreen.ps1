<#
.SYNOPSIS
    Purge Windows Defender, SecurityHealth, SmartScreen, and BrowserCore
.DESCRIPTION
    Purges Windows Defender directories, SecurityHealth binaries/services, SmartScreen policies/CLSIDs, and BrowserCore native messaging hosts.
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
    $RemoveDefender = $false
)

$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('RemoveDefender')) {
    $RemoveDefender = if ($RemoveDefender -is [bool]) {
        $RemoveDefender
    } else {
        ([string]$RemoveDefender -match '(?i)^(both|dual|remove|true|\$true)$')
    }
} else {
    $foundMode = $null
    if ((Test-Path variable:profileChain) -and $profileChain -and (Get-Command Get-ProfileDefenderMode -ErrorAction SilentlyContinue)) {
        $foundMode = Get-ProfileDefenderMode -ProfileChain $profileChain
    } elseif ((Test-Path variable:profileChain) -and $profileChain) {
        for ($i = $profileChain.Count - 1; $i -ge 0; $i--) {
            $cfg = $profileChain[$i].Config
            if ($cfg -and $cfg.ContainsKey('DefenderBuild') -and $cfg.DefenderBuild) {
                $foundMode = [string]$cfg.DefenderBuild
                break
            }
        }
    } elseif ((Test-Path variable:ProfileDir) -and $ProfileDir -and (Test-Path (Join-Path $ProfileDir "profile.psd1"))) {
        $cfg = if (Get-Command Import-ProfileManifest -ErrorAction SilentlyContinue) {
            Import-ProfileManifest -Path (Join-Path $ProfileDir "profile.psd1")
        } else {
            try { Import-PowerShellDataFile -Path (Join-Path $ProfileDir "profile.psd1") -ErrorAction Stop } catch { $null }
        }
        if ($cfg -and $cfg.ContainsKey('DefenderBuild') -and $cfg.DefenderBuild) {
            $foundMode = [string]$cfg.DefenderBuild
        }
    }

    if ($foundMode) {
        $RemoveDefender = ($foundMode -match '(?i)^(both|dual|remove|true)$')
    }
}

if ($RemoveDefender) {
    Write-Step "Purging Windows Defender Folders, Binaries, and Services..."
    Disable-OfflineFeature -MountDir $MountDir -FeatureName "Windows-Defender-Default-Definitions" -Remove

    $defenderFolders = @(
        "$MountDir\Program Files\Windows Defender",
        "$MountDir\Program Files (x86)\Windows Defender",
        "$MountDir\ProgramData\Microsoft\Windows Defender",
        "$MountDir\Windows\System32\drivers\wd",
        "$MountDir\Windows\System32\SecurityHealth"
    )
    foreach ($dir in $defenderFolders) {
        if (Test-Path $dir) {
            Remove-ForceDirectory $dir
            Write-Success "Deleted Defender directory: $dir"
        }
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
        "$MountDir\Windows\System32\wscui.cpl"
    )
    foreach ($bin in $defenderBinaries) {
        if (Test-Path $bin) {
            Remove-ForceFile $bin
            Write-Success "Deleted Defender binary: $(Split-Path $bin -Leaf)"
        }
    }

    $defenderServices = @(
        "Sense", "WdBoot", "WdFilter", "WdNisDrv", "WdNisSvc",
        "WinDefend", "SecurityHealthService", "webthreatdefsvc", "webthreatdefusersvc"
    )
    foreach ($svc in $defenderServices) {
        Remove-RegKey "HKLM\SYSTEM\CurrentControlSet\Services\$svc"
        Write-Success "Deleted Defender service: $svc"
    }

    Remove-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" "SecurityHealth"
    Remove-RegValue "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" "SecurityHealth"
    Write-Success "Deleted SecurityHealth tray icon startup from Run keys."

    Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*Microsoft.SecHealthUI*"
    Remove-OfflineProvisionedAppxPackage -MountDir $MountDir -Pattern "*SecHealthUI*"

    Write-Step "Purging SmartScreen, AppRep, and BrowserCore..."
    $smartScreenFiles = @(
        "$MountDir\Windows\System32\smartscreen.exe",
        "$MountDir\Windows\System32\smartscreen.dll",
        "$MountDir\Windows\System32\smartscreenps.dll",
        "$MountDir\Windows\System32\en-US\smartscreen.exe.mui",
        "$MountDir\Windows\System32\AppRepAgent.dll",
        "$MountDir\Windows\System32\AppRepUX.exe",
        "$MountDir\Windows\System32\SmartAppControl.dll",
        "$MountDir\Windows\SysWOW64\smartscreen.dll",
        "$MountDir\Windows\SysWOW64\smartscreenps.dll",
        "$MountDir\Windows\SysWOW64\AppRepAgent.dll"
    )
    foreach ($f in $smartScreenFiles) {
        if (Test-Path $f) {
            Remove-ForceFile $f
            Write-Success "Deleted SmartScreen binary: $(Split-Path $f -Leaf)"
        }
    }

    Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern "smartscreen*.mui" -Recurse

    Remove-OfflineSystemApp -MountDir $MountDir -Pattern "Microsoft.Windows.AppRep.ChxApp_*"

    $browserCoreFiles = @(
        "$MountDir\Windows\System32\browsercore.exe",
        "$MountDir\Windows\System32\browsercore.json",
        "$MountDir\Windows\SysWOW64\browsercore.exe",
        "$MountDir\Windows\SysWOW64\browsercore.json"
    )
    foreach ($bf in $browserCoreFiles) {
        if (Test-Path $bf) {
            Remove-ForceFile $bf
            Write-Success "Deleted BrowserCore binary: $(Split-Path $bf -Leaf)"
        }
    }

    Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern "browsercore*.mui" -Recurse

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
