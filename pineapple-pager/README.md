# DEFCON Defense — WiFi Pineapple Pager

A **passive, fatigue-resistant** early-warning kit. It detects and warns; it
never transmits attacks against other people. Core idea: **warn loudly only on
a repeated same-offense**, stay quiet on ambient DEF CON noise.

## What's included

| Payload | Type | Warns you when… |
|---|---|---|
| `user/defcon/DEFCON-DEFENSE` | on-demand | runs a dedicated 480x222 full-screen Pager application with the designed general, threat-detail, and PCAP-evidence interfaces; it supplies live passive 2.4/5 GHz Recon, background trusted/watched-network correlation, bounded investigation capture, evidence verification, and later download through Virtual Pager |
| `user/defcon/RF-BUDDY` | on-demand | separate, standalone full-screen 2.4/5 GHz interference finder (also viewable at `http://172.16.52.1:1474`): a live channel overview, a 1-second lock-on meter with a buzzer tick, a Bluetooth LE browser (brand → type → device) with a walk-around TRACK meter, and a survey log, so you can walk an office and find where Wi-Fi and Bluetooth suffer and why (interference, congestion, overlap, Bluetooth density, weak coverage). Recon keeps running, locked to one channel at a time |
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
2. With the Pager on USB, run `./deploy.sh` (key-based SSH to `root@172.16.52.1`).
   `./deploy.sh` installs RF-BUDDY; `./deploy.sh --payload DEFCON-DEFENSE`
   installs DEFCON Defense; `./deploy.sh --payload all` installs both. Each
   payload is deployed on its own into `/root/payloads/user/defcon/<name>/` and
   never touches the other. Any previous copy is moved to
   `/mmc/root/payload-backups/<timestamp>/<name>`; a DEFCON Defense deploy also
   moves an old `user/general/DEFCON_DEFENSE` there so the menu shows one copy.
   Only the newest deploy backup of each payload is kept (set
   `PAGER_BACKUP_KEEP=n` to keep more); folders you create yourself in that
   directory are never touched.
   The script registers the `defcon` folder in the Payloads menu
   (`/etc/config/payloads`). Use `--dry-run` to preview. A firmware update may
   reset the menu list; re-run the deploy afterwards. To install over USB
   storage instead, copy the wanted folders from `library/user/defcon/` into
   `/mmc/root/payloads/user/defcon/` and add `list payloaddir 'user/defcon'` to
   `/etc/config/payloads`.
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
- **Unified RF monitoring:** open `DEFCON-DEFENSE` (Payloads → defcon). The custom application
  renders directly on the physical 480x222 display and mirrors the same canvas
  in Virtual Pager. The primary views are **general**, **Observed APs**,
  **My Watch List**, **threat detail**, and **evidence browser**. On the general screen,
  UP/DOWN moves the highlight, A opens the selected item, B exits, and
  LEFT/RIGHT opens evidence. **AP Watch List** opens the APs currently heard in
  passive Recon; UP/DOWN selects an AP and green A adds or removes it from
  monitoring. **Monitored Networks** opens the saved user watch list, including
  entries that are not currently visible; green A removes an entry and RIGHT
  returns to observed APs to add one. In threat detail, UP/DOWN selects the next/previous
  alert, A requests a bounded passive investigation capture, B returns to
  general, and RIGHT opens evidence. Red/B is consistently back or exit;
  green/A confirms or opens the next step. In evidence,
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

## Hunting office interference (RF-BUDDY)

RF-BUDDY is standalone and lives in its own **defcon** folder in the Payloads
menu (`./deploy.sh` registers it; see Install). Open `RF-BUDDY`. The overview
ranks every 2.4 GHz channel (UP/DOWN for 5 GHz) by interference score and names
the likely cause. Select the worst channel and press A to lock on: the score
updates every second and the buzzer tick speeds up as you get closer to the
problem. Press A to MARK SPOT where it peaks, then match the numbered marks in
`/root/loot/rf_buddy/<date-time>/marks.csv` to places in the office. Set
`OFFICE_SSID` in its `payload.sh` to also flag weak coverage; `TICK_FREQ_HZ` and
`TICK_VOLUME` (0-100) set the tick's pitch and loudness. The Pager's radio
cannot report busy time or noise floor, so RF-BUDDY scores channels from Wi-Fi
airtime, retries, AP crowding, and Bluetooth density; the Bluetooth scan is
passive.

