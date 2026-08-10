# DEF CON WiFi Pineapple Pager — Defensive Loadout

**Date:** 2026-08-06
**Status:** Design — pending user review
**Author:** Henry Hu (with Claude Code)

## Goal

Turn the Hak5 WiFi Pineapple Pager into a **passive, fatigue-resistant early-warning
system** for network attacks aimed at the operator while at DEF CON. It detects and
warns only — it never transmits attacks against other people.

**Core UX principle:** _warn loudly on a **repeated same-offense**, stay quiet on the
ambient chaos._ DEF CON's airspace is saturated with deauths, evil twins, and Flipper
Zeros; a naive "alert on everything" setup buzzes nonstop within minutes and gets
ignored. The value is warning when a **specific** attacker persists, or when something
targets the operator directly.

## Posture (confirmed with user)

- **Passive / defensive only.** Detect + warn. No transmitted attacks.
- **Plus an intentional honeypot:** an open decoy AP the operator runs on purpose, with
  an alert when anything connects to it.
- **Excluded (offensive, aimed at other people, out of scope):** `fenris` (deauth
  storm), `hati` (PMKID attack), handshake capture / autocrack / hashtopolis upload,
  `evil_portal` / `goodportal` captive portals, PineAP karma / rogue-AP association.
  These are neither staged nor armed.

## Device facts (from the pulled repo)

- On-device payload root: `/mmc/root/payloads/library/<category>/<name>/payload.sh`.
- **Alert hooks** live at `alerts/<event>/<handler>/payload.sh` and are fired
  **event-driven** by the PineAP engine. New alert payloads install **disabled** (dir
  renamed `DISABLED.<name>`); a handler is **armed** when its directory has **no**
  `DISABLED.` prefix (equivalently, enabled via the on-device Alerts menu).
- The device runs **one foreground payload at a time**, but alert hooks fire
  independently of whatever foreground payload is running — so the always-on hooks
  (Tier 1) and an on-demand monitor (Tier 3) coexist.
