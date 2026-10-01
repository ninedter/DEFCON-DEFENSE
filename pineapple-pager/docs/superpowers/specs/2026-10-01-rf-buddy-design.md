# RF-BUDDY — Office 2.4/5 GHz Interference Finder for the Pager

**Date:** 2026-10-01 (revised 2026-10-02 after on-device checks; v1.1 standalone redesign)
**Status:** Design — approved
**Author:** Henry Hu (with Claude Code)

## Goal

Give the WiFi Pineapple Pager a **real-time, walk-around interference meter** so the
operator can find *where* in the office 2.4 GHz and 5 GHz interference is worst and
*what kind* it is. Reported symptoms are mixed: slow/laggy Wi-Fi in some areas, random
drops, one band worse than the other, and **static in AirPods** (Bluetooth shares
2.4 GHz, so 2.4 GHz congestion/interference and BLE density are first-class signals).

The tool is a Geiger counter, not a floor-plan surveyor: **no predefined zones**. The
operator watches readings fluctuate while walking and homes in on the worst spot. A
timestamped log plus operator-dropped **marks** support later review.

## Posture

- **Passive only.** RF-BUDDY listens; it never transmits frames, deauths, or probes.
- **Standalone payload**, independent of DEFCON Defense: own launcher, binary, lock, viewer page (port 1474), and logs. It shares no files, ports, or loot with it.

## Payload organisation

RF-BUDDY gets its own menu category; DEFCON Defense is not moved and stays where it is on main:

```
/root/payloads/user/defcon/RF-BUDDY/     (this payload)
/root/payloads/user/general/DEFCON_DEFENSE/   (unchanged, not part of this work)
```

- The repo mirrors this: `src/user/defcon/RF-BUDDY/` and `src/user/general/DEFCON_DEFENSE/`.
- **Independence rules.** RF-BUDDY files live only in `src/user/defcon/RF-BUDDY/`; runtime
  state only in `/tmp/rf_buddy*` and `/root/loot/rf_buddy/`. It never touches `/pineapple/ui/*`,
  any other payload directory, DEFCON loot, or ports 1472/1473, and never `killall`/`pkill`s
  shared tool names. Its remote viewer is its own page on port 1474.
- The only shared-system actions, all reverted on every exit path: freeze/resume the stock
  `pineapple` process; `_pineap EXAMINE CHANNEL/CANCEL`; an exclusive grab of
  `/dev/input/event0` (released when the fd closes); buzzer pulses with the saved and restored
  `frequency` and `volume`.
- No hak5 API commands (`LOG`, `ERROR_DIALOG`, `RINGTONE`, `VIBRATE`, `PINEAPPLE_*`, ...) run
  between freezing and resuming `pineapple`, because they stop working while it is frozen.
- `payload.sh` exports a default `PATH` (`/usr/sbin:/usr/bin:/sbin:/bin`) when the runner
  starts it without one; the UI binary also sets one for itself.
- **Hyphens, not underscores**, in the payload folder name; shell variables (`RF_BUDDY_*`)
  keep underscores.
- The Pager menu only shows categories listed in `/etc/config/payloads`
  (`list payloaddir 'user/...'` in the anonymous `directories` section, addressed as `payloads.@directories[0]`).
  Installation therefore adds `user/defcon` with
  `uci add_list 'payloads.@directories[0].payloaddir=user/defcon'` and `uci commit payloads`.
  A firmware update may reset this list; re-running the deploy script restores it.

## Verified device facts (Pager, firmware hak5ver 107, kernel 6.6.86)

- `wlan1mon` is the monitor interface on `phy1` (bands 2.4 / 5 / 6 GHz).
- **`wlan1mon` reports no survey counters**: `iw dev wlan1mon survey dump` returns zeros
  for active/busy time on every channel, and no noise line, even while locked to a
  channel. Busy % and noise floor are therefore **not available**.
- `wlan0mon`/`wlan0cli` (`phy0`, 2.4 GHz only) do report busy time, but only for the
  channel the Pager's Wi-Fi client is connected to; they are not used.
