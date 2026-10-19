<#
.SYNOPSIS
    Removes bloat files, upgrade manifests, telemetry agents, and foreign boot fonts from Windows ISO media.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$MediaDir,

    [Parameter(Mandatory = $false)]
    [string]$TargetOS = "",

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludedItems = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command Remove-IsoBloatItems -ErrorAction SilentlyContinue)) {
    $candidates = @(
        (Join-Path $PSScriptRoot "..\..\..\Utils\ISO\New-IsoImage.ps1"),
        (Join-Path $PSScriptRoot "..\..\..\..\Utils\ISO\New-IsoImage.ps1"),
        "Utils\ISO\New-IsoImage.ps1"
    )
    foreach ($cand in $candidates) {
        if (Test-Path $cand) { . (Resolve-Path $cand).Path; break }
    }
}

# Directories to strip from sources\
$isoBloatDirectories = @(
    "replacementmanifests",
    "migration",
    "dlmanifests",
    "sxs",
    "uup",
    "etwproviders",
    "support",
    "asz",
    "ca-es",
    "eu-es",
    "gl-es",
    "id-id",
    "vi-vn",
    "xp",
    "vista"
)

# Upgrade manifests, compatibility databases, telemetry agents, and bloat files to strip from sources\
$isoBloatFiles = @(
    "appraiser.dll", "appraiserres.dll",
    "diagtrackrunner.exe", "diagnostic.dll",
    "admtv3check.dll", "itgtupg.dll", "ntdsupg.dll", "ntfrsupg.dll", "rdsupgcheck.dll", "rmsupg.dll", "wdsupgcompl.dll",
    "sflistrs1.dat", "sflistw7.dat", "sflistw8.dat", "sflistwb.dat", "sflistwt.dat",
    "sfpatrs1.inf", "sfpatw7.inf", "sfpatw8.inf", "sfpatwb.inf", "sfpatwt.inf",
    "acmigration.dll", "acres.dll", "actionqueue.dll", "adfscomp.dll", "aeinv.dll",
    "appcompat_detailed.xsl", "appcompat_detailed_bidi.xsl", "appcompatservicing.dll",
    "appraiser.sdb", "appraiserdatasha1.cat", "appraiserwc.dll",
    "background_cli.bmp", "cdplib.mof", "cdplibuninstall.mof", "clustercompliance.dll", "cmi2migxml.dll",
    "compatresources.dll", "compres.dll", "csiagent.dll", "cversion.ini", "db_msftproductionwindowssigningca.cer",
    "devinv.dll", "du.dll", "facilitator.dll", "gatherosstate.exe", "generaltel.dll",
    "hwcompatPE.txt", "hwexcludePE.txt", "hypervcomplcheck.dll", "iasmigplugin.dll", "iiscomp.dll",
    "migapp.xml", "migcore.dll", "mighost.exe", "migisol.dll", "migres.dll", "migstore.dll", "migsys.dll", "migtestplugin.dll",
    "mitigation.dll", "mxeagent.dll", "nxquery.inf", "nxquery.sys", "offlineprofileutils.dll",
    "oscomps.woa.xml", "oscomps.xml", "osfilter.inf", "outofbox_windows_db.bin", "pnppropmig.dll", "product.ini",
    "reportgen.dll", "reservemanager.dll", "sdbapiu.dll", "setupdiag.exe", "setuperror.exe",
    "sfcn.dat", "sflcid.dat", "sfpat.inf", "sfpatrs1.inf", "sfpatw7.inf", "sfpatw8.inf", "sfpatwb.inf", "sfpatwt.inf",
    "sflistrs1.dat", "sflistw7.dat", "sflistw8.dat", "sflistwb.dat", "sflistwt.dat",
    "uddicomp.dll", "uninstall.xml", "uninstall_data.xml", "updateagent.dll",
    "upgrade_bulk.xml", "upgrade_comp.xml", "upgrade_data.xml", "upgradeagent.dll", "upgradeagent.xml", "upgwow_bulk.xml",
    "wicadevicefilters.xml", "winsetupboot.hiv", "winsetupboot.sys"
)

# Unneeded documentation and orphaned .mui files to strip from language folders in sources\
$isoBloatLanguageFiles = @(
    "acres.dll.mui", "actionqueue.dll.mui", "appraiserwc.dll.mui", "compatresources.dll.mui", "compres.dll.mui",
    "credits.rtf", "erofflps.txt", "migres.dll.mui", "oobe_help_opt_in_details.rtf", "privacy.rtf",
    "setup_help_whattokeep.rtf", "setuperror.exe.mui"
)

# Unneeded EFI boot files to strip from efi\Microsoft\boot\
$isoBloatEfiFiles = @(
    "boot.stl", "cdboot_noprompt.efi", "efisys_noprompt.bin"
)

# Footprint directories, binaries, and manifests required by Windows 11 Modern Setup
$win11FootprintExclusions = @(
    "replacementmanifests", "migration", "dlmanifests", "sxs", "miggac",
    "diagtrackrunner.exe", "pnppropmig.dll", "cmi2migxml.dll", "csiagent.dll", "du.dll",
    "reservemanager.dll", "winsetupboot.hiv", "winsetupboot.sys", "winsetupmon.hiv", "winsetupmon.sys",
    "migcore.dll", "mighost.exe", "migisol.dll", "migres.dll", "migstore.dll", "migsys.dll",
    "mxeagent.dll", "offlineprofileutils.dll", "oscomps.xml", "osfilter.inf",
    "hwcompatpe.txt", "hwexcludepe.txt", "migapp.xml", "uninstall.xml", "uninstall_data.xml",
    "upgrade_bulk.xml", "upgrade_comp.xml", "upgrade_data.xml", "upgradeagent.dll", "upgradeagent.xml", "upgwow_bulk.xml",
    "sfcn.dat", "sflcid.dat", "sfpat.inf", "sfpatrs1.inf", "sfpatw7.inf", "sfpatw8.inf", "sfpatwb.inf", "sfpatwt.inf",
    "sflistrs1.dat", "sflistw7.dat", "sflistw8.dat", "sflistwb.dat", "sflistwt.dat",
    "migres.dll.mui", "servicingcommon.dll", "updatecompression.dll", "diager.dll", "diagtrack.dll"
)

Remove-IsoBloatItems `
    -MediaDir $MediaDir `
    -TargetOS $TargetOS `
    -ExcludedItems $ExcludedItems `
    -Directories $isoBloatDirectories `
    -Files $isoBloatFiles `
    -LanguageFiles $isoBloatLanguageFiles `
    -EfiFiles $isoBloatEfiFiles `
    -FootprintExclusions $win11FootprintExclusions
