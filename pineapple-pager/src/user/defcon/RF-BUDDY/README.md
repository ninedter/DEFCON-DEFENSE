# RF-BUDDY

A passive 2.4 GHz / 5 GHz interference finder for the WiFi Pineapple Pager.
Carry it around the office and watch the readings move: walking toward a
problem makes the score rise, walking away makes it fall. It never transmits.

## What it measures

The Pager's monitor radio cannot report channel busy time or a noise floor, so
RF-BUDDY measures what it can hear directly:

- **Airtime %** — how much of the channel is taken up by Wi-Fi frames.
- **Retry %** — how many frames are retransmissions. Lots of retries on a channel
  that is not busy usually means radio interference.
- **APs** — networks on the channel, plus 2.4 GHz networks on overlapping channels.
- **Bluetooth** — nearby BLE devices (earbuds, watches, phones).

## Screens and buttons

**Overview** — one bar per channel (airtime %, coloured by score: green < 40,
amber 40–69, red ≥ 70). The right panel shows the selected channel's score,
airtime, retry %, AP count, frames per second, and the likely cause.

| Button | Action |
|---|---|
| LEFT / RIGHT | select channel |
| UP / DOWN | switch 2.4 GHz / 5 GHz |
| A | lock on to the selected channel |
| B | exit |

**Lock-on** — the radio stays on one channel and updates once a second: big
score, trend, peak, a 60-second graph, the strongest transmitters, and the
nearby Bluetooth count. A tick plays faster as the score rises.

| Button | Action |
|---|---|
| LEFT / RIGHT | move to the neighbouring channel |
| UP | tick on/off |
| A | MARK SPOT — writes a numbered marker to the log |
| B | back to the overview |

## Likely causes

| Label | Meaning |
|---|---|
| INTERFERENCE | many retries while the channel is not busy — typical of microwaves, wireless cameras, or heavy Bluetooth |
| CONGESTION | Wi-Fi is using most of the channel's airtime |
| CHANNEL OVERLAP | a loud AP on a neighbouring 2.4 GHz channel (e.g. 4 next to 6) |
| BT DENSE | many Bluetooth LE devices nearby — a common cause of earbud static |
| WEAK COVERAGE | your office AP is quiet here (needs `OFFICE_SSID`) |
| CLEAN | nothing notable |

## Setup

Edit the CONFIG block at the top of `payload.sh`:

- `OFFICE_SSID` — your office network name. Enables `WEAK COVERAGE`.
- `TICK_RINGTONE` — the lock-on tick. By default a short inline RTTTL beep; set
  it to any ringtone name or RTTTL string. It is played with `RINGTONE` and
  falls back to `VIBRATE` with the same pattern.
- Thresholds (`RETRY_HIGH_PCT`, `AIRTIME_HIGH_PCT`, …) are documented inline.

Recon keeps running while RF-BUDDY is open; it is locked to one channel at a
time and returns to normal hopping when you exit.

## Logs

Each run writes `/root/loot/rf_buddy/<date-time>/`:

- `samples.csv` — one row per channel per sweep, one row per second in lock-on
  (`score` is the raw score, so spikes are kept).
- `marks.csv` — your MARK SPOT markers.
- `session.txt` — what the radio supported and the settings used.

Retrieve them with Virtual Pager → **Download Loot**.
