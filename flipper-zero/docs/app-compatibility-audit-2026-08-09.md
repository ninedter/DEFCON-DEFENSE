# Flipper App Compatibility Audit - 2026-08-09

## Device and root cause

- Device: `N4tar4n`, hardware target 7
- Firmware: Official `1.4.3`
- Firmware API: `87.1`
- SD card: mounted and healthy

The official firmware update replaced the previous `/ext/apps` tree with 15
stock/current FAPs. The prior app-data directories remained intact, so saved
application data was preserved.

## Recovery completed

- Backed up the 15 post-update FAPs before making changes.
- Restored 236 missing menu applications into their original categories.
- Preserved all 15 current official FAPs rather than overwriting them with
  Momentum system builds.
- Kept 13 Momentum-only internal Settings/Assets FAPs out of the official
  firmware tree to avoid replacing official system applications.
- Downloaded and installed 41 API 87.1 replacements from the official Flipper
  application catalog.
- Rebuilt and installed DEFCON Defense with the official `1.4.3` SDK.
- Preserved `/ext/apps_data`, including Marauder and DEFCON Defense data.

The restored app tree initially contained 251 menu FAPs. All 251 had valid
target-7, API-87.1 manifests. Calculator, WiFi Marauder, and the rebuilt DEFCON
Defense were launched safely from the on-device Apps menu.

## Official-firmware import result

- Fully compatible with official `1.4.3`: 226 FAPs
- Momentum-only imports remaining: 25 FAPs
- Malformed FAPs: 0

The following apps did not have an exact current official-catalog build and
still imported Momentum-only functions or graphics:

- `Bluetooth/ble_spam.fap`
- `GPIO/ESP/esp8266_ifttt_virtual_button.fap`
- `GPIO/ESP/esp8266_wifi_deauther_v2.fap`
- `GPIO/ESP/evil_portal.fap`
- `GPIO/ESP/wardriver.fap`
- `GPIO/ESP/wifi_scanner.fap`
- `GPIO/MAYHEM/mayhem_camera.fap`
- `GPIO/MAYHEM/mayhem_marauder.fap`
- `GPIO/MAYHEM/mayhem_morseflash.fap`
- `GPIO/NRF24/nrf24batch.fap`
- `GPIO/NRF24/nrf24mousejacker.fap`
- `GPIO/NRF24/nrf24scan.fap`
- `GPIO/NRF24/nrf24sniff.fap`
- `GPIO/gpio_reader_b.fap`
- `GPIO/timelapse.fap`
- `Games/simon_says.fap`
- `Infrared/ir_remote.fap`
- `Media/etch.fap`
- `NFC/nfc_playlist.fap`
- `NFC/saflip.fap`
- `Sub-GHz/subghz_bruteforcer.fap`
- `Sub-GHz/subghz_fap.fap`
- `Sub-GHz/subghz_playlist.fap`
- `Tools/bad_kb.fap`
- `Tools/nightstand.fap`

## Momentum app removal

At the user's request, all 25 Momentum-dependent FAPs listed above were backed
up byte-for-byte and removed from `/ext/apps`. The 13 Momentum-only internal
Settings/Assets FAPs were never restored after the official firmware update.
No Momentum-dependent FAP remains in the on-device application tree.

The current tree contains 226 FAPs. A complete on-device MD5 comparison against
the official-only host mirror passed with 226 expected, 226 observed, zero
missing, zero unexpected, and zero mismatches. `/ext/apps_data` was not removed
or modified, so retained application data is still available.

Restoring any removed Momentum app would require either compatible official
source/catalog builds or a separate decision to return to compatible custom
firmware.

## Dolphin mood repair

The pre-change `/int/.dolphin.state` was backed up. Official firmware's Desktop
Settings > Happy Mode was then enabled instead of resetting dolphin progress or
editing the state file. Passport verification showed `Mood: Happy` and retained
`Level: 3`.

## Audit evidence and backups

All recovery work is contained under:

```text
flipper-zero/work/app-compat-audit-20260809/
```

Key evidence files:

- `pre-restore-apps/` - 15 post-update FAP backup
- `pre-official-replacements/` - Momentum FAPs replaced by catalog builds
- `final-apps/` - historical mirror of the pre-removal 251-FAP tree
- `removed-momentum-apps/` - exact backup and manifest for the 25 removed FAPs
- `official-apps/` - current official-compatible 226-FAP mirror
- `on-device-hash-audit.json` - complete device hash comparison
- `official-on-device-hash-audit.json` - post-removal 226-FAP hash comparison
- `momentum-removal-audit.json` - removal scope and post-removal path audit
- `final-fap-audit.json` - manifest and API audit
- `final-official-import-audit.json` - official symbol/import audit
- `official-catalog-install.json` - 41 catalog replacements and hashes
- `defcon-official-install.json` - rebuilt DEFCON Defense installation evidence

Dolphin backup and screen evidence are contained under:

```text
flipper-zero/work/dolphin-mood-fix-20260809/
```

## Wi-Fi frequency coverage

The attached ESP32-S2 radio supports 2.4 GHz Wi-Fi only. DEFCON Defense reports
2.4 GHz coverage and does not claim live 5 GHz visibility. A future dual-band
radio/firmware can be supported by extending the channel model and UART input,
but the current hardware cannot observe 5 GHz Wi-Fi traffic.
