<#
.SYNOPSIS
    Remove Windows Content Delivery Manager and Cloud Consumer Features
.DESCRIPTION
    Deprovisions ContentDeliveryManager, clears scheduled tasks, and enforces policies to disable sponsored apps and suggested consumer content.
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

Write-Step "Purging Content Delivery Manager (microsoft.windows.contentdeliverymanager)..."
$cdmApps = Get-ChildItem -Path "$MountDir\Windows\SystemApps" -Filter "Microsoft.Windows.ContentDeliveryManager_*" -Directory -ErrorAction SilentlyContinue
foreach ($app in $cdmApps) {
    Remove-ForceDirectory $app.FullName
    Write-Success "Purged ContentDeliveryManager SystemApp: $($app.Name)"
}

Remove-ScheduledTask "\Microsoft\Windows\ContentDeliveryManager"
Remove-ScheduledTask "\Microsoft\Windows\CloudExperienceHost\CreateObjectTask"
Write-Success "Purged ContentDeliveryManager and CloudExperienceHost scheduled tasks."
$inboxAppsKey = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications"
foreach ($k in (Get-RegSubKey $inboxAppsKey "ContentDeliveryManager")) {
    Remove-RegKey $k
}

$deproKey = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy"
Set-RegKey $deproKey

Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
Set-RegValue "HKCU\Software\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SilentInstalledAppsEnabled" 0
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "ContentDeliveryAllowed" 0
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-310093Enabled" 0
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338387Enabled" 0
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338388Enabled" 0
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-338389Enabled" 0
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-353694Enabled" 0
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" "SubscribedContent-353696Enabled" 0
Write-Success "Purged Content Delivery Manager and registered deprovisioning tombstone."
