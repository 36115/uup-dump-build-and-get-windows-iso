@{
    # =========================================================================
    # Windows ISO Build Configuration (BuildConfig.psd1)
    # =========================================================================
    # This configuration is loaded automatically by .\Build-Iso.ps1 and
    # .\Build-Iso.cmd. You can edit this file directly or select presets
    # interactively via `.\Build-Iso.ps1 -Menu`.
    # =========================================================================

    # Target Windows Build / Ring
    # Options (matching Utils/UUPDump/Get-UupDumpIso.ps1 definitions):
    #   'windows-11@24h2'      : Windows 11 26100 (24H2, GE Release) [Default]
    #   'windows-11@23h2'      : Windows 11 22631 (23H2)
    #   'windows-10'           : Windows 10 19045 (22H2)
    #   'windows-11@24h2_beta' : Windows 11 26120 (24H2 Beta)
    #   'windows-11@25h2'      : Windows 11 26200 (25H2)
    #   'windows-11@25h2_beta' : Windows 11 26220 (25H2 Beta)
    #   'windows-11@26h1'      : Windows 11 28000 (26H1)
    #   'windows-11@26h2'      : Windows 11 26300 (26H2)
    #   'windows-11@26h2_exp'  : Windows 11 26340 (26H2 Experimental)
    #   'windows-dev'          : Windows 11 26300 (Dev Channel)
    #   'windows-canary'       : Windows 11 Insider Preview (Canary Channel)
    Target       = 'windows-11@26h2'

    # CPU Architecture
    # Options: 'x64', 'arm64'
    Architecture = 'x64'

    # Windows Edition
    #   'pro'                     : Windows Pro [Default]
    #   'home'                    : Windows Home (Core)
    #   'multi'                   : Multi-Edition (Home + Pro in single ISO)
    #   'homesinglelanguage'      : Windows Home Single Language
    #   'enterprise'              : Windows Enterprise
    #   'education'               : Windows Education
    #   'professionalworkstation' : Windows Pro for Workstations
    #   'professionaleducation'   : Windows Pro Education
    #   'iotenterprise'           : Windows IoT Enterprise
    #   'iotenterprisek'          : Windows IoT Enterprise K
    #   'serverrdsh'              : Windows Enterprise multi-session
    #   (Shorthand aliases like 'core', 'homesl', 'proworkstation', 'proeducation' are also supported)
    Edition      = 'pro'

    # Language code
    # Options: 'en-us', 'zh-cn', 'es-es', 'de-de', 'fr-fr', 'ja-jp', etc.
    Language     = 'en-us'

    # Servicing & Debloat Profile
    # Options:
    #   'Debloat' : Applies modular debloat scripts & registry customizations from Config/Debloat
    #   ''        : Pure vanilla Windows ISO without servicing modifications
    ProfileName  = 'Debloat'

    # Separate Defender Editions Installer Options
    # If $true, generates a single ISO with dual edition selection in Windows Setup:
    #   1. "<Edition> (Defender)"    - with Windows Defender & Security Health UI
    #   2. "<Edition> (No Defender)" - with Defender, SmartScreen, and SecurityHealth purged
    SeparateDefenderEditions = $true

    # Compression & Component Flags
    Esd          = $false   # Use ESD compression (smaller ISO, slower compression)
    Drivers      = $false   # Integrate additional drivers from Drivers/ folder
    NetFx3       = $false   # Integrate .NET Framework 3.5 (offline FOD)
    WimOnly      = $false   # Generate install.wim only (skip packing into final .iso)

    # Output Directory
    OutDir       = 'Out'

    # UUP Dump Download & Cache Behavior
    # If $false, reuses existing cached base Windows media under Out/BaseIso if UUP configs haven't changed.
    # Set to $true or pass -ForceDownload to bypass cache and redownload fresh from UUP Dump.
    ForceDownload = $false

    # Optional specific revision (leave empty '' for latest available on UUP)
    Revision     = ''
}
