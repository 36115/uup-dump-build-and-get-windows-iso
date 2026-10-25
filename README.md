# About

This creates an iso file with the latest Windows available from the [Unified Update Platform (UUP)](https://docs.microsoft.com/en-us/windows/deployment/update/windows-update-overview).

This shrink wraps the [UUP dump](https://git.uupdump.net/uup-dump) project into a single command.

# The whole was written for the use with Github Actions.
Just fork this repository and use Github Actions to build your own version.

Once the GitHub actions are complete, you'll receive a finished ISO image in two flavors.

1. Release with the .iso file split into several parts (as GitHub doesn't allow files larger than 2GB to be included in a release).
Additionally, for each release, packages are created for various systems and architectures, containing a ready-made script that downloads all parts of the split ISO and returns the finished ISO file.
2. Artifacts - a single zip file, but logging in to the website is required to download.

# You can also executed directly on a Windows x64 or arm64 host (min. 21H2).

## This supports the following: 
Windows Builds:
* `windows-10`: Windows 10 19045 (aka 22H2)
* `windows-11old`: Windows 11 22631 (aka 23H2)
* `windows-11`: Windows 11 26100 (aka 24H2)
* `windows-11beta`: Windows 11 26120 (aka 24H2 BETA)
* `windows-11new`: Windows 11 26200 (aka 25H2)
* `windows-11dev`: Windows 11 26220 (aka 25H2 BETA)
* `windows-1126h1`: Windows 11 28000 (aka 26H1) <details><summary>Details</summary>for new 2026 devices with select new silicon (e.g., Snapdragon X2) to enable new hardware innovations - not for existing PCs or general enterprise deployments.</details>

* `windows-1126h2`: Windows 11 26300 (aka 26H2)
* `windows-1126h2beta`: Windows 11 26340 (aka 26H2 Experimental)
* `windows-dev`: Windows 11 26300 (aka DEV)
* `windows-canary`: Windows 11 Insider Preview (aka CANARY)


Architecture:
* `x64`
* `arm64`


Edition:
* `home`
* `pro`
* `multi`: Home + Pro


Language:
* `ar-sa`: Arabic (Saudi Arabia)
* `bg-bg`: Bulgarian (Bulgaria)
* `cs-cz`: Czech (Czech Republic)
* `da-dk`: Danish (Denmark)
* `de-de`: German (Germany)
* `el-gr`: Greek (Greece)
* `en-gb`: English (United Kingdom)
* `en-us`: English (United States)
* `es-es`: Spanish (Spain)
* `es-mx`: Spanish (Mexico)
* `et-ee`: Estonian (Estonia)
* `fi-fi`: Finnish (Finland)
* `fr-ca`: French (Canada)
* `fr-fr`: French (France)
* `he-il`: Hebrew (Israel)
* `hr-hr`: Croatian (Croatia)
* `hu-hu`: Hungarian (Hungary)
* `it-it`: Italian (Italy)
* `ja-jp`: Japanese (Japan)
* `ko-kr`: Korean (Korea)
* `lt-lt`: Lithuanian (Lithuania)
* `lv-lv`: Latvian (Latvia)
* `nb-no`: Norwegian Bokmål (Norway)
* `nl-nl`: Dutch (Netherlands)
* `pl-pl`: Polish (Poland)
* `pt-br`: Portuguese (Brazil)
* `pt-pt`: Portuguese (Portugal)
* `ro-ro`: Romanian (Romania)
* `ru-ru`: Russian (Russia)
* `sk-sk`: Slovak (Slovakia)
* `sl-si`: Slovenian (Slovenia)
* `sr-latn-rs`: Serbian (Latin, Serbia)
* `sv-se`: Swedish (Sweden)
* `th-th`: Thai (Thailand)
* `tr-tr`: Turkish (Turkey)
* `uk-ua`: Ukrainian (Ukraine)
* `zh-cn`: Chinese (Simplified, China)
* `zh-tw`: Chinese (Traditional, Taiwan)


Additional options:
* `esd`: Use ESD compression
* `drivers`: Add drivers from Drivers folder
* `netfx3`: Add .NET Framework 3.5
* `revision`: System Revision Number


## Usage

### Quick Start (Local Machine)

Run with zero arguments to build using your active configuration:

```powershell
.\Build-Iso.ps1
```

#### Interactive Preset Menu:
```powershell
.\Build-Iso.ps1 -Menu
```

#### Choose a Predefined Build Preset:
```powershell
.\Build-Iso.ps1 -Preset Win11-26H2-Pro-SeparateDefender
.\Build-Iso.ps1 -Preset Win10-22H2-Pro-SeparateDefender
.\Build-Iso.ps1 -ListPresets
```

#### Command-Line Overrides:
```powershell
.\Build-Iso.ps1 -windowsTargetName windows-11@26h2 -edition pro -separateDefenderEditions:$true -destinationDirectory Out
```

---

### Command-Line / CI Usage

Run directly with positional or named parameters:

```powershell
pwsh Build-Iso.ps1 windows-11@26h2 Out -architecture x64 -edition pro -lang en-us -profileName Debloat -separateDefenderEditions
```

---

### Smart Base Media & Package Caching (Fast Rebuilds)

The build engine provides a **two-tier caching system** to avoid multi-gigabyte re-downloads:

1. **Tier 1 — Base ISO Cache (`Out/BaseIso/`)**:
   - Reuses pristine pre-built Windows base ISOs immediately in **seconds** when building repeatedly or modifying post-servicing settings (e.g. `SeparateDefenderEditions`, debloat profiles, registry files, or custom scripts).
   - Smart configuration hashing tracks impacting parameters and automatically invalidates the cache only if essential settings change.
2. **Tier 2 — Raw UUP Package Cache (`Out/UupPackages/`)**:
   - Preserves downloaded Microsoft update packages (`*.cab`, `*.esd`, `UpdateAgent.dll`).
   - If you modify UUP converter settings (such as `SkipEdge`, `ResetBase`, `SkipWinRE`, `StartVirtual`, or `wim2esd`), `aria2c` verifies local checksums in 2 seconds, downloads **0 MB from Microsoft**, and UUP dump rebuilds the ISO locally in 2–3 minutes.

- **Excluded Settings:** Operational settings that do NOT alter the final Windows image bytes (such as `AutoExit`, `Cleanup`, `AutoStart`, `ForceDism`, `SkipISO` packaging, and offline servicing options like `SeparateDefenderEditions`) do not invalidate the cache.
- **Force Fresh Download:** Bypass both caches at any time using `-forceDownload` or disable caching with `-noCache`:
  ```powershell
  .\Build-Iso.ps1 -forceDownload
  ```


## Tags structure

```text
  .------------------------------- OS Build
  |    .-------------------------- System Revision
  |    |    .--------------------- Release Channel/Version
  |    |    |    .---------------- System Edition
  |    |    |    |   .------------ CPU architecture
  |    |    |    |   |  .--------- Language
  |    |    |    |   |  |  .------ Image is compressed by ESD (optional)
  |    |    |    |   |  |  | .---- Include additional drivers (optional)
  |    |    |    |   |  |  | | .-- Include .NET Framework 3.5 (optional)
__|__ _|__ _|__ _|_ _|_ |_ | | |
26300.9711.26H2.PRO.X64.PL.E.D.N
```

## Related Tools

* [Rufus](https://github.com/pbatard/rufus)
* [Fido](https://github.com/pbatard/Fido)
* [windows-evaluation-isos-scraper](https://github.com/rgl/windows-evaluation-isos-scraper)

## Reference

* [UUP dump home](https://uupdump.net)
* [UUP dump source code](https://git.uupdump.net/uup-dump)
* [Unified Update Platform (UUP)](https://docs.microsoft.com/en-us/windows/deployment/update/windows-update-overview)