- `_pineap EXAMINE CHANNEL <channel> <seconds>` locks Recon to a channel (takes effect
  immediately, works for 2.4 and 5 GHz numbers); `_pineap EXAMINE CANCEL` resumes
  normal hopping. Recon keeps running throughout.
- Passive capture on `wlan1mon` delivers radiotap frames with TSFT, legacy rate,
  channel, dBm signal, and further fields (bit 22 present); the 802.11 retry flag is
  readable. On channel 6 the office AP `NINEDTER` was heard at −67 dBm.
- `hcitool`, `hciconfig`, and `hci0` exist; `_pineap` is in `/usr/bin`. The buzzer is
  `/sys/class/leds/buzzer` (`frequency`, `volume`, `brightness`).

## Payload layout

`src/user/defcon/RF-BUDDY/` (installed to `/root/payloads/user/defcon/RF-BUDDY/`):

```
RF-BUDDY/
  README.md
  payload.sh         CONFIG block, PATH export, lock file, start UI, stock-UI freeze/resume,
                     freeze watchdog, cleanup trap (EXAMINE CANCEL, stop hcitool, buzzer reset)
  ui/                Go program, static MIPS32 soft-float
    display.go       framebuffer, exclusive input grab, own viewer page on :1474
    channels.go      band/channel model
    score.go         metrics, score, LIKELY rules
    recon.go         Recon JSON parser + AP inventory
    frames.go        radiotap/802.11 parsing incl. HT/VHT rate, dwell statistics
    bluetooth.go     BLE device counting
    radio.go         EXAMINE-based tuning, capture, Recon AP refresh
    logger.go        session CSVs
    probe.go         launch-time capability probe
    engine.go        sweep / lock-on scheduling, smoothing, peak, trend
    ui.go            screens and buttons
    preview.go       preview PNGs
    main.go          wiring
```

`build.sh`/`package.sh` build and ship it (binary `rf-buddy-ui`, `ui/` source removed,
mode 755). `deploy.sh` installs the built tree on the Pager over SSH (see Deployment).

The Go binary does sampling, scoring, rendering, logging, the viewer page, and the buzzer
tick itself (a 1 Hz meter cannot afford shell + temp-file IPC). Its display/input plumbing
was copied from DEFCON-DEFENSE's UI and shares no code or files with it.

## Configuration (`payload.sh` CONFIG block)

| Name | Default | Meaning |
|---|---|---|
| `OFFICE_SSID` | `""` | Office network SSID. Enables `WEAK COVERAGE`. Blank = rule skipped. |
| `DWELL_MS` | `250` | Overview dwell per channel. |
| `RETRY_HIGH_PCT` | `25` | Retry % at/above which `INTERFERENCE` is considered. |
| `AIRTIME_HIGH_PCT` | `50` | Wi-Fi airtime % at/above which a channel is `CONGESTION` (and not interference). |
| `OVERLAP_MIN_DBM` | `-70` | Min neighbour AP signal for `CHANNEL OVERLAP`. |
| `BT_DENSE_COUNT` | `30` | BLE devices for `BT DENSE`. |
| `WEAK_SIGNAL_DBM` | `-70` | Office AP signal below this → `WEAK COVERAGE`. |
| `LOG_MAX_MB` | `20` | Per-session log cap. |
| `MIN_FREE_MB` | `64` | Logging pauses below this free space. |
| `TICK_FREQ_HZ` | `2000` | Buzzer pitch of the lock-on tick, Hz. |
| `TICK_VOLUME` | `128` | Buzzer loudness of the lock-on tick, 0-255. |

## Measurement

### Tuning

`_pineap EXAMINE CHANNEL <n> 300` per dwell (re-issued on every tune; the 300 s lock
expires on its own if RF-BUDDY dies). `_pineap EXAMINE CANCEL` on exit (Go defer and the
`payload.sh` cleanup trap). In overview, a channel is skipped after 3 consecutive tune failures (a successful tune resets the count); skips are cleared every 20th sweep cycle and whenever every channel is skipped, so transient failures recover. Lock mode never skips.

