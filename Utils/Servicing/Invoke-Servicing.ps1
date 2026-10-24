<#
.SYNOPSIS
    Master Offline Windows Image Servicing Engine.
.DESCRIPTION
    Applies offline servicing to a mounted Windows image:
    - Mounts offline registry hives (SYSTEM, SOFTWARE, DEFAULT NTUSER.DAT)
    - Resolves profile hierarchy via Profile.ps1
    - Translates and imports profile registry files
    - Executes modular servicing scripts defined by the profile
    - Dismounts offline registry hives
    - Runs DISM component cleanup (/ResetBase) if requested
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MountDir,

    [Parameter(Mandatory = $false)]
    [string]$ProfileName = "Default",

    [Parameter(Mandatory = $false)]
    [string]$ProfileDir = "",

    [Parameter(Mandatory = $false)]
    [string]$CustomRegPath = "",

    [Parameter(Mandatory = $false)]
    [string]$RegistryDir = "",

    [Parameter(Mandatory = $false)]
    [string]$NSudoPath = "",

    [Parameter(Mandatory = $false)]
    [string]$ScriptsDir = "",

    [Parameter(Mandatory = $false)]
    [switch]$SkipCleanup,

    [Parameter(Mandatory = $false)]
    [switch]$ForceRemoveDefender
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) {
    Write-Host "`n>>> $msg" -ForegroundColor Cyan
}

function Write-Success([string]$msg) {
    Write-Host "  [OK] $msg" -ForegroundColor Green
}

function Write-Info([string]$msg) {
    Write-Host "  [INFO] $msg" -ForegroundColor Gray
}

# Resolve paths
if ($ForceRemoveDefender) {
    $env:FORCE_REMOVE_DEFENDER = 'true'
}

$MountDir = (Resolve-Path $MountDir).Path
if (-not (Test-Path "$MountDir\Windows\System32")) {
    throw "Invalid MountDir: '$MountDir' does not appear to be a mounted Windows image."
}

