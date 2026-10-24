@{
    # Profile Name
    Name = 'Debloat'

    # Parent profile to inherit root baseline settings from
    Extends = 'Default'

    # Description
    Description = "Universal root debloat configuration for $targetOS"

    # Output ISO and Volume naming
    IsoTag = '.Debloat'
    IsoNameFormat = '{TargetName}-{Edition}-{Version}-Lite-{Build}'
    VolumeLabel = ''

    # UUP dump converter settings (offline servicing requires raw WIM and skipped ISO creation)
    ConvertConfig = @{
        SkipISO       = 1
        vSkipISO      = 1
        wim2esd       = 0
        vwim2esd      = 0
        vDeleteSource = 1
    }

    # Whitelisted provisioned Modern Store apps to retain
    EnabledApps = @(
        'Microsoft.WindowsStore',
        'Microsoft.StorePurchaseApp',
        'Microsoft.DesktopAppInstaller',
        'Microsoft.XboxIdentityProvider'
    )

    # Force remove all framework dependencies (Microsoft.VCLibs, Microsoft.UI.Xaml, .NET.Native)
    # WARNING: Enabling this will break the remaining Store apps above because they depend on these runtimes.
    # Only enable if EnabledApps is empty (@()) and you want a 100% headless/legacy win32-only OS.
    # RemoveFrameworkDependencies = $true

    # Granular removal of specific legacy or unused framework dependencies (commented out by default)
    # ExcludedDependencies = @(
    #     'Microsoft.UI.Xaml.2.4',
    #     'Microsoft.NET.Native.Framework.1.7'
    # )

    # Universal and version-specific registry files (dynamically evaluated using exposed $targetOS number e.g. 10 or 11)
    RegistryFiles = @(
        'OS/Registry/Common.reg'
        "OS/Registry/Win$targetOS.reg"
    ) | Where-Object { $_ }

    # Modular servicing scripts to execute
    Scripts = @(
        'OS/Scripts/Remove-TelemetryAndDiagnostics.ps1'
        'OS/Scripts/Remove-DefenderAndSmartScreen.ps1'
        'OS/Scripts/Remove-ContentDeliveryManager.ps1'
        if ($targetOS -eq '11') { 'OS/Scripts/Remove-AIAndCloudServices.ps1' }
        'OS/Scripts/Remove-BrowsersAndEdgeComponents.ps1'
        'OS/Scripts/Remove-RemoteAccess.ps1'
        'OS/Scripts/Optimize-DiskFootprint.ps1'
        'OS/Scripts/Remove-ShellFlyoutsAndAuxiliaryApps.ps1'
        'OS/Scripts/Remove-DefaultAppsAndCapabilities.ps1'
        'OS/Scripts/Configure-SystemAndFirstBoot.ps1'
    ) | Where-Object { $_ }
}
