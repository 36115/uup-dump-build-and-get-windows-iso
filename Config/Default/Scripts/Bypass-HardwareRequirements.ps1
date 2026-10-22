<#
.SYNOPSIS
    WinPE Hardware Requirement Bypasses & Setup Configuration.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$MountDir = "",

    [Parameter(Mandatory = $false)]
    [string]$WinPeHiveKey = "HKLM\WINPE_BOOTSYS",

    [Parameter(Mandatory = $false)]
    [string]$TargetOS = ""
)

$ErrorActionPreference = 'Stop'

# Hardware requirement bypasses are only needed on Windows 11
$resolvedTargetOS = if ($TargetOS) {
    $TargetOS
} elseif (Test-Path variable:global:targetOS) {
    $global:targetOS
} else {
    ""
}
if ($resolvedTargetOS -and $resolvedTargetOS -ne '11') {
    return
}

Write-Host "  >>> Executing Component: Bypass-HardwareRequirements..." -ForegroundColor Cyan

function Enable-Win11HardwareBypass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$WinPeHiveKey = "HKLM\WINPE_BOOTSYS"
    )

    $targetKey = if ($WinPeHiveKey -and (Test-Path "Registry::$WinPeHiveKey")) {
        $WinPeHiveKey
    } elseif (Test-Path "Registry::HKLM\OFFLINE_SYSTEM") {
        "HKLM\OFFLINE_SYSTEM"
    } else {
        $null
    }

    if ($targetKey) {
        $labConfigKey = "$targetKey\Setup\LabConfig"
        $moSetupKey = "$targetKey\Setup\MoSetup"

        if (-not (Test-Path "Registry::$labConfigKey")) {
            New-Item -Path "Registry::$labConfigKey" -Force | Out-Null
        }
        if (-not (Test-Path "Registry::$moSetupKey")) {
            New-Item -Path "Registry::$moSetupKey" -Force | Out-Null
        }

        $bypassDwords = @{
            "BypassTPMCheck"        = 1
            "BypassSecureBootCheck" = 1
            "BypassRAMCheck"        = 1
            "BypassCPUCheck"        = 1
            "BypassStorageCheck"    = 1
            "BypassDiskCheck"       = 1
        }

        foreach ($kv in $bypassDwords.GetEnumerator()) {
            Set-ItemProperty -Path "Registry::$labConfigKey" -Name $kv.Key -Value $kv.Value -Type DWord -Force
        }

        Set-ItemProperty -Path "Registry::$moSetupKey" -Name "AllowUpgradesWithUnsupportedTPMOrCPU" -Value 1 -Type DWord -Force

        Write-Host "      [OK] Injected LabConfig and MoSetup bypasses (TPM, SecureBoot, RAM, CPU, Storage, Disk)." -ForegroundColor Green
    } else {
        Write-Warning "WinPE registry hive key not mounted: '$WinPeHiveKey'"
    }
}

Enable-Win11HardwareBypass -WinPeHiveKey $WinPeHiveKey