Press UP/DOWN until the **BT** tab is highlighted to browse nearby Bluetooth LE
devices: A drills from BRANDS (Apple, Microsoft, …) to their TYPES (Find My,
Nearby, AirPods, …) to the DEVICES themselves, and B steps back. On a device, A
starts TRACK: a proximity meter (VERY CLOSE / CLOSE / NEAR / FAR) whose tick
speeds up as you walk toward it — handy for finding the earbud case or beacon
that sits on a busy desk. Details and button tables are in
`src/user/defcon/RF-BUDDY/README.md`.

Open `http://172.16.52.1:1474` in a browser for a live copy of the screen with
buttons. Like DEFCON Defense's screen server, it listens only on the Pager's USB
management address, never on Wi-Fi. While RF-BUDDY runs, the stock Pager menu and the stock Virtual Pager
(`:1471`) are paused; they come back when you press B. Recon keeps running,
locked to one channel at a time.

## Tuning

Each custom handler has a CONFIG block at the top of its `payload.sh`:
- `defcon_sentry`: `REPEAT_THRESHOLD`, `WINDOW_SECONDS`, `COOLDOWN_SECONDS`,
  `KEY_MODE`, `WATCH_MACS` (put **your** device MACs here for instant targeted
  warnings).
- `defcon_honeypot`: `COOLDOWN_SECONDS` (default `600`).
- `DEFCON-DEFENSE`: `MONITOR_INTERVAL`, `NEW_BSSID_THRESHOLD`,
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
- `/root/loot/rf_buddy/<date-time>/` — RF-BUDDY `samples.csv`, `marks.csv`, and `session.txt`.
- `/root/loot/defcon_defense/watched_aps.tsv` — APs selected with the Pager arrows.
- `/root/loot/defcon_defense/findings.tsv` — passive RF alerts and evidence.
- `/root/loot/defcon_defense/latest_recon.json` — latest raw Recon snapshot.
- `/root/loot/defcon_defense/pcap_index.tsv` — capture time, trigger, severity,
  SSID/BSSID, band/channel, signal, duration, size, SHA-256 state, status, and path.
- `/root/loot/pcap/` — firmware-native focused passive Recon captures.

The watch list can also be maintained as a user-owned, tab-separated file with
one `BSSID`, `SSID`, `channel`, and `band` entry per line and no header. The native **My Watch List**
screen continues to display entries even when they are absent from the current
Recon snapshot. Do not store passwords or PSKs in this file.

Open **PCAP Evidence** to browse saved captures by time, threat, network, size,
and status. Open a row for full details; use **Verify SHA-256** when a digest is
needed. Digesting is intentionally on demand so a large pre-existing PCAP does
not delay the general screen. To retrieve captures
later, open Virtual Pager, choose **Download Loot**, unzip the archive, and open
the `pcap/` folder.

