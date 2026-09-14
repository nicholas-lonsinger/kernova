# Which macOS builds get a restore image

**Date:** 2026-09-14, the day macOS 27.0 (26A428), 26.7 (25G229) and 15.8
(24H23) shipped · **Host:** macOS 27.0 (Darwin 27.0.0)

## Summary

A macOS VM installs only from a restore image (`.ipsw`). Apple publishes one
restore image per device: the current release of the newest major version.
Updates to the previous major version released alongside or after it get a full installer
and no restore image — observed for 26.7 today and for every 15.7.x.

The full installers are listed by `softwareupdate`, for several versions of
each major line at once. Nothing in an installer's catalog entry leads to a
restore image, so that catalog is not a source for restore images. An
installer upgrades an existing guest to an exact version; it cannot create one.

## Restore images

`https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml`,
the feed `Tools/regen-restore-image-catalog.swift` reads, named one image for
all 119 devices it lists:

```
curl -s <feed> | grep -o 'UniversalMac_[^<]*ipsw' | sort | uniq -c
    119 UniversalMac_27.0_26A428_Restore.ipsw
```

Apple's public version list, `https://gdmf.apple.com/v2/pmv`, posted 26.7
(25G229) and 27.0 (26A428) the same day, so 26.7 is a shipped release with no
image in the feed.

The bundled catalog shows the same pattern for macOS 15: its newest build is
15.6.1 (24G90), the last release before 26.0, and no 15.7.x image was ever
recovered from the feed's archived snapshots or the archive's crawl index.

## Full installers

`softwareupdate --list-full-installers` listed, for macOS 15:

```
* Title: macOS Sequoia, Version: 15.8, Size: 15296950KiB, Build: 24H23
* Title: macOS Sequoia, Version: 15.7.9, Size: 15289021KiB, Build: 24G830
* Title: macOS Sequoia, Version: 15.7.8, Size: 15288760KiB, Build: 24G824
* Title: macOS Sequoia, Version: 15.7.7, Size: 15288576KiB, Build: 24G720
```

`softwareupdate --fetch-full-installer --full-installer-version <version>`
downloads one of them. The same four are `InstallAssistant.pkg` products in
Apple's software update catalog,
`https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog`,
which held 19 such products back to 11.7.10. A product's version and build are
in its distribution file (`VERSION` and `BUILD` keys), not in its URL. The
catalog contains no `.ipsw` URL.

## Installer and restore image for the same build

Six builds had both. None of the restore image's path tokens appears anywhere
in the software update catalog, and the part numbers never match:

| Build | Installer part | Installer posted | Restore image part | Image Last-Modified |
|---|---|---|---|---|
| 26.5.1 (25F80) | 122-84023 | 2026-06-09 | 122-88870 | 2026-05-28 |
| 26.5.2 (25F84) | 140-36226 | 2026-07-07 | 140-24263 | 2026-06-25 |
| 26.6 (25G72) | 140-71750 | 2026-07-27 | 140-65618 | 2026-07-24 |
| 26.6.1 (25G76) | 140-77964 | 2026-08-06 | 140-83079 | 2026-08-03 |
| 26.6.2 (25G83) | 140-93587 | 2026-08-24 | 140-75212 | 2026-08-13 |
| 27.0 (26A428) | 142-15488 | 2026-09-14 | none in path | 2026-09-04 |

Only the three-digit prefix is shared. The restore image's UUID path segment
was absent from the catalog in every case, and so were `.ipsw` references and
`updates.cdn-apple.com` in the two sidecar files checked (`InstallInfo.plist`
and `com_apple_MobileAsset_MacSoftwareUpdate.plist`, for 25G83 and 26A428).

27.0's image URL drops the `fullrestores/<part>/` segments and uses a lowercase
UUID: `updates.cdn-apple.com/2026FallFCS/afcfc88e-bbe6-44bf-a5da-07c56eebc06c/UniversalMac_27.0_26A428_Restore.ipsw`.
