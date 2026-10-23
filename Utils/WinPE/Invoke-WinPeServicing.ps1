<#
.SYNOPSIS
    WinPE Environment Servicing, Bypass Injection, and Binary Patching Utilities.
#>

function Enable-Win11HardwareBypass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$WinPeHiveKey = "HKLM\WINPE_BOOTSYS",

        [Parameter(Mandatory = $false)]
        [string]$MountDir = ""
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

function Get-PeMachineArchitecture([byte[]]$bytes) {
    if ($bytes.Length -lt 0x40) { return "Unknown" }
    if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { return "Unknown" }
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -le 0 -or ($peOffset + 6) -gt $bytes.Length) { return "Unknown" }
    if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or $bytes[$peOffset + 2] -ne 0x00 -or $bytes[$peOffset + 3] -ne 0x00) {
        return "Unknown"
    }
    $machine = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
    switch ($machine) {
        0xAA64 { return "ARM64" }
        0x01C4 { return "ARM" }
        0x8664 { return "x64" }
        0x014C { return "x86" }
        default { return "0x$($machine.ToString('X4'))" }
    }
}

function Patch-BinaryPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [byte[]]$Pattern,

        [Parameter(Mandatory = $true)]
        [byte[]]$Replacement,

        [Parameter(Mandatory = $false)]
        [int]$PatchOffset = 0,

        [Parameter(Mandatory = $false)]
        [byte[]]$VerifyPattern = $null,

        [Parameter(Mandatory = $false)]
        [byte[]]$AlreadyPatched = $null,

        [Parameter(Mandatory = $false)]
        [string]$Description = "binary patch"
    )

    if (-not (Test-Path $FilePath)) {
        return $false
    }

    try {
        Set-ItemProperty -Path $FilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        & attrib.exe -r $FilePath *> $null

        $bytes = [System.IO.File]::ReadAllBytes($FilePath)

        # Architecture guard: skip x86_64 bytecode patterns on ARM/ARM64 targets
        $arch = Get-PeMachineArchitecture $bytes
        if ($arch -match '^ARM') {
            Write-Host "      [INFO] '$FilePath' is $arch architecture. Skipping x86_64 binary pattern ($Description)." -ForegroundColor Gray
            return $false
        }
        $patLen  = $Pattern.Length
        $reqLen  = [math]::Max($patLen, ($PatchOffset + $Replacement.Length))
        if ($VerifyPattern) {
            $reqLen = [math]::Max($reqLen, ($PatchOffset + $VerifyPattern.Length))
        }
        if ($AlreadyPatched) {
            $reqLen = [math]::Max($reqLen, ($PatchOffset + $AlreadyPatched.Length))
        }
        $maxIdx  = $bytes.Length - $reqLen

        for ($i = 0; $i -le $maxIdx; $i++) {
            $match = $true
            for ($j = 0; $j -lt $patLen; $j++) {
                if ($bytes[$i + $j] -ne $Pattern[$j]) {
                    $match = $false
                    break
                }
            }
            if ($match) {
                # Check unpatched verification pattern if provided
                if ($VerifyPattern) {
                    $verifyMatch = $true
                    for ($v = 0; $v -lt $VerifyPattern.Length; $v++) {
                        if ($bytes[$i + $PatchOffset + $v] -ne $VerifyPattern[$v]) {
                            $verifyMatch = $false
                            break
                        }
                    }
                    if ($verifyMatch) {
                        for ($k = 0; $k -lt $Replacement.Length; $k++) {
                            $bytes[$i + $PatchOffset + $k] = $Replacement[$k]
                        }
                        [System.IO.File]::WriteAllBytes($FilePath, $bytes)
                        Write-Host "      [OK] Patched '$FilePath' at offset 0x$(($i + $PatchOffset).ToString('X')): $Description applied unconditionally." -ForegroundColor Green
                        return $true
                    }
                } else {
                    for ($k = 0; $k -lt $Replacement.Length; $k++) {
                        $bytes[$i + $PatchOffset + $k] = $Replacement[$k]
                    }
                    [System.IO.File]::WriteAllBytes($FilePath, $bytes)
                    Write-Host "      [OK] Patched '$FilePath' at offset 0x$(($i + $PatchOffset).ToString('X')): $Description applied unconditionally." -ForegroundColor Green
                    return $true
                }

                # Check if already patched
                if ($AlreadyPatched) {
                    $alreadyMatch = $true
                    $checkOffset = if ($VerifyPattern) { $PatchOffset } else { 0 }
                    for ($a = 0; $a -lt $AlreadyPatched.Length; $a++) {
                        if ($bytes[$i + $checkOffset + $a] -ne $AlreadyPatched[$a]) {
                            $alreadyMatch = $false
                            break
                        }
                    }
                    if ($alreadyMatch) {
                        Write-Host "      [INFO] '$FilePath' is already patched ($Description active)." -ForegroundColor Gray
                        return $true
                    }
                }
            }
        }
        Write-Warning "Target instruction pattern for $Description not found in '$FilePath'."
    } catch {
        Write-Warning "Failed to patch '$FilePath': $_"
    }
    return $false
}

