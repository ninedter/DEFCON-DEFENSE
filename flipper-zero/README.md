# DEFCON Defense for Flipper Zero

`DEFCON Defense` is a unified, defensive-only Flipper Zero application for the
AIO V1.4 ESP32-S2 Marauder board. It opens directly into a RECON-style monitor
and keeps every defensive workflow inside one application.

## Included workflows

- continuous passive 2.4 GHz AP, station, and management-frame observation;
- live AP, client, channel, RSSI, and alert summaries;
- new or unknown BSSID alerts;
- trusted-SSID impersonation and possible evil-twin detection;
- suspicious deauthentication and disassociation frame detection;
- channel-change and large RSSI-shift alerts;
- in-app allowlist add and remove actions;
- incident history and persistent evidence logging;
- emergency mode that stops the ESP Wi-Fi workflow and recommends a wired or
  separately trusted fallback connection.

The attached ESP32-S2 radio is 2.4 GHz-only. The UI reports 5 GHz as unavailable
instead of claiming coverage the hardware cannot provide.

## Controls

- **OK** opens the internal application menu.
- **LEFT/RIGHT** changes the RECON monitor page.
- **BACK** returns to the preceding in-app view; from the RECON dashboard it
  exits the application cleanly.

Evidence, incidents, settings, and the allowlist are stored under:

```text
/ext/apps_data/defcon_defense/
```

## Defensive command boundary

The FAP compiles only `defcon_defense.c` and `defcon_uart.c`. Its ESP32 command
surface is limited to:

```text
scanap
scansta
sniffdeauth
stopscan
stopscan -f
```

The app does not include RF jamming, attack transmission, deauthentication or
disassociation injection, spoofing, evil portals, beacon spam, BLE spam, Karma,
PMKID collection, SSID injection, or offensive automation scripts.

The original WiFi Marauder application remains a separate app on the Flipper;
this project uses the distinct app ID `defcon_defense` and does not overwrite it.

## Build

The current verified target is official firmware `1.4.3`, Flipper target 7,
firmware API 87.1. With the matching official uFBT SDK selected:

```sh
sh tests/test_defensive_contract.sh
ufbt
```

The generated application is:

```text
dist/defcon_defense.fap
```

## Project layout

```text
flipper-zero/
├── application.fam
├── defcon_defense.c
├── defcon_uart.c
├── defcon_uart.h
├── wifi_10px.png
├── tests/test_defensive_contract.sh
├── dist/defcon_defense.fap
├── docs/verification.md
└── releases/
```

The UART, OTG-power, and expansion integration pattern is derived from the
Flipper Zero WiFi Marauder companion project. See `LICENSE` for licensing.