$repo = if (Get-Command Get-RepoRoot -ErrorAction SilentlyContinue) { Get-RepoRoot } else { (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }

$profileHelper = Join-Path $repo "Utils\Common\Profile.ps1"
if (Test-Path $profileHelper) { . $profileHelper }

# Resolve ProfileDir
if (-not $ProfileDir -and $ProfileName) {
    if (Get-Command Resolve-ProfileDir -ErrorAction SilentlyContinue) {
        $ProfileDir = Resolve-ProfileDir -ProfileName $ProfileName -RepoRoot $repo
    } else {
        $candidateProfiles = @(
            (Join-Path $repo "Config\$ProfileName"),
            (Join-Path $repo "Config\Win11\$ProfileName"),
            (Join-Path $repo "Config\Win10\$ProfileName")
        )
        foreach ($cand in $candidateProfiles) {
            if (Test-Path $cand) {
                $ProfileDir = (Resolve-Path $cand).Path
                break
            }
        }
    }
}

# Resolve profile hierarchy if profile.psd1 is present
if (-not (Get-Command Get-ProfileHierarchy -ErrorAction SilentlyContinue)) {
    function Get-ProfileHierarchy([string]$dir, [string]$repoRoot, [string]$mountDir = "") {
        $chain = [System.Collections.Generic.List[psobject]]::new()
        $currDir = $dir
        while ($currDir -and (Test-Path (Join-Path $currDir "profile.psd1"))) {
            $manifestPath = Join-Path $currDir "profile.psd1"
            $cfg = if (Get-Command Import-ProfileManifest -ErrorAction SilentlyContinue) {
                Import-ProfileManifest -Path $manifestPath -MountDir $mountDir
            } else {
                Import-PowerShellDataFile -Path $manifestPath
            }
            $chain.Insert(0, [PSCustomObject]@{ Dir = $currDir; Config = $cfg })
            if ($cfg.ContainsKey('Extends') -and $cfg.Extends) {
                $parent = Join-Path $repoRoot "Config\$($cfg.Extends)"
                if (Test-Path (Join-Path $parent "profile.psd1")) {
                    $currDir = (Resolve-Path $parent).Path
                } else {
                    break
                }
            } else {
                break
            }
        }
        return $chain
    }

}

$profileChain = if ($ProfileDir) { Get-ProfileHierarchy -dir $ProfileDir -repoRoot $repo -MountDir $MountDir } else { @() }
$profileRegFiles = [System.Collections.Generic.List[string]]::new()
$profileScripts = [System.Collections.Generic.List[string]]::new()

foreach ($item in $profileChain) {
    $cfg = $item.Config
    $baseDir = $item.Dir

    if ($cfg.ContainsKey('RegistryFiles') -and $cfg.RegistryFiles) {
        foreach ($rf in $cfg.RegistryFiles) {
            $cand = Join-Path $baseDir $rf
            if (-not (Test-Path $cand)) { $cand = Join-Path $repo $rf }
            if (Test-Path $cand) {
                $resolved = (Resolve-Path $cand).Path
                if (-not $profileRegFiles.Contains($resolved)) {
                    $profileRegFiles.Add($resolved)
                }
            }
        }
    }

    if ($cfg.ContainsKey('Scripts') -and $cfg.Scripts) {
        foreach ($sc in $cfg.Scripts) {
            $cand = Join-Path $baseDir $sc
            if (-not (Test-Path $cand)) { $cand = Join-Path $repo $sc }
            if (Test-Path $cand) {
                $resolved = (Resolve-Path $cand).Path
                if (-not $profileScripts.Contains($resolved)) {
                    $profileScripts.Add($resolved)
                }
            }
        }
    }
}

# Resolve RegistryDir
if (-not $RegistryDir) {
    if ($ProfileDir -and (Test-Path (Join-Path $ProfileDir "Registry"))) {
        $RegistryDir = (Resolve-Path (Join-Path $ProfileDir "Registry")).Path
    } else {
        $candidates = @(
            (Join-Path $repo "Config\Win11\Registry"),
            (Join-Path $repo "Config\Registry"),
            (Join-Path $PSScriptRoot "Config\Registry")
        )
        foreach ($cand in $candidates) {
            if (Test-Path $cand) {
                $RegistryDir = (Resolve-Path $cand).Path
                break
            }
        }
    }
}

if ($CustomRegPath -and (Test-Path $CustomRegPath -PathType Leaf)) {
    $CustomRegPath = (Resolve-Path $CustomRegPath).Path
} else {
    $CustomRegPath = ""
}

$setupScript = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "Build\Initialize-Environment.ps1"
if (-not (Test-Path $setupScript)) { $setupScript = Join-Path $PSScriptRoot "..\..\Build\Initialize-Environment.ps1" }
if (-not (Test-Path $setupScript)) { $setupScript = "Build\Initialize-Environment.ps1" }
if (Test-Path $setupScript) { . $setupScript }

if (-not $NSudoPath -or -not (Test-Path $NSudoPath -PathType Leaf)) {
    if (Get-Command Get-NSudoPath -ErrorAction SilentlyContinue) {
        $NSudoPath = Get-NSudoPath -Path $NSudoPath
    } elseif (Get-Command NSudoLC -ErrorAction SilentlyContinue) {
        $NSudoPath = (Get-Command NSudoLC).Source
    }
}

if (-not $ScriptsDir) {
    if ($ProfileDir -and (Test-Path (Join-Path $ProfileDir "Scripts"))) {
        $ScriptsDir = (Resolve-Path (Join-Path $ProfileDir "Scripts")).Path
    } else {
        $candidates = @(
            (Join-Path $repo "Config\Win11\Scripts"),
            (Join-Path $repo "Config\Scripts"),
            (Join-Path $PSScriptRoot "Config\Scripts")
        )
        foreach ($cand in $candidates) {
            if (Test-Path $cand) {
                $ScriptsDir = (Resolve-Path $cand).Path
                break
            }
        }
    }
}

Write-Info "Mount Directory  : $MountDir"
Write-Info "Custom Registry  : $CustomRegPath"
Write-Info "NSudo Utility    : $NSudoPath"
Write-Info "Scripts Directory: $ScriptsDir"

# Helpers
function Remove-ForceDirectory([string]$targetPath) {
    if (Test-Path $targetPath) {
        & takeown.exe /f $targetPath /r /d y *> $null
        & icacls.exe $targetPath /grant *S-1-5-32-544:F /t /c /q *> $null
        Remove-Item -Path $targetPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ForceFile([string]$targetFile) {
    if (Test-Path $targetFile) {
        & takeown.exe /f $targetFile /a *> $null
        & icacls.exe $targetFile /grant *S-1-5-32-544:F /c /q *> $null
        Remove-Item -Path $targetFile -Force -ErrorAction SilentlyContinue
    }
}

function Clear-ForceDirectoryContents([string]$targetDir) {
    if (Test-Path $targetDir) {
        Get-ChildItem -Path $targetDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSIsContainer) {
                Remove-ForceDirectory $_.FullName
            } else {
                Remove-ForceFile $_.FullName
            }
        }
    }
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Resolve-OfflineRegPath([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return $Key }
    $k = $Key.Trim()
    if ($k -match '^(?:HKCU|HKEY_CURRENT_USER)(?:\\(.*))?$') {
        if ($matches[1]) { return "HKU\OFFLINE_DEFAULT\$($matches[1])" } else { return "HKU\OFFLINE_DEFAULT" }
    }
    if ($k -match '^(?:HKCR|HKEY_CLASSES_ROOT)(?:\\(.*))?$') {
        if ($matches[1]) { return "HKLM\OFFLINE_SOFTWARE\Classes\$($matches[1])" } else { return "HKLM\OFFLINE_SOFTWARE\Classes" }
    }
    if ($k -match '^(?:HKLM|HKEY_LOCAL_MACHINE)\\SYSTEM\\CurrentControlSet(?:\\(.*))?$') {
        if ($matches[1]) { return "HKLM\OFFLINE_SYSTEM\ControlSet001\$($matches[1])" } else { return "HKLM\OFFLINE_SYSTEM\ControlSet001" }
    }
    if ($k -match '^(?:HKLM|HKEY_LOCAL_MACHINE)\\SYSTEM(?:\\(.*))?$') {
        if ($matches[1]) { return "HKLM\OFFLINE_SYSTEM\$($matches[1])" } else { return "HKLM\OFFLINE_SYSTEM" }
    }
    if ($k -match '^(?:HKLM|HKEY_LOCAL_MACHINE)\\SOFTWARE(?:\\(.*))?$') {
        if ($matches[1]) { return "HKLM\OFFLINE_SOFTWARE\$($matches[1])" } else { return "HKLM\OFFLINE_SOFTWARE" }
    }
    if ($k -match '^HKU\\\.DEFAULT(?:\\(.*))?$') {
        if ($matches[1]) { return "HKU\OFFLINE_DEFAULT\$($matches[1])" } else { return "HKU\OFFLINE_DEFAULT" }
    }
    return $k
}

function Set-RegKey {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Key,

        [switch]$Elevated
    )
    $resolvedKey = Resolve-OfflineRegPath $Key
    $cmd = "reg add `"$resolvedKey`" /f"
    if ($Elevated) {
        Invoke-NSudo $cmd
    } else {
        cmd /c "$cmd >nul 2>&1"
        if ($LASTEXITCODE -ne 0 -and $NSudoPath -and (Test-Path $NSudoPath)) {
            Invoke-NSudo $cmd
        }
    }
}

function Set-RegValue {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Key,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$ValueName = "",

        [Parameter(Mandatory = $true, Position = 2)]
        [string]$Data,

        [Parameter(Mandatory = $false, Position = 3)]
        [string]$Type = "REG_DWORD",

        [switch]$Elevated
    )
    $resolvedKey = Resolve-OfflineRegPath $Key
    $valParam = if ($ValueName) { "/v `"$ValueName`"" } else { "/ve" }
    $cmd = "reg add `"$resolvedKey`" $valParam /t $Type /d `"$Data`" /f"
    if ($Elevated) {
        Invoke-NSudo $cmd
    } else {
        cmd /c "$cmd >nul 2>&1"
        if ($LASTEXITCODE -ne 0 -and $NSudoPath -and (Test-Path $NSudoPath)) {
            Invoke-NSudo $cmd
        }
    }
}

function Remove-RegKey {
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string[]]$Key,

        [switch]$Elevated
    )
    $validKeys = @($Key | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($validKeys.Count -eq 0) { return }
    $resolvedKeys = @($validKeys | ForEach-Object { Resolve-OfflineRegPath $_ })
    if ($Elevated) {
        $delCmds = $resolvedKeys | ForEach-Object { "reg delete `"$_`" /f" }
        Invoke-NSudo $delCmds
    } else {
        $failed = [System.Collections.Generic.List[string]]::new()
        foreach ($k in $resolvedKeys) {
            cmd /c "reg delete `"$k`" /f >nul 2>&1"
            if ($LASTEXITCODE -ne 0) {
                $failed.Add("reg delete `"$k`" /f")
            }
        }
        if ($failed.Count -gt 0 -and $NSudoPath -and (Test-Path $NSudoPath)) {
            Invoke-NSudo $failed.ToArray()
        }
    }
}

function Remove-RegValue {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Key,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$ValueName,

        [switch]$Elevated
    )
    $resolvedKey = Resolve-OfflineRegPath $Key
    $cmd = "reg delete `"$resolvedKey`" /v `"$ValueName`" /f"
    if ($Elevated) {
        Invoke-NSudo $cmd
    } else {
        cmd /c "$cmd >nul 2>&1"
        if ($LASTEXITCODE -ne 0 -and $NSudoPath -and (Test-Path $NSudoPath)) {
            Invoke-NSudo $cmd
        }
    }
}

function Get-RegValue {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Key,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$ValueName
    )
    $resolvedKey = Resolve-OfflineRegPath $Key
    $raw = @(cmd /c "reg query `"$resolvedKey`" /v `"$ValueName`" 2>nul")
    if ($LASTEXITCODE -ne 0) { return $null }
    $escapedName = [regex]::Escape($ValueName)
    foreach ($line in $raw) {
        if ($line -match "^\s*$escapedName\s+REG_\w+\s*(.*)$") {
            return $matches[1]
        }
    }
    return $null
}

function Get-RegSubKey {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Key,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$Filter = ""
    )
    $resolvedKey = Resolve-OfflineRegPath $Key
    $cmd = if ($Filter) {
        "reg query `"$resolvedKey`" /f `"$Filter`" 2>nul"
    } else {
        "reg query `"$resolvedKey`" 2>nul"
    }
    $res = @(cmd /c $cmd | Select-String -Pattern "^\s*(HKEY_|HKU\\|HKLM\\|HKCR\\|HKCU\\)")
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $res) {
        $trimmed = $line.ToString().Trim()
        if ($trimmed) { $out.Add($trimmed) }
    }
    return $out.ToArray()
}

# Compatibility aliases
Set-Alias Set-OfflineRegKey Set-RegKey
Set-Alias Remove-OfflineScheduledTask Remove-ScheduledTask
Set-Alias Set-OfflineRegValue Set-RegValue
Set-Alias Remove-OfflineRegKey Remove-RegKey
Set-Alias Remove-OfflineRegValue Remove-RegValue
Set-Alias Get-OfflineRegValue Get-RegValue
Set-Alias Get-OfflineRegSubKey Get-RegSubKey

function Remove-ScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string[]]$TaskPath
    )
    foreach ($tp in $TaskPath) {
        if ([string]::IsNullOrWhiteSpace($tp)) { continue }
        $cleanPath = $tp.Trim().TrimStart('\')
        $treeKey = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\$cleanPath"

        $id = Get-RegValue -Key $treeKey -ValueName "Id"
        if ($id) {
            Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\$id" -Elevated
            Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Plain\$id" -Elevated
            Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Maintenance\$id" -Elevated
            Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Boot\$id" -Elevated
            Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Logon\$id" -Elevated
        }

        $subKeys = Get-RegSubKey $treeKey
        foreach ($sk in $subKeys) {
            $subId = Get-RegValue -Key $sk -ValueName "Id"
            if ($subId) {
                Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\$subId" -Elevated
                Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Plain\$subId" -Elevated
                Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Maintenance\$subId" -Elevated
                Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Boot\$subId" -Elevated
                Remove-RegKey "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Logon\$subId" -Elevated
            }
        }

        Remove-RegKey $treeKey -Elevated

        $diskPath = Join-Path $MountDir "Windows\System32\Tasks\$cleanPath"
        if (Test-Path $diskPath) {
            if ((Get-Item $diskPath).PSIsContainer) {
                Remove-ForceDirectory $diskPath
            } else {
                Remove-ForceFile $diskPath
            }
        }
    }
}

function Invoke-ElevatedRegDelete([string[]]$regKeys) {
    Remove-RegKey -Key $regKeys -Elevated
}

function Remove-ForceFilesByPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string[]]$Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [string[]]$Pattern,

        [switch]$Recurse
    )
    foreach ($p in $Path) {
        if (-not (Test-Path $p)) { continue }
        foreach ($pat in $Pattern) {
            $gciParams = @{
                Path        = $p
                Filter      = $pat
                File        = $true
                ErrorAction = 'SilentlyContinue'
            }
            if ($Recurse) { $gciParams['Recurse'] = $true }
            Get-ChildItem @gciParams | ForEach-Object {
                Remove-ForceFile $_.FullName
            }
        }
    }
}

function Test-OfflineRegistryHivesMounted {
    if (Test-Path "HKLM:\OFFLINE_SYSTEM") { return $true }
    if (Test-Path "HKLM:\OFFLINE_SOFTWARE") { return $true }
    if (Test-Path "Registry::HKEY_USERS\OFFLINE_DEFAULT") { return $true }
    return $false
}

function Mount-OfflineRegistryHives([string]$targetMountDir = "") {
    if (-not $targetMountDir) {
        if (Test-Path variable:MountDir) {
            $targetMountDir = $MountDir
        } elseif (Test-Path variable:script:MountDir) {
            $targetMountDir = $script:MountDir
        }
    }
    if (Test-OfflineRegistryHivesMounted) {
        return
    }
    Write-Step "Loading Offline Registry Hives..."
    cmd /c "reg unload HKLM\OFFLINE_SYSTEM >nul 2>&1"
    cmd /c "reg unload HKLM\OFFLINE_SOFTWARE >nul 2>&1"
    cmd /c "reg unload HKU\OFFLINE_DEFAULT >nul 2>&1"

    $sysHive = "$targetMountDir\Windows\System32\config\SYSTEM"
    $sofHive = "$targetMountDir\Windows\System32\config\SOFTWARE"
    $defHive = "$targetMountDir\Users\Default\NTUSER.DAT"

    $loadSys = cmd /c "reg load HKLM\OFFLINE_SYSTEM `"$sysHive`" 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "Failed to load offline SYSTEM hive: $loadSys" }

    $loadSof = cmd /c "reg load HKLM\OFFLINE_SOFTWARE `"$sofHive`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        cmd /c "reg unload HKLM\OFFLINE_SYSTEM >nul 2>&1"
        throw "Failed to load offline SOFTWARE hive: $loadSof"
    }

    if (Test-Path $defHive) {
        cmd /c "reg load HKU\OFFLINE_DEFAULT `"$defHive`" >nul 2>&1"
    }
    Write-Success "Loaded OFFLINE_SYSTEM, OFFLINE_SOFTWARE, and OFFLINE_DEFAULT hives."
}

function Dismount-OfflineRegistryHives {
    if (-not (Test-OfflineRegistryHivesMounted)) {
        return
    }
    if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name HKU -ErrorAction SilentlyContinue | Out-Null
    }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500

    $hivesToUnload = @("HKLM\OFFLINE_SYSTEM", "HKLM\OFFLINE_SOFTWARE", "HKU\OFFLINE_DEFAULT")
    foreach ($h in $hivesToUnload) {
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            $unl = cmd /c "reg unload `"$h`" 2>&1"
            $check = cmd /c "reg query `"$h`" 2>&1"
            if ($LASTEXITCODE -ne 0) {
                Write-Success "Offline hive unloaded: $h (attempt $attempt)"
                break
            }
            Write-Warning "Failed to unload $h (attempt $attempt): $unl"
            Start-Sleep -Milliseconds 500
        }
    }
    Write-Success "Unloaded OFFLINE_SYSTEM, OFFLINE_SOFTWARE, and OFFLINE_DEFAULT hives."
}