function Invoke-WinPeBinaryPatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$MountDir = "",

        [Parameter(Mandatory = $false)]
        [string]$DistDir = "",

        [Parameter(Mandatory = $false)]
        [string]$BootWimPath = "",

        [Parameter(Mandatory = $false)]
        [int]$ImageIndex = 2,

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = "",

        [Parameter(Mandatory = $false)]
        [string]$RelativeFilePath = "sources\winsetup.dll",

        [Parameter(Mandatory = $true)]
        [scriptblock]$PatchAction
    )

    # 1. Patch if WinPE is mounted to a directory
    $isMounted = $MountDir -and (Test-Path $MountDir)
    if ($isMounted) {
        $candidates = @(
            (Join-Path $MountDir $RelativeFilePath),
            (Join-Path $MountDir "Windows\System32\winsetup.dll"),
            (Join-Path $MountDir ([System.IO.Path]::GetFileName($RelativeFilePath)))
        )
        foreach ($cand in $candidates) {
            if (Test-Path $cand) {
                & $PatchAction $cand | Out-Null
            }
        }
    }

    # 2. Patch in distribution media root
    if ($DistDir -and (Test-Path $DistDir)) {
        $candidates = @(
            (Join-Path $DistDir $RelativeFilePath),
            (Join-Path $DistDir ([System.IO.Path]::GetFileName($RelativeFilePath)))
        )
        foreach ($cand in $candidates) {
            if (Test-Path $cand) {
                & $PatchAction $cand | Out-Null
            }
        }
    }

    # 3. Patch inside boot.wim using wimlib (only when WinPE is NOT currently mounted by DISM)
    if (-not $isMounted -and $BootWimPath -and (Test-Path $BootWimPath) -and $WimLibPath -and (Test-Path $WimLibPath)) {
        $fileName = [System.IO.Path]::GetFileName($RelativeFilePath)
        $tempPatchDir = Join-Path ([System.IO.Path]::GetTempPath()) "winsetup_patch_$([System.IO.Path]::GetRandomFileName())"
        New-Item -ItemType Directory -Path $tempPatchDir -Force | Out-Null
        try {
            $wimInternalPath = "\" + ($RelativeFilePath.TrimStart('\', '/'))
            & $WimLibPath extract $BootWimPath $ImageIndex $wimInternalPath "--dest-dir=$tempPatchDir" --no-acls *> $null
            $extractedFile = Join-Path $tempPatchDir $fileName
            if (Test-Path $extractedFile) {
                $didPatch = & $PatchAction $extractedFile
                if ($didPatch) {
                    $updateCmd = "add `"$extractedFile`" `"$wimInternalPath`""
                    $updateCmd | & $WimLibPath update $BootWimPath $ImageIndex --force *> $null
                    Write-Host "      [OK] Re-injected patched $fileName into boot.wim (Index $ImageIndex)." -ForegroundColor Green
                }
            }
        } catch {
            Write-Warning "Failed to patch $fileName inside boot.wim: $_"
        } finally {
            Remove-Item $tempPatchDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Enable-WinPeSetupBypass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Eula", "ProductKey")]
        [string]$Type,

        [Parameter(Mandatory = $false)]
        [string]$MountDir = "",

        [Parameter(Mandatory = $false)]
        [string]$WinPeHiveKey = "HKLM\WINPE_BOOTSYS",

        [Parameter(Mandatory = $false)]
        [string]$BootWimPath = "",

        [Parameter(Mandatory = $false)]
        [int]$ImageIndex = 2,

        [Parameter(Mandatory = $false)]
        [string]$WimLibPath = "",

        [Parameter(Mandatory = $false)]
        [string]$DistDir = ""
    )

    switch ($Type) {
        "Eula" {
            Invoke-WinPeBinaryPatch `
                -MountDir $MountDir `
                -DistDir $DistDir `
                -BootWimPath $BootWimPath `
                -ImageIndex $ImageIndex `
                -WimLibPath $WimLibPath `
                -RelativeFilePath "sources\winsetup.dll" `
                -PatchAction {
                    param($f)
                    Patch-BinaryPattern `
                        -FilePath $f `
                        -Pattern ([byte[]](0x49, 0x8B, 0xCC, 0x41, 0x0F, 0x94, 0xC1, 0xE8)) `
                        -Replacement ([byte[]](0x45, 0x31, 0xC9, 0x90)) `
                        -PatchOffset 3 `
                        -AlreadyPatched ([byte[]](0x49, 0x8B, 0xCC, 0x45, 0x31, 0xC9, 0x90, 0xE8)) `
                        -Description "EULA bypass"
                }
        }
        "ProductKey" {
            Invoke-WinPeBinaryPatch `
                -MountDir $MountDir `
                -DistDir $DistDir `
                -BootWimPath $BootWimPath `
                -ImageIndex $ImageIndex `
                -WimLibPath $WimLibPath `
                -RelativeFilePath "sources\winsetup.dll" `
                -PatchAction {
                    param($f)
                    Patch-BinaryPattern `
                        -FilePath $f `
                        -Pattern ([byte[]](0xC7, 0x45, 0x7F, 0x02, 0x00, 0x00, 0x00, 0x45, 0x33, 0xC9, 0xE8)) `
                        -PatchOffset 15 `
                        -VerifyPattern ([byte[]](0x85, 0xC0, 0x0F, 0x84)) `
                        -Replacement ([byte[]](0x31, 0xC0)) `
                        -AlreadyPatched ([byte[]](0x31, 0xC0, 0x0F, 0x84)) `
                        -Description "ProductKey check bypass"
                }
        }
    }
}
