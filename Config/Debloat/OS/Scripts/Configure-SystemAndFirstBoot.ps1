<#
.SYNOPSIS
    Configure Services, Clean Start Menu, and Ultimate Performance Power Plan
.DESCRIPTION
    Configures essential background service start types, stages clean Start Menu layout, enforces language privacy, sets OEM associations, and activates Ultimate Performance power scheme offline.
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

Write-Step "Configuring Service Start Types..."
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Services\PlugPlay" "Start" 4
Write-Success "Service PlugPlay start type set to 4 (Disabled)."

Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Services\Spooler" "Start" 3
Write-Success "Service Spooler start type set to 3 (Manual)."

Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Services\lfsvc" "Start" 4
Write-Success "Service lfsvc start type set to 4 (Disabled)."

Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Services\DPS" "Start" 4 -Elevated
Write-Success "Configured DPS start=4 via NSudo (TrustedInstaller)."

Write-Step "Configuring Start Menu Layout and Language Privacy Policy..."
Set-OfflineStartLayout -MountDir $MountDir

Set-RegValue "HKCU\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 1
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Control Panel\International" "UserHttpAcceptLanguageOptOut" 1
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" "Telemetry Language Disable" 'reg.exe add "HKCU\Control Panel\International\User Profile" /v HttpAcceptLanguageOptOut /t REG_DWORD /d 1 /f' "REG_SZ"
Write-Success "Persisted HttpAcceptLanguageOptOut policy in Default Profile and Policies."

Write-Step "Generating OEMDefaultAssociations.xml and Notepad.lnk..."
Set-OfflineDefaultAssociations -MountDir $MountDir

$accDir = "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories"
New-FileShortcut -Path "$accDir\Notepad.lnk" -TargetPath "C:\Windows\System32\notepad.exe" -IconLocation "C:\Windows\System32\notepad.exe,0" -WorkingDirectory "C:\Windows\System32" -Description "Notepad"

Write-Step "Activating Ultimate Performance Power Scheme Offline..."
$ultGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes" "ActivePowerScheme" $ultGuid "REG_SZ" -Elevated
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\Default\PowerSchemes" "ActivePowerScheme" $ultGuid "REG_SZ" -Elevated
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$ultGuid" "Attributes" 0 "REG_DWORD" -Elevated
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\Default\PowerSchemes\$ultGuid" "Attributes" 0 "REG_DWORD" -Elevated
Write-Success "Activated and unhid Ultimate Performance power scheme in offline registry."
