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
Set-OfflineServiceStart "Spooler" 3
Set-OfflineServiceStart "lfsvc" 4
Set-OfflineServiceStart "DPS" 4 -Elevated

Write-Step "Configuring Language Privacy Policy..."
Set-RegValue "HKCU\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 1
$runOnceKey = "Registry::HKU\OFFLINE_DEFAULT\Software\Microsoft\Windows\CurrentVersion\RunOnce"
if (-not (Test-Path $runOnceKey)) { New-Item -Path $runOnceKey -Force | Out-Null }
Set-ItemProperty -Path $runOnceKey -Name "Telemetry Language Disable" -Value 'reg.exe add "HKCU\Control Panel\International\User Profile" /v HttpAcceptLanguageOptOut /t REG_DWORD /d 1 /f' -Force
Write-Success "Persisted HttpAcceptLanguageOptOut in Default Profile and RunOnce."

Write-Step "Configuring OEM Default Associations and Notepad.lnk..."
if ($targetOS -eq '10') {
    Clear-OfflineDefaultStartLayout -MountDir $MountDir
}
$assocXml = Join-Path (Split-Path $PSScriptRoot -Parent) "OEMDefaultAssociations.xml"
if (Test-Path $assocXml) {
    Set-OfflineDefaultAssociations -MountDir $MountDir -XmlPath $assocXml
} else {
    Set-OfflineDefaultAssociations -MountDir $MountDir
}

$accDir = "$MountDir\ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories"
New-FileShortcut -Path "$accDir\Notepad.lnk" -TargetPath "C:\Windows\System32\notepad.exe" -IconLocation "C:\Windows\System32\notepad.exe,0" -WorkingDirectory "C:\Windows\System32" -Description "Notepad"

Write-Step "Activating Ultimate Performance Power Scheme Offline..."
$ultGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes" "ActivePowerScheme" $ultGuid "REG_SZ" -Elevated
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\Default\PowerSchemes" "ActivePowerScheme" $ultGuid "REG_SZ" -Elevated
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$ultGuid" "Attributes" 0 "REG_DWORD" -Elevated
Set-RegValue "HKLM\SYSTEM\CurrentControlSet\Control\Power\User\Default\PowerSchemes\$ultGuid" "Attributes" 0 "REG_DWORD" -Elevated
Write-Success "Activated and unhid Ultimate Performance power scheme in offline registry."

Write-Step "Configuring Offline OOBE Bypass..."
# Bypass Windows 11 Network / MSA requirement for local account setup
Set-RegValue "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" "BypassNRO" 1 "REG_DWORD"

# Disable local account security questions prompt so OOBE only asks for username and password
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "NoLocalPasswordResetQuestions" 1 "REG_DWORD"

Write-Success "Configured offline OOBE bypass (BypassNRO = 1, NoLocalPasswordResetQuestions = 1)."

