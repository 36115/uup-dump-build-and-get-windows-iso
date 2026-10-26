<#
.SYNOPSIS
    Remove Shell Flyouts, Dialog Prompts, and Auxiliary SystemApps
.DESCRIPTION
    Purges AppResolverUX (restores classic Open With), FolderSuggestions, PinningConfirmationDialog, legacy File Explorer, RetailDemo (RDX), Family Safety, and Narrator.
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

Write-Step "Purging AppResolverUX and Restoring Classic Open With..."
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*Microsoft.Windows.AppResolverUX*"

Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" "NoUseStoreOpenWith" 1
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" "NoNewAppAlert" 1
Set-RegValue "HKCU\Software\Policies\Microsoft\Windows\Explorer" "NoUseStoreOpenWith" 1
Set-RegValue "HKCU\Software\Policies\Microsoft\Windows\Explorer" "NoNewAppAlert" 1
Write-Success "Enforced classic Open With and suppressed Store recommendation prompts."

Write-Step "Purging Add Folder Suggestions Dialog..."
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*AddSuggestedFoldersToLibraryDialog*"
Write-Success "Purged Folder Suggestions dialog registrations."

Write-Step "Purging PinningConfirmationDialog SystemApp..."
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*Microsoft.Windows.PinningConfirmationDialog*"
Write-Success "Purged PinningConfirmationDialog registrations."

Write-Step "Purging File Explorer (Legacy) SystemApp..."
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*Microsoft.Windows.FileExplorer*"
Write-Success "Purged File Explorer (Legacy) registrations."

Write-Step "Purging Retail Demo Content & Retail Demo Experience (RDX)..."
$retailDemoDirs = @(
    "$MountDir\ProgramData\Microsoft\Windows\RetailDemo",
    "$MountDir\Windows\SystemApps\Microsoft.Windows.CloudExperienceHost_cw5n1h2txyewy\RetailDemo"
)
foreach ($dir in $retailDemoDirs) {
    if (Test-Path $dir) {
        Remove-ForceDirectory $dir
        Write-Success "Purged RetailDemo directory: $(Split-Path $dir -Leaf)"
    }
}

$retailDemoBinaries = @(
    "$MountDir\Windows\System32\RDXService.dll",
    "$MountDir\Windows\System32\RDXTaskFactory.dll",
    "$MountDir\Windows\System32\Windows.System.Profile.RetailInfo.dll",
    "$MountDir\Windows\SysWOW64\Windows.System.Profile.RetailInfo.dll"
)
foreach ($bin in $retailDemoBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted RetailDemo binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern @("*rdx*.mui", "*RetailInfo*.mui") -Recurse
Remove-ScheduledTask "\Microsoft\Windows\RetailDemo"
Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RetailDemo"
Clear-OfflineAppxInboxAndDeprovision -Patterns "RetailDemo"

Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\RetailDemo" "AllowRetailDemo" 0
Write-Success "Purged RetailDemo registry and enforced AllowRetailDemo=0 policy."

Write-Step "Purging Microsoft Family & Parental Controls..."
Remove-OfflineProvisionedAppxPackage -MountDir $MountDir -Pattern "*MicrosoftFamily*"
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*MicrosoftFamily*"
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*ParentalControls*"
$familyBinaries = @(
    "$MountDir\Windows\System32\Wpc.dll",
    "$MountDir\Windows\System32\WpcApi.dll",
    "$MountDir\Windows\System32\WpcDesktopMonSvc.dll",
    "$MountDir\Windows\System32\WpcMon.exe",
    "$MountDir\Windows\System32\WpcProxyStubs.dll",
    "$MountDir\Windows\System32\WpcRefreshTask.dll",
    "$MountDir\Windows\System32\WpcTok.exe",
    "$MountDir\Windows\System32\WpcWebFilter.dll",
    "$MountDir\Windows\System32\FamilySafetyExt.dll",
    "$MountDir\Windows\System32\wpcatltoast.png",
    "$MountDir\Windows\System32\wpcmon.png",
    "$MountDir\Windows\SysWOW64\Wpc.dll",
    "$MountDir\Windows\SysWOW64\WpcWebFilter.dll",
    "$MountDir\Windows\SysWOW64\FamilySafetyExt.dll"
)
foreach ($bin in $familyBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted ParentalControls binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path @("$MountDir\Windows\System32", "$MountDir\Windows\SysWOW64") -Pattern "wpc*.dll.mui" -Recurse

Remove-OfflineService "WpcMonSvc", "WpcMonTemplateSvc"

Remove-RegMultiSzItem -Key "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost" -ValueName "LocalService" -Item "WpcMonSvc"
Remove-ScheduledTask "\Microsoft\Windows\ParentalControls"
Write-Success "Purged Microsoft Family and Parental Controls."

Write-Step "Purging Narrator and NarratorQuickStart..."
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*NarratorQuickStart*"
$narratorMCAT = "$MountDir\Windows\System32\NarratorMCAT"
if (Test-Path $narratorMCAT) {
    Remove-ForceDirectory $narratorMCAT
    Write-Success "Purged NarratorMCAT directory: $narratorMCAT"
}

$narratorBinaries = @(
    "$MountDir\Windows\System32\Narrator.exe",
    "$MountDir\Windows\System32\NarratorControlTemplates.xml",
    "$MountDir\Windows\System32\NarratorControlTemplates.xsd"
)
foreach ($bin in $narratorBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted Narrator binary: $(Split-Path $bin -Leaf)"
    }
}

Remove-ForceFilesByPattern -Path "$MountDir\Windows\System32" -Pattern "Narrator*.mui" -Recurse

$narratorShortcuts = @(
    "$MountDir\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Accessibility\Narrator.lnk"
)
Get-ChildItem -Path "$MountDir\Users" -Filter "Narrator.lnk" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $narratorShortcuts += $_.FullName
}

foreach ($sc in ($narratorShortcuts | Select-Object -Unique)) {
    if (Test-Path $sc) {
        Remove-ForceFile $sc
        Write-Success "Deleted Narrator shortcut: $(Split-Path $sc -Leaf)"
    }
}

Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility\ATs\Narrator"
Remove-RegKey "HKCU\Software\Microsoft\Narrator"

Write-Success "Purged Narrator and NarratorQuickStart registrations."
