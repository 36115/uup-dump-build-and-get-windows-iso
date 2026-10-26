<#
.SYNOPSIS
    Remove Windows 11 Copilot, Recall, CoreAI, and Cross-Device Services
.DESCRIPTION
    Decouples Copilot, removes Windows Recall and CoreAI packages, blocks CrossDeviceResume, and enforces AI disablement policies.
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

Write-Step "Decoupling Windows Copilot (WFEP) & Shell Integration..."
Remove-OfflineProvisionedAppxPackage -MountDir $MountDir -Pattern "*Copilot*"
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "*Copilot*"
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
Set-RegValue "HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1
Set-RegValue "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" 0
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Edge" "CopilotPageContext" 0
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Edge" "ShowCopilotButton" 0
Write-Success "Decoupled Copilot from Taskbar Shell and Microsoft Edge."

Write-Step "Removing Windows Recall Optional Feature..."
Write-Info "Disabling and removing feature payload: Recall"
Disable-OfflineFeature -MountDir $MountDir -FeatureName "Recall" -Remove
Write-Success "Feature Recall disabled with payload removed."

Write-Step "Purging Windows Feature Experience Pack - CoreAI (CoreAIComponents)..."
Remove-OfflineSystemApp -MountDir $MountDir -Pattern "MicrosoftWindows.Client.CoreAI_*"
$coreAiBinaries = @(
    "$MountDir\Windows\System32\Windows.AI.MachineLearning.dll",
    "$MountDir\Windows\System32\Windows.AI.MachineLearning.Preview.dll",
    "$MountDir\Windows\System32\onnxruntime.dll"
)
foreach ($bin in $coreAiBinaries) {
    if (Test-Path $bin) {
        Remove-ForceFile $bin
        Write-Success "Deleted CoreAI binary: $(Split-Path $bin -Leaf)"
    }
}

Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
Set-RegValue "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "TurnOffRecall" 1
Write-Success "Purged CoreAI registry keys and enforced AI policies."

Write-Step "Disabling Cross-Device Resume & Connected Devices Platform..."
$ifeoKey = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CrossDeviceResume.exe"
Set-RegValue $ifeoKey "Debugger" "systray.exe" "REG_SZ"

$sysPol = "HKLM\SOFTWARE\Policies\Microsoft\Windows\System"
Set-RegValue $sysPol "EnableCrossDeviceResume" 0
Set-RegValue $sysPol "EnableCdp" 0

$defSysPol = "HKCU\Software\Policies\Microsoft\Windows\System"
Set-RegValue $defSysPol "EnableCrossDeviceResume" 0
Set-RegValue $defSysPol "EnableCdp" 0

$pmConn = "HKLM\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume"
Set-RegValue $pmConn "value" 1
Write-Success "Cross-Device Resume blocked via IFEO and disabled across policies."
