# DEFCON Defense — WiFi Pineapple Pager

A **passive, fatigue-resistant** early-warning kit. It detects and warns; it
never transmits attacks against other people. Core idea: **warn loudly only on
a repeated same-offense**, stay quiet on ambient DEF CON noise.

## What's included

| Payload | Type | Warns you when… |
|---|---|---|
| `user/general/DEFCON_DEFENSE` | on-demand | runs a dedicated 480x222 full-screen Pager application with the designed general, threat-detail, and PCAP-evidence interfaces; it supplies live passive 2.4/5 GHz Recon, background trusted/watched-network correlation, bounded investigation capture, evidence verification, and later download through Virtual Pager |
| `alerts/deauth_flood_detected/defcon_sentry` | auto (custom) | the **same** attacker sustains a deauth/disassoc flood (3 hits/2 min, 5 min cooldown; watched MACs escalate instantly), then immediately starts a bounded passive PCAP when storage and concurrency guards allow |
| `alerts/pineapple_client_connected/defcon_honeypot` | auto (custom) | a client joins **your decoy AP** (first sighting per client, dedup reconnects; flags randomized/private MACs — most modern phones use these, so it's expected, not alarming) |
| `user/general/PORT_ALERT` | on-demand | someone port-scans the Pager (auto-hardens firewall 60s) |
| `user/general/ICMP_ALERT` | on-demand | someone pings/traceroutes the Pager (blocks ICMP/UDP 60s) |
| `user/reconnaissance/find_hackers` | on-demand | evil-twin / SSID-spoofing + BT/Flipper activity |
| `user/reconnaissance/alien_ap` | on-demand | an AP beacons a bogus country code (rogue-AP tell) |
| `user/reconnaissance/SignalFence` | on-demand (optional) | a device gets close and lingers |

**Deliberately excluded** (offensive, aimed at other people): deauth storms,
PMKID attacks, handshake capture/crack, captive portals, PineAP karma/rogue-AP.

## Install (offline, before you touch con WiFi)

1. Build the tree on your computer:
   ```bash
   cd pineapple-pager && ./build.sh
   ```
   This writes `pineapple-pager/library/`.
   The build uses Go to cross-compile the custom UI as a static MIPS32
   soft-float binary for the Pager; all Go dependencies are vendored.
   For a Pager-ready archive with macOS metadata stripped, run `./package.sh`;
   it writes the archive and checksum manifest under `pineapple-pager/dist/`.
2. Copy `pineapple-pager/library/*` into the Pager's `/mmc/root/payloads/`
   over USB (merge with existing payloads).
3. **Arm the auto-hooks:** make sure these directories have **no** `DISABLED.`
   prefix on the device (or enable them in the on-device **Alerts** menu):
   - `alerts/deauth_flood_detected/defcon_sentry`
   - `alerts/pineapple_client_connected/defcon_honeypot`
4. **Start passive monitoring:** enable PineAP recon/scan (listening) so deauth
   events are heard.
5. **For the honeypot:** start an **open** AP with a neutral SSID that does
   **not** impersonate any real network.

## Which to run when (cheat sheet)

- **Always-on (no action needed once armed):** `defcon_sentry`, `defcon_honeypot`
  — they fire from the engine while you do anything else.
- **Unified RF monitoring:** open `DEFCON_DEFENSE`. The custom application
  renders directly on the physical 480x222 display and mirrors the same canvas
  in Virtual Pager. The three primary views are the designed **general**,
  **threat detail**, and **evidence browser** screens. On the general screen,
  UP/DOWN moves the highlight, A opens the selected item, B exits, and
  LEFT/RIGHT opens evidence. In threat detail, UP/DOWN selects the next/previous
  alert, A requests a bounded passive investigation capture, B toggles alert
  audio, LEFT returns to general, and RIGHT opens evidence. In evidence,
  UP/DOWN selects a PCAP, LEFT/RIGHT changes page, A opens metadata and on-demand
  SHA-256 verification, and B returns to general. Passive trusted/watched-
  network correlation continues in the background. A confirmed red alert
  begins a 30-second passive PCAP immediately when
  no capture is active, the same threat is outside its five-minute capture
  cooldown, and the storage safety reserve is healthy. The alert and detail
  screens show `PCAP CAPTURING`, `EVIDENCE SAVED`, or the reason capture was
  skipped. This keeps ordinary RF traffic separate from actionable indicators.
  A baseline is optional: selected and trusted-network mismatches work without one. When a
  reviewed baseline is present, persistent strong new BSSIDs are also detected.
- **Walking the floor / feeling watched:** launch `find_hackers`, then `alien_ap`
  for a rogue-AP sweep. Add `SignalFence` if you want a proximity tripwire.
- **On a wired/again-connected network you control:** run `PORT_ALERT` /
  `ICMP_ALERT` to catch someone scanning the Pager itself.

## Tuning

Each custom handler has a CONFIG block at the top of its `payload.sh`:
- `defcon_sentry`: `REPEAT_THRESHOLD`, `WINDOW_SECONDS`, `COOLDOWN_SECONDS`,
  `KEY_MODE`, `WATCH_MACS` (put **your** device MACs here for instant targeted
  warnings).
- `defcon_honeypot`: `COOLDOWN_SECONDS` (default `600`).
- `DEFCON_DEFENSE`: `MONITOR_INTERVAL`, `NEW_BSSID_THRESHOLD`,
  `OBSERVATION_WINDOW`, `ALERT_COOLDOWN`, and `MIN_NEW_BSSID_SIGNAL`. Authorized
  SSID/BSSID/channel mappings live in its non-secret `trusted_aps.conf` file.

Stock detectors: `find_hackers` has `MIN_SPOOFING_COUNT`; `PORT_ALERT` has a SYN
threshold — see each payload's own comments/README.

## Loot / logs (on device)

- `/root/loot/defcon_sentry/events.log` — every deauth event (even when silent).
- `/root/loot/defcon_sentry/deauth_state.csv` — per-offender counters.
- `/root/loot/defcon_sentry/honeypot.csv` — every decoy-AP connect.
- `/root/loot/defcon_sentry/honeypot_state.csv` — per-client dedup state.
- `/root/loot/defcon_defense/baseline_bssids.txt` — operator-approved baseline.
- `/root/loot/defcon_defense/watched_aps.tsv` — APs selected with the Pager arrows.
- `/root/loot/defcon_defense/findings.tsv` — passive RF alerts and evidence.
- `/root/loot/defcon_defense/latest_recon.json` — latest raw Recon snapshot.
- `/root/loot/defcon_defense/pcap_index.tsv` — capture time, trigger, severity,
  SSID/BSSID, band/channel, signal, duration, size, SHA-256 state, status, and path.
- `/root/loot/pcap/` — firmware-native focused passive Recon captures.

Open **PCAP Evidence** to browse saved captures by time, threat, network, size,
and status. Open a row for full details; use **Verify SHA-256** when a digest is
needed. Digesting is intentionally on demand so a large pre-existing PCAP does
not delay the general screen. To retrieve captures
later, open Virtual Pager, choose **Download Loot**, unzip the archive, and open
the `pcap/` folder.

The custom UI publishes a read-only PNG mirror on device port `1472` only while
the application is running. An idempotent bridge in the authenticated Virtual
Pager page displays that canvas and automatically falls back to the stock Pager
screen when the application exits. The stock page is backed up before the
bridge is first installed.

Automatic PCAP capture is deliberately bounded and conservative:

- only confirmed red/high-confidence alerts trigger it; optional-baseline
  `NEW_BSSID` review items do not;
- one capture can run at a time;
- matching event/BSSID captures cool down for five minutes;
- each automatic capture stops after 30 seconds;
- automatic capture stops before 256 MB of managed PCAP data or 64 MB of free
  device storage is crossed; and
- no capture is automatically deleted. The evidence browser requires explicit
  confirmation before removing a selected file.

`events.log`, `honeypot.csv`, and `findings.tsv` are append-only and grow over a
multi-day event — clear them periodically if device storage is tight.

## This is not a substitute for opsec

Use a VPN, keep device MAC randomization on, turn radios off when idle, and
don't auto-join open networks. This kit is your **radar**, not your armor.

## Legal / authorized use

Scope is limited to passively monitoring RF you can already hear, your own
device's inbound traffic, and your own decoy AP. Do **not** impersonate real
SSIDs. See the repository's Legal section — Hak5 gear is for authorized auditing
and security analysis only; you are solely responsible for compliance.
