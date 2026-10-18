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

    # Universal and version-specific registry files (dynamically evaluated using exposed $targetOS number e.g. 10 or 11)
    RegistryFiles = @(
        'OS/Registry/Common.reg'
        "OS/Registry/Win$targetOS.reg"
    ) | Where-Object { $_ }

    # Modular servicing scripts to execute
    Scripts = @() | Where-Object { $_ }
}