- **Alert event variables** (verbatim from the repo's `example` handlers):
  - `deauth_flood_detected`: `_ALERT_DENIAL_MESSAGE`,
    `_ALERT_DENIAL_SOURCE_MAC_ADDRESS`, `_ALERT_DENIAL_DESTINATION_MAC_ADDRESS`,
    `_ALERT_DENIAL_AP_MAC_ADDRESS`, `_ALERT_DENIAL_CLIENT_MAC_ADDRESS`.
  - `pineapple_client_connected`: `_ALERT_CLIENT_CONNECTED_SUMMARY`,
    `_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS`,
    `_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS`, `_ALERT_CLIENT_CONNECTED_SSID`,
    `_ALERT_CLIENT_CONNECTED_SSID_LENGTH`.
- **Alert primitives** (confirmed in existing payloads):
  - `ALERT "<multi-line message>"` — on-screen alert; may end with "Press any button…".
  - `RINGTONE "<name|/path.rtttl|inline-RTTTL>"` — built-in names include `alert`,
    `warning`, `halt`, `success`; backgroundable with `&`.
  - `VIBRATE <on ms> <off ms> <on ms> …` — e.g. `VIBRATE 300 100 300`; also `VIBRATE`
    bare or a named pattern.
  - `LED <STATE>` — states seen: `ATTACK`, `FAIL`, `SETUP`, `SPECIAL`, `FINISH`, colors
    (`R`, `G`, `GREEN`, `RED`, `WHITE`, `OFF`).
  - `LOG "<msg>"` — writes to the payload log.

## Approach (chosen: A)

**A — Proven payloads + one custom deauth handler.** Arm the community-tested detectors
as-is / lightly-tuned, and hand-write only the pieces that need real cross-event
state-tracking (the repeat-offense engine). Lowest risk, delivers the exact
"repeated same-offense" behavior. _(Rejected: B, a single monolithic super-payload —
too much untested-on-hardware code to debug at DEF CON; C, curation only — the stock
deauth handler echoes every event and cannot do repeat-only alerting.)_

## Deliverables

1. `defcon-defense/` — a **self-contained staging folder** on the Mac, mirroring the
   device's `library/…` layout, for a one-drag USB copy onto the Pager.
2. Custom handler `alerts/deauth_flood_detected/defcon_sentry` (repeat-offense engine).
3. Custom handler `alerts/pineapple_client_connected/defcon_honeypot` (dedup-by-client
   honeypot warning).
4. Curated existing payloads copied in verbatim: `PORT_ALERT`, `ICMP_ALERT`,
   `find_hackers`, `alien_ap`, `SignalFence`.
5. `defcon-defense/build.sh` — reproducibly assembles the staging folder from the
   submodule + custom handlers.
6. `defcon-defense/README.md` — install, arming, run-order cheat sheet, tuning knobs,
   one-page threat model, and authorized-use note.
7. Host-side test harness (`defcon-defense/tests/`) validating the state-machine logic.
8. This spec, committed to the meta-repo.

## Component 1 — `defcon_sentry` (deauth repeat-offense handler)

Auto-fires on every `deauth_flood_detected` event. Maintains state across firings so it
can alert **only on repeats**.

**Config block (top of file, all tunable):**
- `REPEAT_THRESHOLD=3` — same-offense hits needed within the window to warn.
- `WINDOW_SECONDS=120` — sliding window for counting repeats.
- `COOLDOWN_SECONDS=300` — per-offense silence after a warning.
- `KEY_MODE="source_ap"` — offense identity: `source` | `source_ap` | `source_client`.
- `WATCH_MACS=""` — comma-separated MACs that are "yours"; a flood hitting one of these
  warns **immediately** (targeted-at-me escalation, threshold bypassed, cooldown still
  applies).
- `RINGTONE_NAME="warning"`, `LED_STATE="ATTACK"`, `VIBRATE_PATTERN="300 100 300 100 300"`.
- `STATE_DIR="/root/loot/defcon_sentry"`.

**Per-invocation logic:**
1. Ensure `STATE_DIR`; append the raw event (timestamp + all `_ALERT_*` vars) to
   `events.log` — full record even when it stays silent.
2. Sanitize MACs (uppercase, strip whitespace); compute `KEY` from `KEY_MODE`.
3. Acquire a lock (`flock` on a lockfile; fallback `mkdir` lock) to serialize state
   updates — the engine may fire events in rapid succession.
4. Load the state row for `KEY` (`count`, `window_start`, `last_alert`, `last_seen`).
5. If `now - window_start > WINDOW_SECONDS`: reset `count=0`, `window_start=now`.
6. `count += 1`; `last_seen=now`.
7. Decide:
   - **Targeted:** any `WATCH_MACS` entry appears as source/dest/ap/client in this event
     → warn (if `now - last_alert >= COOLDOWN_SECONDS`).
   - **Repeat:** else if `count >= REPEAT_THRESHOLD` and
     `now - last_alert >= COOLDOWN_SECONDS` → warn.
8. On warn: `last_alert=now`; `LED $LED_STATE`; `VIBRATE $VIBRATE_PATTERN`;
   `RINGTONE "$RINGTONE_NAME" &`; `ALERT` with a multi-line summary (attacker MAC,
   target AP/client, hit-count in window, TARGETED flag, time); `LOG` a one-liner.
9. Persist state atomically (temp file + `mv`); prune rows whose `last_seen` is older
   than 1 h to bound file size; release lock.

**Robustness:** every variable guarded (`${var:-}`); never exit in a way that disrupts
the engine; sub-second runtime. State file is CSV:
`key,count,window_start,last_alert,last_seen` (one row per key), rewritten atomically.

## Component 2 — `defcon_honeypot` (client-connected handler)

Auto-fires on `pineapple_client_connected`. Because a connection to your decoy AP **is**
the signal, it warns on the **first** sight of each client rather than on repeats, and
dedups so reassociations from the same client don't spam.

**Config:** `COOLDOWN_SECONDS=600` per client MAC; `RINGTONE_NAME="alert"`,
`LED_STATE="SPECIAL"`, `VIBRATE_PATTERN="200 100 200"`, `STATE_DIR="/root/loot/defcon_sentry"`.

**Logic:** dedup by `_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS`; warn on first sight and
after cooldown for repeats; flag **randomized / locally-administered** MACs (2nd hex
nibble in `{2,6,A,E}`); log every connect to `honeypot.csv`
(`ts,client_mac,ap_mac,ssid,randomized`).

**Operator setup (documented in README, not automated):** run an **open** decoy AP in
PineAP using a **neutral SSID that does not impersonate any real network** (staying out
of evil-twin territory). No karma / association attack is used — just a plain open AP
that clients may choose to join.

## Component 3 — Curated existing payloads (copied verbatim)

No edits to the upstream source; any needed tweak is a copy-then-edit **inside the
staging folder**, never a mutation of the `payloads` submodule.

- `user/general/PORT_ALERT` — detects a port scan against the Pager (≥ N SYNs), loud
  ringtone + attacker IP→port breakdown, auto-hardens firewall for 60 s.
- `user/general/ICMP_ALERT` — detects ping / traceroute probing the Pager, alerts and
  blocks ICMP/UDP for 60 s.
- `user/reconnaissance/find_hackers` — evil-twin / SSID-spoof detection (already
  repeat-aware via `MIN_SPOOFING_COUNT=5`) plus BT / Flipper activity.
- `user/reconnaissance/alien_ap` — flags APs beaconing bogus country codes (rogue-AP /
  evil-twin tell).
- `user/reconnaissance/SignalFence` *(optional)* — warns when a device gets close and
  **lingers** (persistence = repeat).

README documents each payload's config knobs (e.g. `find_hackers` `MIN_SPOOFING_COUNT`,
`PORT_ALERT` SYN threshold).

