# DEFCON Defense for Flipper Zero v1.0

## Delivered application

- Project root: `DEFCON-DEFENSE/flipper-zero`
- App ID: `defcon_defense`
- Display name: `DEFCON Defense`
- Install path: `/ext/apps/GPIO/defcon_defense.fap`
- Build target: Flipper target 7
- Firmware API: 87.1
- Target device firmware: Official `1.4.3`
- Target companion board: AIO V1.4 / ESP32-S2

The ESP32-S2 radio supports 2.4 GHz but not 5 GHz. The application reports 5 GHz as unavailable instead of claiming unsupported coverage.

## Unified in-app flow

The app opens directly into a RECON-style monitor. Press **OK** to open the internal menu and **LEFT/RIGHT** to move between monitor pages.

The internal menu includes:

- RECON live summary;
- AP and channel activity;
- client activity;
- incident view;
- allowlist add/remove;
- evidence viewer and logging toggle;
- emergency mode;
- device/capability status.

Emergency mode stops the current observation cycle and issues the Marauder radio-shutdown command. It does not transmit disruptive frames. The UI recommends moving protected devices to a wired or separately trusted connection.

## Defensive boundary

Only `defcon_defense.c` and `defcon_uart.c` are compiled into the FAP. The binary contains these radio-control commands:

- `scanap`
- `scansta`
- `sniffdeauth`
- `stopscan`
- `stopscan -f`

The built binary was checked and contains no attack, deauthentication injection, disassociation injection, spoofing, evil-portal, beacon-spam, BLE-spam, Karma, PMKID, SSID-injection, or target-selection command strings.

## Verification completed

- Official uFBT SDK `1.4.3` build: PASS
- Official import resolution for target 7 / API 87.1: PASS
- Defensive command-contract test: PASS
- Source formatting check for the app files: PASS
- Device installation at `/ext/apps/GPIO/defcon_defense.fap`: PASS
- On-device hash verification after installation: PASS
- Launch from **Apps > GPIO > DEFCON Defense** on official firmware: PASS
- RECON dashboard rendered after launch: PASS
- WiFi Marauder remained installed separately and launched from the GPIO menu: PASS

The official build replaces the disabled `strtok_r` dependency with a local
line parser. This keeps allowlist loading behavior while using only symbols
exported by official firmware `1.4.3`.

## Consolidated project verification

The source, defensive contract test, documentation, icon, license, FAP, debug
artifact, audit evidence, official SDK workspace, and release archives are all
contained under the `flipper-zero` project folder. The official API 87.1 build
and import check were run from that location.

## Checksums

- `dist/defcon_defense.fap`: `4e49490d75f1c9a3f9ceb4cb721c56b5e70809230644848c49cd7416fba213f0`
- `releases/DEFCON-Defense-Flipper-v1.0-source.tar.gz`: `919572a968faca350e6b210dee358ec6f2fe2f115a66515b8c098cbddfdabced`
- `releases/DEFCON-Defense-Flipper-v1.0-source-original.tar.gz`: `08647a981ed21fe783858867df38f295dfeab6f11a742fa19936b618acd1844e`