function Invoke-WithoutOfflineHives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$MountDir = "",

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )
    $targetMount = $MountDir
    if (-not $targetMount) {
        if (Test-Path variable:MountDir) {
            $targetMount = $MountDir
        } elseif (Test-Path variable:script:MountDir) {
            $targetMount = $script:MountDir
        }
    }
    $hivesWereMounted = Test-OfflineRegistryHivesMounted
    if ($hivesWereMounted) {
        Write-Info "Ensuring offline registry hives are dismounted prior to DISM operation..."
        Dismount-OfflineRegistryHives
    }
    try {
        & $Action
    }
    finally {
        if ($hivesWereMounted -and $targetMount) {
            Write-Info "Restoring offline registry hives after DISM operation..."
            Mount-OfflineRegistryHives $targetMount
        }
    }
}

function Disable-OfflineFeature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$MountDir,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$FeatureName,

        [switch]$Remove
    )
    Invoke-WithoutOfflineHives -MountDir $MountDir -Action {
        $args = @("/English", "/Image:$MountDir", "/Disable-Feature", "/FeatureName:$FeatureName", "/NoRestart")
        if ($Remove) { $args += "/Remove" }
        $res = & dism.exe @args 2>&1
        if ($LASTEXITCODE -eq 0) {
            $statusSuffix = if ($Remove) { " with payload removed" } else { "" }
            Write-Success "Feature $FeatureName disabled$statusSuffix."
        } else {
            Write-Warning "Failed to disable feature $FeatureName : $res"
        }
    }
}

function Remove-OfflineProvisionedAppxPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$MountDir,

        [Parameter(Mandatory = $false)]
        [string]$PackageName = "",

        [Parameter(Mandatory = $false)]
        [string]$Pattern = ""
    )
    Invoke-WithoutOfflineHives -MountDir $MountDir -Action {
        if ($PackageName) {
            try {
                $null = Remove-AppxProvisionedPackage -Path $MountDir -PackageName $PackageName -ErrorAction Stop
                Write-Success "Removed provisioned package: $PackageName"
            } catch {
                & dism.exe /English /Image:$MountDir /Remove-ProvisionedAppxPackage /PackageName:$PackageName /NoRestart *> $null
                Write-Success "Removed provisioned package (dism fallback): $PackageName"
            }
        } elseif ($Pattern) {
            $provInfo = & dism.exe /English /Image:$MountDir /Get-ProvisionedAppxPackages 2>&1
            $matches = $provInfo | Where-Object { $_ -match '^PackageName\s*:\s*(.*)' }
            foreach ($line in $matches) {
                $pkg = ($line -split 'PackageName\s*:\s*')[1].Trim()
                if ($pkg -like $Pattern) {
                    & dism.exe /English /Image:$MountDir /Remove-ProvisionedAppxPackage /PackageName:$pkg /NoRestart *> $null
                    Write-Success "Removed provisioned package: $pkg"
                }
            }
        }
    }
}