## Deployment / install

1. Run `defcon-defense/build.sh` to assemble `defcon-defense/library/…` from the
   submodule + custom handlers.
2. Copy `defcon-defense/library/*` into the Pager's `/mmc/root/payloads/library/` over
   USB — **before** joining any con network.
3. **Arm the hooks:** ensure the `defcon_sentry` and `defcon_honeypot` directories have
   **no** `DISABLED.` prefix (or enable them in the on-device Alerts menu).
4. **Start passive monitoring:** enable PineAP recon/scan (listening) so deauth events
   are heard; configure the open decoy AP for the honeypot.
5. **Sweeps on demand:** launch `find_hackers` / `alien_ap` / `SignalFence` from the
   payload menu when you want an active look around.

## Testing / verification (no hardware in the loop)

- **Static:** `bash -n` on every `payload.sh` in the staging folder; `shellcheck` if
  available.
- **Logic harness** (`defcon-defense/tests/`): source the state-machine functions with
  mocked `_ALERT_*` vars and stubbed `ALERT/RINGTONE/VIBRATE/LED/LOG` (recording shell
  functions). Assert:
  - below threshold → no alert;
  - reaching `REPEAT_THRESHOLD` within the window → exactly one alert;
  - further hits during cooldown → suppressed;
  - window expiry resets the count (a later burst re-alerts);
  - a `WATCH_MACS` hit alerts immediately regardless of count;
  - honeypot: first client → alert, repeat within cooldown → suppressed, randomized MAC
    flagged.
- **Device smoke test** (documented): trigger a benign repeat, confirm one loud alert +
  cooldown behavior.

## Non-goals

- No offensive / transmit payloads.
- Not a substitute for opsec (VPN, MAC randomization, radios off when idle) — the README
  lists these as complements, not replacements.
- Cannot remotely configure the physical device from the Mac; the deliverable is the
  staged folder plus precise instructions.

## Legal / authorized use

Scope is limited to passively monitoring RF you can already hear, your own device's
inbound traffic, and your own decoy AP. The staging README carries the repo's
authorized-use notice and explicitly advises **against impersonating real SSIDs**.