The custom UI publishes a read-only PNG mirror on device port `1472` only while
the application is running. An idempotent bridge in the authenticated Virtual
Pager page displays that canvas and automatically falls back to the stock Pager
screen when the application exits. Version 4.19 starts the native renderer before
loading monitoring libraries so the designed General screen appears at the
beginning of a payload launch. It sends only changed frames using
change-driven long polling, reclaims the physical display only when the native
payload runner displaces it, routes Virtual Pager buttons directly to the app,
admits only one button until the next rendered frame, uses a low-churn five-second
long poll with bounded client and server timeouts, restores the application
immediately after page refresh, hides
the stock login/loading panels while the application owns the screen, supports
the same flow from the keyboard arrow/Enter/Escape keys,
reads the six physical controls directly from the Pager input device instead of
loading the Pager service with repeated input requests, lets the launch-confirm
gesture finish before accepting navigation, commits the first screen
before starting Recon/evidence workers, uses low-CPU uncompressed PNGs for the
Virtual Pager, starts from cached safe state before any live refresh, cleans up
UI workers on normal exit or disconnect, prevents duplicate UI instances, and
clips dynamic text to its assigned panels. On Pager 24.10.1 it also isolates the
renderer from the firmware launcher's process-group handoff, pauses the stock
framebuffer/input service while the custom application owns the hardware,
restores it on every exit path, maps the physical green button to confirm and
red to back/exit, and retains one distinct follow-up button until the current
frame is acknowledged so quick two-step navigation is not dropped. It also
gives every run a unique screen revision, forgets prior revisions after exit,
and bounds a dead screen request at 6.5 seconds, so repeated launches switch
back to the live DEFCON canvas without a manual browser reload. For day-long
sessions, it refreshes the physical input descriptor every ten minutes, limits
framebuffer ownership probes to the eight-second launch handoff, times out a
stalled Recon read, exposes degraded or stale monitoring state, and uses unique
atomic state files for concurrent background workers. Virtual screen responses
share immutable frame buffers rather than copying 320 KB per request. Version
4.19 also reuses the canvas and RGB565 conversion buffers, draws its ten fixed
status icons without loading a TrueType parser, classifies each Recon snapshot
in one pass, calculates all UI counters in one pass, imports pre-existing PCAPs
once per session with a linear index comparison, and installs the Virtual Pager
bridge as a small external-script tag. The stock page is backed up before the
bridge is first installed. Measured before/after results are recorded in
`docs/ui-v4/performance.md`. The complete normal, empty, detail, and stress-state
containment audit is in `docs/audits/2026-08-10-text-containment/README.md`.

The custom screen server binds only to the Pager's `172.16.52.1` USB-management
address. Screen and button requests require a random 128-bit token stored with
mode `0600` under the DEFCON Defense loot directory and exposed only through the
authenticated Virtual Pager page. The health check contains no screen data and
remains available for local liveness testing.

Version 4.18 and later reject Recon observations older than 45 seconds and require a
post-launch observation before alerting. Cached AP rows therefore cannot keep
an ended test threat active, replay its ringtone after restart, or start another
automatic PCAP after the transmitter is gone.

Automatic PCAP capture is deliberately bounded and conservative:

- only confirmed red/high-confidence alerts trigger it; optional-baseline
  `NEW_BSSID` review items do not;
- one capture can run at a time;
- matching event/BSSID captures cool down for five minutes;
- each automatic capture stops after 30 seconds;
- automatic capture stops before 256 MB of managed PCAP data or 64 MB of free
  device storage is crossed; and
- no capture is automatically deleted. The evidence browser requires explicit
  confirmation before removing a selected file, and the main UI's **Clear
  Session** option requires the deliberate **RIGHT to arm, then A within three
  seconds** sequence before removing the current alert history and all managed
  PCAP files. Repeated or stray A presses cannot activate it.

`events.log`, `honeypot.csv`, and `findings.tsv` can grow over a multi-day
event. **Clear Session** resets the DEFCON Defense alert history and managed
PCAP evidence while preserving watched APs, the reviewed baseline, and trusted
rules. The separate honeypot record remains outside that UI reset.

## This is not a substitute for opsec

Use a VPN, keep device MAC randomization on, turn radios off when idle, and
don't auto-join open networks. This kit is your **radar**, not your armor.

## Legal / authorized use

Scope is limited to passively monitoring RF you can already hear, your own
device's inbound traffic, and your own decoy AP. Do **not** impersonate real
SSIDs. See the repository's Legal section — Hak5 gear is for authorized auditing
and security analysis only; you are solely responsible for compliance.