function Remove-OfflineSystemApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$MountDir,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Pattern
    )
    $dirs = @(
        (Join-Path $MountDir "Windows\SystemApps"),
        (Join-Path $MountDir "Program Files\WindowsApps")
    )
    foreach ($baseDir in $dirs) {
        if (Test-Path $baseDir) {
            Get-ChildItem -Path $baseDir -Filter $Pattern -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-ForceDirectory $_.FullName
                Write-Success "Purged App directory: $($_.Name)"
            }
        }
    }
}

function Enable-WorldwideEdgeUninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$MountDir
    )
    $policyPath = "$MountDir\Windows\System32\IntegratedServicesRegionPolicySet.json"
    if (Test-Path $policyPath) {
        & takeown.exe /f $policyPath /a *> $null
        & icacls.exe $policyPath /grant *S-1-5-32-544:F *> $null

        $rawPolicy = [System.IO.File]::ReadAllText($policyPath, [System.Text.Encoding]::UTF8)
        try {
            $polObj = $rawPolicy | ConvertFrom-Json
            foreach ($p in $polObj.policies) {
                if ($p.name -eq 'Edge_UninstallEdge' -or $p.guid -eq '{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6}' -or $p.'$comment' -match 'Edge is uninstallable') {
                    $p.defaultState = 'enabled'
                }
            }
            $patchedPolicy = $polObj | ConvertTo-Json -Depth 10
        } catch {
            $patchedPolicy = [regex]::Replace(
                $rawPolicy,
                '("name"\s*:\s*"Edge_UninstallEdge"[\s\S]*?"defaultState"\s*:\s*")([^"]+)(")',
                '${1}enabled${3}'
            )
        }
        [System.IO.File]::WriteAllText($policyPath, $patchedPolicy, [System.Text.Encoding]::UTF8)
        & icacls.exe $policyPath /setowner "NT SERVICE\TrustedInstaller" *> $null
        Write-Success "Edge_UninstallEdge set to 'enabled' in-place. All other policies preserved."
    } else {
        Write-Info "IntegratedServicesRegionPolicySet.json not found."
    }
}

function Remove-RegMultiSzItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Key,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$ValueName,

        [Parameter(Mandatory = $true, Position = 2)]
        [string]$Item
    )
    $currentVal = Get-RegValue -Key $Key -ValueName $ValueName
    if ($currentVal -and $currentVal -match [regex]::Escape($Item)) {
        $items = ($currentVal -split '\\0') | Where-Object { $_ -ne $Item -and $_.Trim() -ne "" }
        $newVal = if ($items.Count -gt 0) { ($items -join '\0') + '\0' } else { "" }
        Set-RegValue $Key $ValueName $newVal "REG_MULTI_SZ"
    }
}

function Remove-OfflineCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$MountDir,

        [Parameter(Mandatory = $false)]
        [string]$CapabilityName = "",

        [Parameter(Mandatory = $false)]
        [string[]]$Pattern = @()
    )
    Invoke-WithoutOfflineHives -MountDir $MountDir -Action {
        if ($CapabilityName) {
            & dism.exe /English /Image:$MountDir /Remove-Capability /CapabilityName:$CapabilityName /NoRestart *> $null
            Write-Success "Removed capability: $CapabilityName"
        } elseif ($Pattern -and $Pattern.Count -gt 0) {
            try {
                $installedCaps = @(Get-WindowsCapability -Path $MountDir -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Installed' })
                foreach ($pat in $Pattern) {
                    $matching = $installedCaps | Where-Object { $_.Name -like $pat }
                    foreach ($c in $matching) {
                        & dism.exe /English /Image:$MountDir /Remove-Capability /CapabilityName:$($c.Name) /NoRestart *> $null
                        Write-Success "Removed capability: $($c.Name)"
                    }
                }
            } catch {
                Write-Warning "Capability discovery issue: $_"
            }
        }
    }
}