### Capability probe

At launch: lock channel 6; capture for 300 ms; wait 500 ms and read
`iw dev wlan1mon info` — if the channel is not 6, fail with a clear error (something else
is moving the radio). Capture failure is **fatal** (every metric depends on it). Bluetooth
availability = `hcitool` on PATH and `/sys/class/bluetooth/hci0` present; if absent, BT
shows `N/A` and `BT DENSE` is skipped. If the capture socket cannot be opened, the open error (for example "operation not permitted") is carried into the probe and shown on the fatal screen, and the radio is released immediately after a fatal probe.

### Frames (`frames.go`)

An `AF_PACKET` receive-only socket on `wlan1mon`. Radiotap is walked field by field
(bits 0–21 with correct alignment) to read: flags (FCS present / bad FCS), legacy rate,
dBm signal, **HT MCS** (bit 19), and **VHT MCS/NSS/bandwidth** (bit 21). 802.11 header:
retry bit, transmitter address, beacon SSID and DS-parameter channel. Frames with bad FCS
are ignored.

Per dwell:

- **Frames/s.**
- **Retry %** = retries ÷ frames (needs ≥ 10 frames, else `N/A`).
- **Airtime %** = Σ(frame bits ÷ PHY rate + 20 µs) ÷ dwell, clamped to 100. PHY rate comes
  from the legacy rate, HT MCS table, or VHT MCS table (× streams × bandwidth × short-GI);
  unknown rates (e.g. HE) assume 24 Mb/s. This estimates how much of the channel decodable
  Wi-Fi occupies; monitor capture misses some frames, so it is a lower bound.
- **Strongest transmitters** (top 3 by signal; SSID from beacons or the inventory).
- Beacons update the AP inventory.

### AP inventory

Seeded from `_pineap RECON APS format=json` at launch and refreshed from it every 30 s
(Recon keeps running), plus beacons heard while sweeping. Used for co-channel AP count,
2.4 GHz overlap (different channel within ±4), the office SSID's best signal per band, and
the list of 5 GHz channels in use (default 36–48, 149–165 when Recon has none).

### Bluetooth

Background `hcitool -i hci0 lescan --passive --duplicates` (passive: no scan requests are
sent; restarted if it exits); unique addresses in a rolling 30 s window. The scan is stopped
with SIGINT, followed by a scan-disable (`hcitool -i hci0 cmd 0x08 0x000c 00 00`), on exit and
before each restart.

### Cadence

- **Overview:** dwell `DWELL_MS` on each channel of the selected band (2.4 GHz 1–11;
  5 GHz in-use channels); the other band is swept every third cycle.
- **Lock-on:** parked on one channel, one sample per second.

### Score (0–100)

| Metric | Weight | 0 at | 100 at |
|---|---|---|---|
| Wi-Fi airtime % | 45 | 0 % | 80 % |
| Retry % | 35 | 0 % | 50 % |
| AP crowding (co-channel + overlapping APs) | 20 | 0 | 12 |

Missing metrics (retry with < 10 frames) drop out and the remaining weights renormalise.
The displayed score is an EMA with ≈ 3 s time constant; peak tracks the raw score.

### LIKELY cause (first match wins)

1. `INTERFERENCE` — retry % ≥ `RETRY_HIGH_PCT` while airtime % < `AIRTIME_HIGH_PCT`
   (frames are failing but the channel is not crowded: typical of non-Wi-Fi RF such as
   microwaves, wireless cameras, or heavy Bluetooth).
2. `CONGESTION` — airtime % ≥ `AIRTIME_HIGH_PCT`.
3. `CHANNEL OVERLAP` — 2.4 GHz only: an AP louder than `OVERLAP_MIN_DBM` on a different
   channel within ±4.
