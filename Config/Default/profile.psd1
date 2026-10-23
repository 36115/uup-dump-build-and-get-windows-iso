@{
    # Profile Name
    Name = 'Default'

    # Description
    Description = "Baseline stock $targetOS installation with universal setup configuration"

    # Output ISO and Volume naming
    IsoTag = ''
    IsoNameFormat = ''
    VolumeLabel = ''

    # Universal registry files shared by both Windows 10 and 11 (clean default has none)
    RegistryFiles = @(
        # Version-specific registry files can be directly applied here based on exposed $targetOS (e.g. "OS/Registry/Win$targetOS.reg")
    ) | Where-Object { $_ }

    # UUP dump converter settings (overrides for ConvertConfig.ini)
    ConvertConfig = @{
        AutoExit  = 1
        ResetBase = 1
        Cleanup   = 1
    }

    # Modular servicing scripts to execute
    Scripts = @()
}
