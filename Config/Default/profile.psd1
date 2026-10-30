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
        Cleanup   = 0
    }

    # Windows Setup automation (injected into boot.wim Index 2, Panther, and sources\ei.cfg)
    # Default answer file: 'Config/Default/WinPE/autounattend.xml'
    # Default setup channel config: 'Config/Default/WinPE/ei.cfg' ([Channel] _Default)
    # UnattendFile = 'WinPE/autounattend.xml'
    # EiCfgFile    = 'WinPE/ei.cfg'

    # Modular servicing scripts to execute
    Scripts = @(
        if ($targetOS -eq '11') { 'Scripts/Bypass-HardwareRequirements.ps1' }
    ) | Where-Object { $_ }
}