function Set-OfflineStartLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$MountDir
    )
    $shellDir = "$MountDir\Users\Default\AppData\Local\Microsoft\Windows\Shell"
    if (-not (Test-Path $shellDir)) {
        New-Item -ItemType Directory -Path $shellDir -Force | Out-Null
    }
    $layoutJson = "{" + "`r`n" +
        '  "pinnedList": [' + "`r`n" +
        '    { "packagedAppId": "windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel" },' + "`r`n" +
        '    { "desktopAppId": "Microsoft.Windows.Explorer" }' + "`r`n" +
        '  ]' + "`r`n" +
        '}'
    [System.IO.File]::WriteAllText("$shellDir\LayoutModification.json", $layoutJson, [System.Text.Encoding]::UTF8)

    $layoutXml = '<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"><LayoutOptions StartTileGroupCellWidth="6" /><DefaultLayoutOverride><StartLayoutCollection><defaultlayout:StartLayout GroupCellWidth="6" /></StartLayoutCollection></DefaultLayoutOverride></LayoutModificationTemplate>'
    [System.IO.File]::WriteAllText("$shellDir\LayoutModification.xml", $layoutXml, [System.Text.Encoding]::UTF8)
    Write-Success "Generated clean Start Menu layouts (LayoutModification.json & LayoutModification.xml)."
}

function Set-OfflineDefaultAssociations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$MountDir
    )
    $oemAssocXml = '<?xml version="1.0" encoding="UTF-8"?>' + "`r`n" +
'<DefaultAssociations>' + "`r`n" +
'  <Association Identifier=".bmp" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".dib" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".gif" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".ico" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".jfif" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".jpe" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".jpeg" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".jpg" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".jxr" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".png" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".tif" ProgId="TIFImage.Document" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".tiff" ProgId="PhotoViewer.FileAssoc.Tiff" ApplicationName="Windows Photo Viewer" />' + "`r`n" +
'  <Association Identifier=".txt" ProgId="txtfile" ApplicationName="Notepad" />' + "`r`n" +
'</DefaultAssociations>'
    $oemDest = "$MountDir\Windows\System32\OEMDefaultAssociations.xml"
    [System.IO.File]::WriteAllText($oemDest, $oemAssocXml, [System.Text.Encoding]::UTF8)
    Write-Success "Generated: $oemDest"
}

function New-FileShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$TargetPath,

        [Parameter(Mandatory = $false)]
        [string]$Arguments = "",

        [Parameter(Mandatory = $false)]
        [string]$IconLocation = "",

        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory = "",

        [Parameter(Mandatory = $false)]
        [string]$Description = ""
    )
    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $wsh = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $wsh.CreateShortcut($Path)
        $shortcut.TargetPath = $TargetPath
        if ($Arguments) { $shortcut.Arguments = $Arguments }
        if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
        if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
        if ($Description) { $shortcut.Description = $Description }
        $shortcut.Save()
        Write-Success "Created shortcut: $Path"
    } finally {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
    }
}

function Filter-OfflineProvisionedAppxPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountDir,

        [Parameter(Mandatory = $false)]
        [string[]]$EnabledApps = @(),

        [Parameter(Mandatory = $false)]
        [switch]$RemoveFrameworkDependencies = $false,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludedDependencies = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$ProtectedFrameworks = @(
            'Microsoft.VCLibs*',
            'Microsoft.UI.Xaml*',
            'Microsoft.NET.Native.Framework*',
            'Microsoft.NET.Native.Runtime*',
            'Microsoft.Services.Store.Engagement*',
            'Microsoft.WindowsAppRuntime*'
        )
    )

    if (-not $EnabledApps -or $EnabledApps.Count -eq 0) {
        if (Get-Command Get-ProfileEnabledApps -ErrorAction SilentlyContinue -and (Test-Path variable:profileChain) -and $profileChain) {
            $EnabledApps = Get-ProfileEnabledApps -ProfileChain $profileChain
        } elseif ((Test-Path variable:ProfileDir) -and $ProfileDir -and (Test-Path (Join-Path $ProfileDir "profile.psd1"))) {
            $cfg = if (Get-Command Import-ProfileManifest -ErrorAction SilentlyContinue) {
                Import-ProfileManifest -Path (Join-Path $ProfileDir "profile.psd1") -MountDir $MountDir
            } else {
                Import-PowerShellDataFile -Path (Join-Path $ProfileDir "profile.psd1")
            }
            if ($cfg.ContainsKey('EnabledApps') -and $cfg.EnabledApps) {
                $EnabledApps = $cfg.EnabledApps
            }
        }
    }

    if (-not $EnabledApps -or $EnabledApps.Count -eq 0) {
        $EnabledApps = @(
            'Microsoft.WindowsStore',
            'Microsoft.StorePurchaseApp',
            'Microsoft.SecHealthUI',
            'Microsoft.DesktopAppInstaller',
            'Microsoft.XboxIdentityProvider'
        )
    }

    if (-not $PSBoundParameters.ContainsKey('RemoveFrameworkDependencies')) {
        if (Get-Command Get-ProfileRemoveFrameworkDependencies -ErrorAction SilentlyContinue -and (Test-Path variable:profileChain) -and $profileChain) {
            $RemoveFrameworkDependencies = Get-ProfileRemoveFrameworkDependencies -ProfileChain $profileChain
        } elseif ((Test-Path variable:ProfileDir) -and $ProfileDir -and (Test-Path (Join-Path $ProfileDir "profile.psd1"))) {
            $cfg = if (Get-Command Import-ProfileManifest -ErrorAction SilentlyContinue) {
                Import-ProfileManifest -Path (Join-Path $ProfileDir "profile.psd1") -MountDir $MountDir
            } else {
                Import-PowerShellDataFile -Path (Join-Path $ProfileDir "profile.psd1")
            }
            if ($cfg.ContainsKey('RemoveFrameworkDependencies')) {
                $RemoveFrameworkDependencies = [bool]$cfg.RemoveFrameworkDependencies
            }
        }
    }

    if (-not $ExcludedDependencies -or $ExcludedDependencies.Count -eq 0) {
        if (Get-Command Get-ProfileExcludedDependencies -ErrorAction SilentlyContinue -and (Test-Path variable:profileChain) -and $profileChain) {
            $ExcludedDependencies = Get-ProfileExcludedDependencies -ProfileChain $profileChain
        } elseif ((Test-Path variable:ProfileDir) -and $ProfileDir -and (Test-Path (Join-Path $ProfileDir "profile.psd1"))) {
            $cfg = if (Get-Command Import-ProfileManifest -ErrorAction SilentlyContinue) {
                Import-ProfileManifest -Path (Join-Path $ProfileDir "profile.psd1") -MountDir $MountDir
            } else {
                Import-PowerShellDataFile -Path (Join-Path $ProfileDir "profile.psd1")
            }
            if ($cfg.ContainsKey('ExcludedDependencies') -and $cfg.ExcludedDependencies) {
                $ExcludedDependencies = $cfg.ExcludedDependencies
            }
        }
    }

    Invoke-WithoutOfflineHives -MountDir $MountDir -Action {
        try {
            $provPackages = @(Get-AppxProvisionedPackage -Path $MountDir -ErrorAction SilentlyContinue)
            $removedCount = 0
            $retainedCount = 0

            # Pass 1: Filter and remove unlisted user-facing apps
            foreach ($pkg in $provPackages) {
                $isFramework = $false
                foreach ($fw in $ProtectedFrameworks) {
                    if ($pkg.DisplayName -like $fw -or $pkg.PackageName -like $fw) {
                        $isFramework = $true
                        break
                    }
                }
                if ($isFramework) {
                    continue
                }

                $isAllowed = $false
                foreach ($app in $EnabledApps) {
                    if ($pkg.DisplayName -like "$app*" -or $pkg.PackageName -like "$app*") {
                        $isAllowed = $true
                        break
                    }
                }

                if ($isAllowed) {
                    Write-Info "Retaining provisioned app: $($pkg.DisplayName)"
                    $retainedCount++
                } else {
                    Write-Info "Removing provisioned app: $($pkg.DisplayName)..."
                    if (Remove-OfflineProvisionedAppxPackage -MountDir $MountDir -PackageName $pkg.PackageName) {
                        $removedCount++
                    }
                }
            }

            # Pass 2: Process framework runtimes (retain unless RemoveFrameworkDependencies or ExcludedDependencies matches)
            foreach ($pkg in $provPackages) {
                $isFramework = $false
                foreach ($fw in $ProtectedFrameworks) {
                    if ($pkg.DisplayName -like $fw -or $pkg.PackageName -like $fw) {
                        $isFramework = $true
                        break
                    }
                }
                if (-not $isFramework) {
                    continue
                }

                $shouldRemove = $RemoveFrameworkDependencies
                if (-not $shouldRemove -and $ExcludedDependencies -and $ExcludedDependencies.Count -gt 0) {
                    foreach ($ex in $ExcludedDependencies) {
                        if ($pkg.DisplayName -like "$ex*" -or $pkg.PackageName -like "$ex*") {
                            $shouldRemove = $true
                            break
                        }
                    }
                }

                if ($shouldRemove) {
                    Write-Info "Removing framework dependency: $($pkg.DisplayName)..."
                    if (Remove-OfflineProvisionedAppxPackage -MountDir $MountDir -PackageName $pkg.PackageName) {
                        $removedCount++
                    } else {
                        Write-Warning "Could not remove framework $($pkg.DisplayName) (likely required by an active app)."
                    }
                } else {
                    $retainedCount++
                }
            }

            Write-Success "Provisioned apps filtered: $retainedCount retained, $removedCount removed."
        } catch {
            Write-Warning "Provisioned Appx filtering issue: $_"
        }
    }
}