4. `BT DENSE` — 2.4 GHz only: BLE count ≥ `BT_DENSE_COUNT`.
5. `WEAK COVERAGE` — `OFFICE_SSID` set and its best signal on this band is below
   `WEAK_SIGNAL_DBM` (or it is not heard on this band).
6. `CLEAN`.

Rules whose inputs are `N/A` are skipped.

## UI

480×222, DEFCON-DEFENSE visual language (black background, yellow headings, cyan
dividers, green/amber/red status). Rendered to the physical display and served live, with on-page buttons, at
`http://172.16.52.1:1474` (RF-BUDDY's own viewer; the stock Virtual Pager on `:1471` is not used). **Footers place B on the left and A on the right**, matching the physical
buttons (red B left, green A right). Score colours: green `< 40`, amber `40–69`,
red `≥ 70`.

### Probe screen

`FRAME CAPTURE: OK`, `CHANNEL LOCK: OK`, `BLUETOOTH: OK/N/A`, `RECON STAYS ON; LOCKED
TO ONE CHANNEL AT A TIME`. Advances to Overview after 2 s.

### Overview

- Header: `RF-BUDDY`, band selector (`2.4 GHZ` / `5 GHZ`), `BT <n>`, clock (`LOG PAUSED`
  in red replaces the clock when logging is paused).
- Left: one bar per channel, height = airtime %, colour = score; selected channel
  outlined; `WORST: CH x  BEST: CH y`. Skipped channels show a grey dash. Narrow slots
  (many 5 GHz channels) label only the selected channel.
- Right panel: channel + MHz, score + level, `AIRTIME`, `RETRY`, `APS n (+m OVERLAP)`,
  `FRAMES/S`, `LIKELY: <cause>`.
- Footer: `B EXIT` · `LEFT/RIGHT CH` · `UP/DN BAND` · `A LOCK ON`.

### Lock-on

- Header: `LOCKED: CH n - <band>`, `AUDIO ON/OFF`, clock.
- Left box: large smoothed score, level, trend (`^ RISING` / `v FALLING` / `- STEADY`,
  newer vs older half of the last 10 s), `PEAK <raw max>` and its time.
- Right: `AIR`, `RETRY`, `FR/S`; 60-second rolling score graph; top 2 transmitters
  (SSID or BSSID, dBm); `BT/BLE NEARBY <n> DEV`.
- Tick: interval 2 s at score 20 → 0.3 s at 100; off below 20; toggled with UP. The UI
  binary pulses the buzzer itself at `TICK_FREQ_HZ` / `TICK_VOLUME` (`--tick-freq-hz`,
  `--tick-volume`), saving and restoring the buzzer's `frequency` and `volume`; a backstop
  in `payload.sh` and the watchdog silence it if the UI dies. No ringtone or vibrate API is used.
- Footer: `B BACK` · `LEFT/RIGHT CH` · `UP AUDIO` · `A MARK SPOT`.
- `MARK SPOT` appends a numbered mark to `marks.csv` and toasts
  `MARK 3 @ 12:42 - SCORE 91` (or `MARK NOT SAVED: LOG PAUSED`).

### Fatal screen

`CANNOT START RF-BUDDY` plus the wrapped reason; `B EXIT`.

All dynamic text is clipped to its panel (same rules as
`docs/audits/2026-08-10-text-containment/README.md`).

## Logging

`/root/loot/rf_buddy/<YYYYMMDD-HHMMSS>/`:

- `samples.csv` — `epoch,mode,band,channel,airtime_pct,retry_pct,frames_per_s,aps,overlap_aps,bt_count,score,likely`
  (`N/A` fields empty; `score` is the **raw** score so spikes are kept). One row per
  channel per sweep in Overview, one per second in Lock-on.
- `marks.csv` — `mark,epoch,band,channel,score,likely` (`score` = displayed score).
- `session.txt` — probe results and effective CONFIG values.

Writes stop at `LOG_MAX_MB` and pause while free space < `MIN_FREE_MB`. Retrieval:
Virtual Pager → Download Loot.

## Lifecycle and error handling

- **Single instance:** lock directory `/tmp/rf_buddy.lock` with the owner PID; a second
  launch shows "RF-BUDDY is already running." and exits without touching anything.
- **Stock UI freeze/resume:** once the UI has drawn its first frame (ready file), `payload.sh`
  sends SIGSTOP to the stock `pineapple` process so it stops drawing over the framebuffer and
  reading buttons; the UI grabs `/dev/input/event0` exclusively. While frozen, the stock menu
  and the stock Virtual Pager (`:1471`) are unavailable. Cleanup sends SIGCONT, and restarts
  `/etc/init.d/pineapplepager` if `pineapple` is gone. B exits and resumes everything.
- **Watchdog:** right after the freeze, a detached watchdog process waits for `payload.sh` to
  die. If it is SIGKILLed, the watchdog stops the UI, resumes the stock UI, silences the
  buzzer, runs `_pineap EXAMINE CANCEL`, and releases the lock. If the UI itself hangs while
  `payload.sh` is alive, nothing resumes the Pager; the operator holds the power button.
- **Cleanup** (`trap` on EXIT/INT/TERM/HUP and after the binary returns or crashes):
  stop the UI (TERM, KILL after 3 s), resume the stock UI, stop the watchdog, silence the
  buzzer, `killall -INT hcitool` plus an LE scan-disable, `_pineap EXAMINE CANCEL`, release
  the lock. Idempotent.
- Overview tune failure → channel skipped after 3 consecutive failures (cleared every 20 cycles or when all are skipped); capture or channel-lock failure at probe → fatal screen.

## Deployment (`deploy.sh`)

Run from the Mac with the Pager on USB (`root@172.16.52.1`, key-based SSH). It installs
**RF-BUDDY only**; no other payload is sent or touched.

1. `./build.sh` (fresh `library/`).
2. Stream `library/user/defcon/RF-BUDDY` into a staging folder under
   `/mmc/root/payloads/user/defcon/`.
3. Move any previous `RF-BUDDY` to `/mmc/root/payload-backups/<timestamp>/RF-BUDDY` instead of
   removing it, then swap the new one in (`rf-buddy-ui` mode 755).
4. Register the category if missing: `uci add_list 'payloads.@directories[0].payloaddir=user/defcon'`
   and `uci commit payloads`.
5. Print what changed. `--dry-run` prints the commands without running them.

The Pager-side steps change device state, so the operator confirms before running it.

## Testing

- **Go unit tests:** score weights/renormalisation; each LIKELY rule and order; Recon
  parsing (array/object forms, string numbers); inventory queries; radiotap walking
  (alignment, extended present words, FCS, HT and VHT rates) and airtime; dwell stats;
  BLE window; EXAMINE command lines and `iw info` parsing; engine sweep/skip/other-band/
  lock/peak/trend/inventory refresh with a fake radio; logger format/cap/pause; button
  state machine; tick mapping; render containment of stress states.
- **Preview renders:** probe, overview 2.4/5 GHz, lock-on, no-Bluetooth, fatal, stress.
- **Shell tests:** `payload.sh` lock/refusal/cleanup, PATH export, stock-UI freeze/resume,
  watchdog, and a full run with a fake UI; `deploy.sh --dry-run` command list with stubbed
  `ssh` (RF-BUDDY only); build/package include RF-BUDDY under `user/defcon`.
- **On-device verification:** deploy, confirm the `defcon` category appears with RF-BUDDY, run RF-BUDDY near a running microwave and confirm `INTERFERENCE`/high retry on
  nearby 2.4 GHz channels, MARK, exit with B, confirm the stock menu and Virtual Pager are back, Recon hopping resumed, and logs exist.

## Out of scope

- Floor-plan heat maps, zone tagging, or position estimation.
- True spectrum analysis / busy % / noise floor (not available on this radio).
- Changing AP configuration or transmitting anything.
- Moving or refactoring DEFCON Defense (its relocation is that payload's own future work).
