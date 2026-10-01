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
- **Bluetooth** — nearby BLE devices (earbuds, watches, phones), counted with a
  passive scan that never transmits.

## Screens and buttons

**Overview** — one bar per channel (airtime %, coloured by score: green < 40,
amber 40–69, red ≥ 70). The right panel shows the selected channel's score,
airtime, retry %, AP count, frames per second, and the likely cause.

| Button | Action |
|---|---|
| LEFT / RIGHT | select channel |
| UP / DOWN | cycle tabs: 2.4 GHz / 5 GHz / BT |
| A | lock on to the selected channel |
| B | exit |

**Lock-on** — the radio stays on one channel and updates once a second: big
score, trend, peak, a 60-second graph, the strongest transmitters, and the
nearby Bluetooth count. The buzzer tick plays faster as the score rises.

| Button | Action |
|---|---|
| LEFT / RIGHT | move to the neighbouring channel |
| UP | tick on/off |
| A | MARK SPOT — writes a numbered marker to the log |
| B | back to the overview |

**BT tab** — nearby Bluetooth LE devices, strongest first, with the selected
device's address, maker, signal, peak, advert rate, TX power and last-seen time.

| Button | Action |
|---|---|
| LEFT / RIGHT | select the previous / next device |
| UP / DOWN | cycle tabs: 2.4 GHz / 5 GHz / BT |
| A | TRACK the selected device |
| B | exit |

**BT track** — a walk-around proximity meter for one device: big signal
strength with VERY CLOSE / CLOSE / NEAR / FAR, closer/farther trend, peak, a
60-second graph, and which Wi-Fi channels BLE advertising overlaps. The buzzer
tick speeds up as you get closer.

| Button | Action |
|---|---|
| LEFT / RIGHT | track the previous / next device |
| UP | tick on/off |
| A | MARK SPOT — writes a numbered marker to the log |
| B | back to the BT list |

BT marks go in `marks.csv` as `n,epoch,bt,ADDRESS,RSSI,LABEL` (the channel
column holds the device address, the score column its signal in dBm).

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
- `TICK_FREQ_HZ` — pitch of the lock-on tick on the Pager buzzer (default 2000).
- `TICK_VOLUME` — loudness of the tick, 0-100 (default 60).
- Thresholds (`RETRY_HIGH_PCT`, `AIRTIME_HIGH_PCT`, …) are documented inline.

Recon keeps running while RF-BUDDY is open; it is locked to one channel at a
time and returns to normal hopping when you exit. The Bluetooth scan is passive.

## Viewer and the stock UI

Open **http://172.16.52.1:1474** for RF-BUDDY's own viewer: a live copy of the
screen with on-page buttons.

While RF-BUDDY runs, the stock Pager menu and the stock Virtual Pager (`:1471`)
are paused; they return when you press B.

### If the Pager menu stays frozen

RF-BUDDY's watchdog resumes the stock menu if RF-BUDDY is killed. If the
RF-BUDDY app itself hangs, hold the power button to restart the Pager.

## Logs

Each run writes `/root/loot/rf_buddy/<date-time>/`:

- `samples.csv` — one row per channel per sweep, one row per second in lock-on
  (`score` is the raw score, so spikes are kept).
- `marks.csv` — your MARK SPOT markers.
- `session.txt` — what the radio supported and the settings used.

Retrieve them with Virtual Pager → **Download Loot** (after RF-BUDDY has exited and the stock Virtual Pager is back).