function Import-OfflineRegistryFile([string]$regFile) {
    Write-Info "Translating and importing registry pack: $(Split-Path $regFile -Leaf)"
    $regRaw = Get-Content -Path $regFile -Raw

    $replacements = @(
        @('HKEY_CLASSES_ROOT\', 'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\Classes\'),
        @('HKEY_CLASSES_ROOT',   'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\Classes'),
        @('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\', 'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\ControlSet001\'),
        @('HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\',     'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\ControlSet001\'),
        @('HKEY_LOCAL_MACHINE\SYSTEM\',                   'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\'),
        @('HKEY_LOCAL_MACHINE\SOFTWARE\',                 'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\'),
        @('HKEY_LOCAL_MACHINE\Software\',                 'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\'),
        @('HKLM\SYSTEM\CurrentControlSet\',               'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\ControlSet001\'),
        @('HKLM\SYSTEM\ControlSet001\',                   'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\ControlSet001\'),
        @('HKLM\SYSTEM\',                                 'HKEY_LOCAL_MACHINE\OFFLINE_SYSTEM\'),
        @('HKLM\SOFTWARE\',                               'HKEY_LOCAL_MACHINE\OFFLINE_SOFTWARE\'),
        @('HKEY_USERS\.DEFAULT\',                         'HKEY_USERS\OFFLINE_DEFAULT\'),
        @('HKEY_CURRENT_USER\',                           'HKEY_USERS\OFFLINE_DEFAULT\'),
        @('HKEY_CURRENT_USER',                             'HKEY_USERS\OFFLINE_DEFAULT')
    )
    foreach ($r in $replacements) {
        $regRaw = $regRaw.Replace($r[0], $r[1])
    }

    $linesArr = $regRaw -split "\r?\n"
    $filtered = [System.Collections.Generic.List[string]]::new()
    $skip = $false

    foreach ($l in $linesArr) {
        if ($l -match '^\s*\[(.*)\]\s*$') {
            if ($matches[1] -match 'CurrentVersion\\Communications') {
                $skip = $true
            } else {
                $skip = $false
            }
        }
        if (-not $skip) {
            $filtered.Add($l)
        }
    }

    $tmpReg = Join-Path $env:TEMP "offline_import_$([System.IO.Path]::GetRandomFileName()).reg"
    try {
        $regOutText = [string]::Join("`r`n", $filtered)
        [System.IO.File]::WriteAllText($tmpReg, $regOutText, [System.Text.Encoding]::Unicode)
        $impRes = cmd /c "reg import `"$tmpReg`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: reg import reported on $(Split-Path $regFile -Leaf): $impRes" -ForegroundColor Yellow
        } else {
            Write-Success "Registry pack $(Split-Path $regFile -Leaf) imported successfully."
        }
    } finally {
        if (Test-Path $tmpReg) { Remove-Item $tmpReg -Force -ErrorAction SilentlyContinue }
    }
}

# -------------------------------------------------------------
# PHASE 1: DISM Servicing Phase (Offline Registry Hives Dismounted)
# -------------------------------------------------------------
# Run DISM AppX package filtering prior to mounting offline registry hives to eliminate Error 32 sharing violations.
Write-Step "Phase 1: Filtering Provisioned Appx Packages (DISM)..."
Filter-OfflineProvisionedAppxPackages -MountDir $MountDir

# -------------------------------------------------------------
# PHASE 2: Offline Registry Servicing & Modular Profile Scripts
# -------------------------------------------------------------
Write-Step "Phase 2: Mounting Offline Registry Hives & Executing Profile Servicing..."
Mount-OfflineRegistryHives $MountDir

try {
    # Auto-detect and import OS registry packs
    $regFilesToImport = [System.Collections.Generic.List[string]]::new()
    if ($CustomRegPath -and (Test-Path $CustomRegPath -PathType Leaf)) {
        $regFilesToImport.Add((Resolve-Path $CustomRegPath).Path)
    }

    # Add profile-defined registry files
    foreach ($prf in $profileRegFiles) {
        if (-not $regFilesToImport.Contains($prf)) {
            $regFilesToImport.Add($prf)
        }
    }

    if ($RegistryDir) {
        $osRegDirs = @(
            (Join-Path $RegistryDir "OS"),
            $RegistryDir
        )
        foreach ($d in $osRegDirs) {
            if (Test-Path $d) {
                $osRegFiles = Get-ChildItem -Path $d -Filter "*.reg" -File | Sort-Object Name
                foreach ($rf in $osRegFiles) {
                    $resolved = (Resolve-Path $rf.FullName).Path
                    if (-not $regFilesToImport.Contains($resolved)) {
                        $regFilesToImport.Add($resolved)
                    }
                }
                if ($osRegFiles.Count -gt 0 -and $d -ne $RegistryDir) {
                    break
                }
            }
        }
    }

    foreach ($regFile in $regFilesToImport) {
        Import-OfflineRegistryFile $regFile
    }

    # Execute modular servicing scripts from profile manifest
    if ($profileScripts.Count -gt 0) {
        foreach ($s in $profileScripts) {
            Write-Step "Executing Profile Script: $(Split-Path $s -Leaf)..."
            $scriptArgs = @{
                MountDir      = $MountDir
                CustomRegPath = $CustomRegPath
                NSudoPath     = $NSudoPath
            }
            if ($ForceRemoveDefender -and ($s -match 'Remove-DefenderAndSmartScreen\.ps1')) {
                $scriptArgs['RemoveDefender'] = $true
            }
            . $s @scriptArgs
        }
    } elseif ($ScriptsDir -and (Test-Path $ScriptsDir)) {
        $searchDirs = @(
            (Join-Path $ScriptsDir "All"),
            (Join-Path $ScriptsDir "OS")
        )
        $scriptsList = @()
        foreach ($d in $searchDirs) {
            if (Test-Path $d) {
                $scriptsList += Get-ChildItem -Path $d -Filter "*.ps1" | Where-Object { -not $_.PSIsContainer }
            }
        }
        $scriptsList += Get-ChildItem -Path $ScriptsDir -Filter "*.ps1" | Where-Object { -not $_.PSIsContainer }
        $scriptsList = $scriptsList | Sort-Object Name
        foreach ($s in $scriptsList) {
            Write-Step "Executing Servicing Component: $($s.Name)..."
            . $s.FullName -MountDir $MountDir -CustomRegPath $CustomRegPath -NSudoPath $NSudoPath
        }
    } else {
        Write-Info "No modular servicing scripts executed."
    }
}
finally {
    Dismount-OfflineRegistryHives
    if ($ForceRemoveDefender) {
        Remove-Item env:FORCE_REMOVE_DEFENDER -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------
# PHASE 3: Component Cleanup (/ResetBase)
# -------------------------------------------------------------
if (-not $SkipCleanup) {
    Write-Step "Phase 3: Running DISM Component Cleanup (/ResetBase)..."
    $cleanRes = & dism.exe /English /Image:$MountDir /Cleanup-Image /StartComponentCleanup /ResetBase /NoRestart 2>&1
    Write-Success "Component cleanup executed successfully."
} else {
    Write-Info "Skipping component cleanup (-SkipCleanup specified)."
}

# Release any lingering file handles and restore working directory away from MountDir
Set-Location $env:TEMP
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Milliseconds 500
