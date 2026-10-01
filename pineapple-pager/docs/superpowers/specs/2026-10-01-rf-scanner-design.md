# RF Scanner — Office 2.4/5 GHz Interference Finder for the Pager

**Date:** 2026-10-01
**Status:** Design — pending user review
**Author:** Henry Hu (with Claude Code)

## Goal

Give the WiFi Pineapple Pager a **real-time, walk-around interference meter** so the
operator can find *where* in the office 2.4 GHz and 5 GHz interference is worst and
*what kind* of interference it is. Reported symptoms are mixed: slow/laggy Wi-Fi in some
areas, random drops, one band worse than the other, and **static in AirPods** (Bluetooth
shares 2.4 GHz, so 2.4 GHz airtime/noise and BLE density are first-class signals).

The tool is a Geiger counter, not a floor-plan surveyor: there are **no predefined
zones**. The operator watches readings fluctuate while walking and homes in on the
worst spot. A timestamped log plus operator-dropped **marks** support later review.

## Posture

- **Passive only.** The scanner listens; it never transmits frames, deauths, or probes.
- **Separate payload** from `DEFCON_DEFENSE`. While it runs it owns `wlan1mon`, so Recon
  (and DEFCON Defense's Recon-based background monitoring) is paused. The launch screen
  says so, and Recon is restored on every exit path.

## Honest capability limits

The Pager's radios are 802.11 chipsets, not spectrum analyzers. They cannot *identify*
non-Wi-Fi emitters (microwave, wireless camera, cordless phone, Bluetooth). Those appear
indirectly as **high channel busy time and a raised noise floor with little decodable
Wi-Fi traffic**, which the scanner reports as `NON-WIFI NOISE`. Busy % and noise floor
depend on the driver exposing survey counters (`iw dev wlan1mon survey dump`); this is
**unverified on the device** and is the first on-device check. When unsupported, those
metrics show `N/A` rather than an estimate.

## Payload layout

`src/user/general/RF_SCANNER/` (installed to `library/user/general/RF_SCANNER/`):

```
RF_SCANNER/
  README.md
  payload.sh         thin launcher: CONFIG block, prerequisite checks, lock file,
                     save/restore Recon bands, start UI binary, cleanup trap
  ui/
    build.sh         static MIPS32 soft-float build (same flags as DEFCON_DEFENSE/ui)
    go.mod, vendor/  vendored golang.org/x/image (copied from DEFCON_DEFENSE/ui)
    main.go          app loop, screens, button handling, rendering, preview mode
    display.go       framebuffer writer, input-device reader, Virtual Pager PNG mirror
                     (copied from DEFCON_DEFENSE/ui/main.go, not shared)
    probe.go         launch-time capability probe
    sampler.go       channel tuning, survey-counter deltas, frame capture/parsing
    bluetooth.go     BLE device counting
    score.go         0-100 score + LIKELY cause classification
    logger.go        session CSV logging with size cap and storage reserve
    *_test.go        unit tests + fixtures
```

`build.sh` and `package.sh` at the `pineapple-pager/` root are extended to build and ship
`RF_SCANNER` exactly as they do `DEFCON_DEFENSE` (binary `rf-scanner-ui`, `ui/` source
removed from the output tree, mode 755).

**Design choice:** unlike DEFCON Defense (shell does work, Go only renders), the Go binary
here does sampling, scoring, rendering, and logging itself. A 1 Hz live meter cannot
afford shell + temp-file IPC. The display/input/mirror plumbing (~300 lines) is
**copied**, not refactored into a shared package, so the just-stabilized DEFCON Defense
UI is untouched. Consolidation can happen later.

## Configuration (`payload.sh` CONFIG block)

Passed to the UI binary as flags/env.

| Name | Default | Meaning |
|---|---|---|
| `OFFICE_SSID` | `""` | Office network SSID. Enables `WEAK COVERAGE`. Blank = rule skipped. |
| `DWELL_MS` | `250` | Overview dwell per channel. |
| `NOISE_HIGH_DBM` | `-85` | Noise above this → `NON-WIFI NOISE`. |
| `BUSY_HIGH_PCT` | `50` | Busy threshold for `NON-WIFI NOISE` / `CONGESTION`. |
| `CONGESTION_APS` | `8` | AP count for `CONGESTION`. |
| `OVERLAP_MIN_DBM` | `-70` | Min neighbour AP signal for `CHANNEL OVERLAP`. |
| `BT_DENSE_COUNT` | `30` | BLE devices for `BT DENSE`. |
| `WEAK_SIGNAL_DBM` | `-70` | Office AP signal below this → `WEAK COVERAGE`. |
| `LOG_MAX_MB` | `20` | Per-session log cap. |
| `MIN_FREE_MB` | `64` | Logging pauses below this free space. |

## UI

480×222, same visual language as DEFCON Defense (black background, yellow headings,
cyan dividers, green/amber/red status). Rendered to the physical display and mirrored to
Virtual Pager. **Footers place B on the left and A on the right**, matching the physical
buttons (red B left, green A right).

Score colours: green `< 40`, amber `40–69`, red `≥ 70`.

### Launch / probe screen

Shows probe results, e.g. `SURVEY: OK`, `BLUETOOTH: OK`, `RECON: PAUSED WHILE SCANNING`,
and lists metrics that will be `N/A`. Proceeds to Overview automatically after the probe.

### Screen 1 — Overview

- Header: `RF SCANNER`, band selector (`2.4 GHZ` / `5 GHZ`, active one highlighted),
  `BT <count>`, clock; `LOG PAUSED` replaces the clock area when logging is paused.
- Left: one vertical bar per channel, height = busy % (or score when busy is `N/A`),
  colour = score. 2.4 GHz shows channels 1–11; 5 GHz shows only channels with observed
  APs/activity. Selected channel outlined. Below: `WORST: CH x  BEST: CH y`.
  Skipped/failed channels show a grey dash.
- Right panel for the selected channel: channel + MHz, score + level
  (`LOW`/`MEDIUM`/`HIGH`), `BUSY`, `NOISE`, `APS (+n overlap)`, `RETRY`, `LIKELY: <cause>`.
- Footer: `B EXIT` · `←→ CHANNEL` · `↑↓ BAND` · `A LOCK ON`.

### Screen 2 — Lock-on

- Header: `LOCKED: CH n · <band>`, `AUDIO ON/OFF`, clock.
- Left box: large smoothed score, level, trend (`▲ RISING` / `▼ FALLING` / `— STEADY`,
  from the slope over the last 10 s), `PEAK <raw max> @HH:MM`.
- Right: `BUSY`, `NOISE`, `RETRY`; 60-second rolling score graph; top 2 strongest
  transmitters on the channel (SSID or BSSID, dBm); `BT/BLE nearby <n> dev`.
- Audio tick: short beep whose interval shrinks as score rises (~2 s at score 0 to
  ~0.15 s at 100); off when score < 20. Toggled with UP.
- Footer: `B BACK` · `←→ CHANNEL` · `↑ AUDIO` · `A MARK SPOT`.
- `MARK SPOT` appends a numbered mark to `marks.csv` and shows a toast
  `MARK 3 @ 12:42 · SCORE 91`.

### Exit / error screens

- Exit: `RESTORING RECON…`, then the stock Pager screen.
- Fatal error (no monitor interface, interface busy): one-screen explanation, `B EXIT`.

All dynamic text is clipped to its panel (same containment rules as
`docs/audits/2026-08-10-text-containment/README.md`).

## Measurement

### Capability probe (`probe.go`)

At launch: confirm `wlan1mon` exists and can be tuned; run one survey dump and check for
`channel active time`, `channel busy time`, and `noise` fields; check `hci0` and
`hcitool`; check free storage. The result is a capability set consumed by sampler,
scorer, and UI.

### Wi-Fi sampling (`sampler.go`)

- **Tuning:** `iw dev wlan1mon set channel <n>` (HT20). A tune failure marks the channel
  skipped for the session (covers DFS/regulatory refusals).
- **Survey:** read `iw dev wlan1mon survey dump` before and after a dwell; for the
  in-use entry, `busy% = Δbusy / Δactive × 100`; `noise` taken as reported.
- **Frames:** an `AF_PACKET` raw socket on `wlan1mon` (no libpcap). Parse radiotap for
  antenna signal and the 802.11 frame-control **retry** bit, plus transmitter address and
  beacon SSID. Per dwell: frame count, `retry% = retries / frames`, strongest
  transmitters, decoded-airtime estimate (frames × length ÷ radiotap rate) used by the
  `NON-WIFI NOISE` rule.
- **AP inventory:** one `_pineap RECON APS format=json` pass before taking the radio
  (gives the 5 GHz active channel list and AP/SSID per channel), refreshed every 30 s
  from beacons observed during sweeps.
- **Overview cadence:** dwell `DWELL_MS` on each channel in the active band; full
  2.4 GHz sweep ≈ 3 s. The non-displayed band is swept every third cycle so switching
  bands shows recent data.
- **Lock-on cadence:** radio parked on the channel; one sample per second.

### Bluetooth (`bluetooth.go`)

Background `hcitool -i hci0 lescan --duplicates` (restarted if it dies). Count unique
addresses seen in a rolling 30 s window. `N/A` if unavailable.

### Score (`score.go`)

Each metric is normalised to 0–100 and clamped:

| Metric | Weight | 0 at | 100 at |
|---|---|---|---|
| Busy % | 45 | 0 % | 100 % |
| Noise floor | 25 | −95 dBm | −75 dBm |
| Retry % | 20 | 0 % | 50 % |
| AP crowding (co-channel + overlapping APs) | 10 | 0 | 12 |

Missing metrics are dropped and the remaining weights renormalised to sum to 100. The
displayed score is an exponential moving average with ≈3 s time constant; peak tracks
the **raw** score.

### LIKELY cause (first match wins)

1. `NON-WIFI NOISE` — noise > `NOISE_HIGH_DBM`, **or** busy > `BUSY_HIGH_PCT` while
   decoded Wi-Fi airtime < 25 % of busy time.
2. `CONGESTION` — busy > `BUSY_HIGH_PCT` and co-channel APs ≥ `CONGESTION_APS`.
3. `CHANNEL OVERLAP` — 2.4 GHz only: an AP stronger than `OVERLAP_MIN_DBM` on a
   different channel within ±4 of this one.
4. `BT DENSE` — 2.4 GHz only: BLE count ≥ `BT_DENSE_COUNT`.
5. `WEAK COVERAGE` — `OFFICE_SSID` set and its strongest BSSID on this channel/band is
   below `WEAK_SIGNAL_DBM` (or not heard at all on the band).
6. `CLEAN`.

Rules whose inputs are `N/A` are skipped.

## Logging (`logger.go`)

Session directory `/root/loot/rf_survey/<YYYYMMDD-HHMMSS>/`:

- `samples.csv` — `epoch,mode,band,channel,busy_pct,noise_dbm,retry_pct,aps,overlap_aps,bt_count,score,likely`
  (`N/A` fields empty). One row per channel per sweep in Overview; one row per second in
  Lock-on.
- `marks.csv` — `mark,epoch,band,channel,score,likely`.
- `session.txt` — probe results and effective CONFIG values.

Writes stop at `LOG_MAX_MB` and pause while free space < `MIN_FREE_MB` (header shows
`LOG PAUSED`). Retrieval: Virtual Pager → Download Loot.

## Lifecycle and error handling

- **Single instance:** lock file `/tmp/rf_scanner.lock`; a second launch shows
  "already running" and exits.
- **Start:** `payload.sh` pauses PineAP Recon channel hopping on `wlan1mon` through the
  PineAP API, then starts `rf-scanner-ui`. The exact pause command is confirmed during
  the on-device check; the probe independently verifies that a tuned channel *stays*
  tuned for one dwell, and fails with a clear error screen if Recon keeps hopping.
- **Cleanup (`trap` on EXIT/INT/TERM, also after the binary returns or crashes):** kill
  `hcitool`, resume Recon hopping and restore 2.4 + 5 GHz bands via
  `PINEAPPLE_SET_BANDS wlan1mon 2 5` (the same default DEFCON Defense sets), release the display,
  remove the lock file.
- Degraded modes per the capability probe: no survey → busy/noise `N/A`; no Bluetooth →
  BT `N/A`, `BT DENSE` skipped; tune failure → channel skipped. No monitor interface →
  fatal error screen.

## Testing

- **Go unit tests:** score normalisation/weights/renormalisation; each LIKELY rule and
  rule order; survey-dump parsing and busy % deltas from text fixtures; radiotap/802.11
  parsing (retry bit, signal, TA, SSID) from byte fixtures; BLE rolling-window counting;
  logger format, size cap, and pause; trend and audio-interval mapping.
- **Preview renders:** a `-preview` mode (same pattern as DEFCON Defense) writes PNGs
  for probe, overview 2.4/5 GHz, lock-on, `N/A` degraded, error, and stress (long SSIDs,
  extreme values, toast) states for visual containment review.
- **Shell tests (`tests/`):** build/package include `RF_SCANNER` and its binary; the
  cleanup trap restores Recon bands and removes the lock under stubbed commands; second
  instance is refused.
- **On-device verification (operator):** confirm survey counters, channel tuning on both
  bands, BLE scan, Recon restore on exit, and that the physical A/B labels match.

## Out of scope

- Floor-plan heat maps, zone tagging, or position estimation.
- True spectrum analysis / non-Wi-Fi emitter identification.
- Changing AP configuration or transmitting anything.
- Integrating into or refactoring the DEFCON Defense UI.
