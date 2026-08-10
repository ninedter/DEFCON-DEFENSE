# DEF CON Pager Defensive Loadout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained `defcon-defense/` staging folder that deploys a passive, fatigue-resistant network-attack early-warning loadout to the WiFi Pineapple Pager over USB.

**Architecture:** Two custom alert handlers (`defcon_sentry` for repeat-offense deauth warnings, `defcon_honeypot` for decoy-AP connect warnings) share one testable bash library (`pager_alert_lib.sh`). Curated stock detectors are copied verbatim. A `build.sh` assembles the device-layout `library/` tree; a host-side test harness validates the alert logic since the physical device is not in the loop.

**Tech Stack:** POSIX-ish bash (busybox on device — `flock`, `awk`, `jq` confirmed available), DuckyScript alert primitives (`ALERT`, `RINGTONE`, `VIBRATE`, `LED`, `LOG`).

## Global Constraints

- All handler code must run under busybox bash on-device; avoid GNU-only flags where a busybox fallback is easy (e.g. `date -d @N` may be absent — always fall back to raw epoch).
- Every deliverable `payload.sh` must pass `bash -n`.
- Custom handler directories must be **self-contained**: `payload.sh` + its copy of `pager_alert_lib.sh` + `README.md`. On-device a payload sources only files in its own directory.
- **Never mutate the `payloads` submodule.** Curated stock payloads are *copied* into the build output only.
- Passive/defensive only — no offensive/transmit payloads are staged or armed.
- On-device state lives under `STATE_DIR` (default `/root/loot/defcon_sentry`).
- Time is obtained via `now_epoch`, which honors `$NOW_OVERRIDE` so tests can simulate elapsed time. Never call `date +%s` directly in logic.
- Shared alert-command names (stubbed in tests, real on device): `ALERT`, `RINGTONE`, `VIBRATE`, `LED`, `LOG`.
- Config defaults — sentry: `REPEAT_THRESHOLD=3`, `WINDOW_SECONDS=120`, `COOLDOWN_SECONDS=300`, `KEY_MODE=source_ap`, `WATCH_MACS=""`, `RINGTONE_NAME=warning`, `LED_STATE=ATTACK`, `VIBRATE_PATTERN="300 100 300 100 300"`. Honeypot: `COOLDOWN_SECONDS=600`, `RINGTONE_NAME=alert`, `LED_STATE=SPECIAL`, `VIBRATE_PATTERN="200 100 200"`.
- Repo root for relative paths: the worktree root (`defcon-defense/` and `payloads/` are siblings there).

---

### Task 1: Scaffold `defcon-defense/` + MAC/time helpers

**Files:**
- Create: `defcon-defense/lib/pager_alert_lib.sh`
- Create: `defcon-defense/tests/stubs.sh`
- Create: `defcon-defense/tests/assert.sh`
- Test: `defcon-defense/tests/test_helpers.sh`

**Interfaces:**
- Produces: `now_epoch` → prints epoch seconds, honoring `$NOW_OVERRIDE`. `sanitize_mac <raw>` → prints uppercased, whitespace-stripped MAC (colons preserved). `is_randomized_mac <mac>` → exit 0 if locally-administered+unicast (2nd hex nibble ∈ {2,6,A,E}), else 1.

- [ ] **Step 1: Write the failing test**

Create `defcon-defense/tests/assert.sh`:

```bash
#!/bin/bash
# Minimal assertion helpers. Sets FAIL=1 on any failure.
FAIL=0
assert_eq() { # actual expected label
  if [ "$1" != "$2" ]; then echo "FAIL: $3 (got '$1' want '$2')"; FAIL=1
  else echo "ok: $3"; fi
}
assert_rc() { # actual_rc expected_rc label
  if [ "$1" != "$2" ]; then echo "FAIL: $3 (rc got '$1' want '$2')"; FAIL=1
  else echo "ok: $3"; fi
}
```

Create `defcon-defense/tests/test_helpers.sh`:

```bash
#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"
. "$ROOT/lib/pager_alert_lib.sh"

# now_epoch honors override
assert_eq "$(NOW_OVERRIDE=12345 now_epoch)" "12345" "now_epoch uses NOW_OVERRIDE"

# sanitize_mac: lowercase->upper, strip spaces, keep colons
assert_eq "$(sanitize_mac '  aa:bb:cc:dd:ee:ff ')" "AA:BB:CC:DD:EE:FF" "sanitize_mac normalizes"
assert_eq "$(sanitize_mac '')" "" "sanitize_mac empty"

# is_randomized_mac: DA (nibble A) => randomized; AA (nibble A) => randomized; A8 (nibble 8) => not
is_randomized_mac "DA:11:22:33:44:55"; assert_rc "$?" "0" "randomized nibble A"
is_randomized_mac "A2:11:22:33:44:55"; assert_rc "$?" "0" "randomized nibble 2"
is_randomized_mac "A8:11:22:33:44:55"; assert_rc "$?" "1" "not randomized nibble 8"
is_randomized_mac "";                  assert_rc "$?" "1" "empty not randomized"

exit $FAIL
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash defcon-defense/tests/test_helpers.sh`
Expected: FAIL — `pager_alert_lib.sh` does not exist (source error / functions not defined).

- [ ] **Step 3: Write minimal implementation**

Create `defcon-defense/lib/pager_alert_lib.sh`:

```bash
#!/bin/bash
# Shared alert library for the DEF CON Pager defensive handlers.
# Sourced by each handler's payload.sh on-device and by the host test harness.
# Side effects go through ALERT/RINGTONE/VIBRATE/LED/LOG, which are real
# DuckyScript commands on-device and recorder stubs in tests.

# Epoch seconds, overridable for deterministic tests.
now_epoch() { echo "${NOW_OVERRIDE:-$(date +%s)}"; }

# Uppercase, strip all whitespace; keep colons.
sanitize_mac() {
  printf '%s' "${1:-}" | tr -d '[:space:]' | tr 'a-f' 'A-F'
}

# Exit 0 when MAC looks randomized (locally administered + unicast):
# second hex nibble is one of 2,6,A,E.
is_randomized_mac() {
  local mac; mac="$(sanitize_mac "${1:-}")"
  [ "${#mac}" -ge 2 ] || return 1
  case "${mac:1:1}" in
    2|6|A|E) return 0 ;;
    *) return 1 ;;
  esac
}
```

Create `defcon-defense/tests/stubs.sh`:

```bash
#!/bin/bash
# Recorder stubs for the DuckyScript alert commands. Requires $REC set to a file.
: "${REC:?REC must point to a recorder file}"
ALERT()    { printf 'ALERT\t%s\n'    "$*" >> "$REC"; }
RINGTONE() { printf 'RINGTONE\t%s\n' "$*" >> "$REC"; }
VIBRATE()  { printf 'VIBRATE\t%s\n'  "$*" >> "$REC"; }
LED()      { printf 'LED\t%s\n'      "$*" >> "$REC"; }
LOG()      { printf 'LOG\t%s\n'      "$*" >> "$REC"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash defcon-defense/tests/test_helpers.sh`
Expected: all `ok:` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add defcon-defense/lib/pager_alert_lib.sh defcon-defense/tests/stubs.sh defcon-defense/tests/assert.sh defcon-defense/tests/test_helpers.sh
git commit -m "feat(pager): scaffold defcon-defense with MAC/time helpers"
```

---

### Task 2: State store — read / upsert / prune + locking

**Files:**
- Modify: `defcon-defense/lib/pager_alert_lib.sh` (append functions)
- Test: `defcon-defense/tests/test_state.sh`

**Interfaces:**
- Consumes: `now_epoch` (Task 1).
- Produces: `state_read_row <file> <key>` → prints the whole CSV row for `key` or nothing. `state_upsert_row <file> <key> <count> <window_start> <last_alert> <last_seen>` → atomic replace-or-insert. `state_prune <file> <max_age> <now>` → drop rows whose 5th field (`last_seen`) < `now-max_age`. `with_lock <lockfile> <cmd...>` → run cmd under `flock -w 5` on fd 9 (no-op lock if flock missing), preserving side effects in the current shell. Row schema: `key,count,window_start,last_alert,last_seen`.

- [ ] **Step 1: Write the failing test**

Create `defcon-defense/tests/test_state.sh`:

```bash
#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"
. "$ROOT/lib/pager_alert_lib.sh"

TMP="$(mktemp -d)"; SF="$TMP/state.csv"

# insert
state_upsert_row "$SF" "AA|BB" 1 1000 0 1000
assert_eq "$(state_read_row "$SF" 'AA|BB')" "AA|BB,1,1000,0,1000" "insert row"

# update same key (no duplicate)
state_upsert_row "$SF" "AA|BB" 2 1000 1005 1005
assert_eq "$(state_read_row "$SF" 'AA|BB')" "AA|BB,2,1000,1005,1005" "update row"
assert_eq "$(wc -l < "$SF" | tr -d ' ')" "1" "no duplicate rows"

# second key coexists
state_upsert_row "$SF" "CC|DD" 1 2000 0 2000
assert_eq "$(state_read_row "$SF" 'CC|DD')" "CC|DD,1,2000,0,2000" "second key"

# prune drops old last_seen (field 5), keeps recent
state_prune "$SF" 100 2050   # cutoff 1950: AA|BB last_seen 1005 dropped, CC|DD 2000 kept
assert_eq "$(state_read_row "$SF" 'AA|BB')" "" "prune drops stale"
assert_eq "$(state_read_row "$SF" 'CC|DD')" "CC|DD,1,2000,0,2000" "prune keeps fresh"

# with_lock runs the command and its writes persist
with_lock "$TMP/lock" state_upsert_row "$SF" "EE|FF" 3 3000 3000 3000
assert_eq "$(state_read_row "$SF" 'EE|FF')" "EE|FF,3,3000,3000,3000" "with_lock persists writes"

# with_lock must not permanently clobber the caller's stderr (regression)
ERRLOG="$TMP/err"
( with_lock "$TMP/lock2" true
  echo "stderr-after-lock" >&2
) 2>"$ERRLOG"
assert_eq "$(cat "$ERRLOG")" "stderr-after-lock" "with_lock preserves caller stderr"

exit $FAIL
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash defcon-defense/tests/test_state.sh`
Expected: FAIL — `state_upsert_row: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `defcon-defense/lib/pager_alert_lib.sh`:

```bash
# --- state store (CSV: key,count,window_start,last_alert,last_seen) ---

state_read_row() { # file key
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -F, -v k="$key" '$1==k{print; exit}' "$file"
}

state_upsert_row() { # file key count window_start last_alert last_seen
  local file="$1" key="$2" count="$3" ws="$4" la="$5" ls="$6"
  local tmp="${file}.tmp.$$"
  mkdir -p "$(dirname "$file")"
  { [ -f "$file" ] && awk -F, -v k="$key" '$1!=k' "$file"
    printf '%s,%s,%s,%s,%s\n' "$key" "$count" "$ws" "$la" "$ls"
  } > "$tmp"
  mv -f "$tmp" "$file"
}

state_prune() { # file max_age now
  local file="$1" max_age="$2" now="$3"
  [ -f "$file" ] || return 0
  local cutoff=$((now - max_age)) tmp="${file}.tmp.$$"
  awk -F, -v c="$cutoff" '$5>=c' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

with_lock() { # lockfile cmd...
  local lockfile="$1"; shift
  # Brace group scopes 2>/dev/null to just the lockfile open (fd 2 restored
  # afterward), while the bare `exec 9>` still persists fd 9 to this shell.
  { exec 9>"$lockfile"; } 2>/dev/null || { "$@"; return $?; }
  if command -v flock >/dev/null 2>&1 && ! flock -w 5 9; then
    echo "with_lock: timed out waiting for $lockfile" >&2
  fi
  "$@"; local rc=$?
  flock -u 9 2>/dev/null
  exec 9>&-
  return $rc
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash defcon-defense/tests/test_state.sh`
Expected: all `ok:`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add defcon-defense/lib/pager_alert_lib.sh defcon-defense/tests/test_state.sh
git commit -m "feat(pager): add locked atomic CSV state store"
```

---

### Task 3: `alert_fire` loud-alert wrapper

**Files:**
- Modify: `defcon-defense/lib/pager_alert_lib.sh` (append)
- Test: `defcon-defense/tests/test_alert_fire.sh`

**Interfaces:**
- Produces: `alert_fire <message>` → emits `LED $LED_STATE`, `VIBRATE $VIBRATE_PATTERN` (unquoted, multi-arg), `RINGTONE "$RINGTONE_NAME" &`, `ALERT "$message"`, `LOG "$message"`; always returns 0.

- [ ] **Step 1: Write the failing test**

Create `defcon-defense/tests/test_alert_fire.sh`:

```bash
#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"
TMP="$(mktemp -d)"; export REC="$TMP/rec"; : > "$REC"
. "$HERE/stubs.sh"
. "$ROOT/lib/pager_alert_lib.sh"

LED_STATE="ATTACK"; RINGTONE_NAME="warning"; VIBRATE_PATTERN="300 100 300"
alert_fire "hello world"
sleep 0.2   # RINGTONE runs backgrounded

assert_eq "$(grep -c '^ALERT'    "$REC")" "1" "ALERT emitted once"
assert_eq "$(grep -c '^LOG'      "$REC")" "1" "LOG emitted once"
assert_eq "$(grep -c '^LED'      "$REC")" "1" "LED emitted once"
assert_eq "$(grep -c '^VIBRATE'  "$REC")" "1" "VIBRATE emitted once"
assert_eq "$(grep -c '^RINGTONE' "$REC")" "1" "RINGTONE emitted once"
assert_eq "$(awk -F'\t' '/^ALERT/{print $2}' "$REC")" "hello world" "ALERT carries message"
assert_eq "$(awk -F'\t' '/^LED/{print $2}' "$REC")" "ATTACK" "LED uses LED_STATE"

# alert_fire honors "always return 0" even under caller set -e when a channel fails
LED() { return 1; }                       # force a channel command to fail
( set -e; alert_fire "boom" ); assert_rc "$?" "0" "alert_fire returns 0 under set -e despite failing channel"

exit $FAIL
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash defcon-defense/tests/test_alert_fire.sh`
Expected: FAIL — `alert_fire: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `defcon-defense/lib/pager_alert_lib.sh`:

```bash
# --- loud alert wrapper (uses config env: LED_STATE, VIBRATE_PATTERN, RINGTONE_NAME) ---
alert_fire() { # message
  local msg="$1"
  # `|| true` so a failing channel can't abort the function under a caller's
  # set -e; the contract is best-effort fire-all-channels + always return 0.
  LED "${LED_STATE:-ATTACK}" 2>/dev/null || true
  # shellcheck disable=SC2086  # VIBRATE takes multiple duration args
  VIBRATE ${VIBRATE_PATTERN:-300 100 300} 2>/dev/null || true
  RINGTONE "${RINGTONE_NAME:-warning}" 2>/dev/null &
  ALERT "$msg" || true
  LOG "$msg" || true
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash defcon-defense/tests/test_alert_fire.sh`
Expected: all `ok:`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add defcon-defense/lib/pager_alert_lib.sh defcon-defense/tests/test_alert_fire.sh
git commit -m "feat(pager): add alert_fire loud-alert wrapper"
```

---

### Task 4: `sentry_process_event` repeat-offense engine

**Files:**
- Modify: `defcon-defense/lib/pager_alert_lib.sh` (append)
- Test: `defcon-defense/tests/test_sentry.sh`

**Interfaces:**
- Consumes: `now_epoch`, `sanitize_mac`, state functions, `with_lock`, `alert_fire`.
- Produces: `sentry_process_event` → reads `_ALERT_DENIAL_{SOURCE,DESTINATION,AP,CLIENT}_MAC_ADDRESS` and config env; appends raw record to `$STATE_DIR/events.log`; updates `$STATE_DIR/deauth_state.csv`; fires exactly one `alert_fire` when the offense key crosses `REPEAT_THRESHOLD` within `WINDOW_SECONDS` (or a `WATCH_MACS` MAC is present) and cooldown has elapsed. Helper `_sentry_update` performs the locked section. Always returns 0.

- [ ] **Step 1: Write the failing test**

Create `defcon-defense/tests/test_sentry.sh`:

```bash
#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

setup() {
  TMP="$(mktemp -d)"; export REC="$TMP/rec"; : > "$REC"
  export STATE_DIR="$TMP/state"
  . "$HERE/stubs.sh"; . "$ROOT/lib/pager_alert_lib.sh"
  REPEAT_THRESHOLD=3; WINDOW_SECONDS=120; COOLDOWN_SECONDS=300
  KEY_MODE="source_ap"; WATCH_MACS=""
  RINGTONE_NAME="warning"; LED_STATE="ATTACK"; VIBRATE_PATTERN="1"
  unset _ALERT_DENIAL_SOURCE_MAC_ADDRESS _ALERT_DENIAL_DESTINATION_MAC_ADDRESS \
        _ALERT_DENIAL_AP_MAC_ADDRESS _ALERT_DENIAL_CLIENT_MAC_ADDRESS
}
alerts() { grep -c '^ALERT' "$REC" 2>/dev/null || true; }
fire() { NOW_OVERRIDE="$1" sentry_process_event; }

# Scenario A: repeats reach threshold -> exactly one alert, cooldown holds
setup
export _ALERT_DENIAL_SOURCE_MAC_ADDRESS="AA:BB:CC:00:00:01"
export _ALERT_DENIAL_AP_MAC_ADDRESS="DE:AD:BE:EF:00:01"
fire 1000; fire 1001
assert_eq "$(alerts)" "0" "A: below threshold silent"
fire 1002
assert_eq "$(alerts)" "1" "A: threshold fires once"
fire 1003; fire 1004
assert_eq "$(alerts)" "1" "A: cooldown suppresses repeats"

# events.log recorded every event (5 so far)
assert_eq "$(wc -l < "$STATE_DIR/events.log" | tr -d ' ')" "5" "A: all events logged"

# Scenario B: after window reset + cooldown, a fresh burst re-alerts
fire 1400; fire 1401     # 1400-ws(1000)>120 -> reset, count 1 then 2
assert_eq "$(alerts)" "1" "B: still one during rebuild"
fire 1402                # count 3, now-last_alert(1002)=400>=300 -> alert
assert_eq "$(alerts)" "2" "B: re-alert after window+cooldown"

# Scenario C: targeted MAC alerts immediately on first hit
setup
WATCH_MACS="99:88:77:66:55:44"
export _ALERT_DENIAL_SOURCE_MAC_ADDRESS="12:34:56:78:9A:BC"
export _ALERT_DENIAL_AP_MAC_ADDRESS="00:11:22:33:44:55"
export _ALERT_DENIAL_CLIENT_MAC_ADDRESS="99:88:77:66:55:44"
fire 2000
assert_eq "$(alerts)" "1" "C: targeted fires on first hit"

# Scenario D: empty offense key (no MACs at all) -> no crash, no alert
setup
fire 3000
assert_eq "$(alerts)" "0" "D: empty event silent"

# Scenario E: watched MAC present only in a non-KEY_MODE field (empty key) still alerts
setup
WATCH_MACS="AA:AA:AA:AA:AA:AA"
export _ALERT_DENIAL_CLIENT_MAC_ADDRESS="AA:AA:AA:AA:AA:AA"   # src+ap empty under default source_ap
fire 6000
assert_eq "$(alerts)" "1" "E: watched MAC alerts even when KEY_MODE fields empty"

exit $FAIL
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash defcon-defense/tests/test_sentry.sh`
Expected: FAIL — `sentry_process_event: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `defcon-defense/lib/pager_alert_lib.sh`:

```bash
# --- deauth repeat-offense engine ---

# Print 1 if any WATCH_MACS entry appears in the event (any field), else 0.
# Runs in a command-substitution subshell, so its IFS twiddling never leaks.
_sentry_targeted() { # src dst ap cli
  local src="$1" dst="$2" ap="$3" cli="$4"
  [ -n "${WATCH_MACS:-}" ] || { echo 0; return; }
  local m oldifs found=0
  oldifs="$IFS"; IFS=','
  for m in $WATCH_MACS; do
    IFS="$oldifs"
    m="$(sanitize_mac "$m")"; [ -z "$m" ] && continue
    if [ "$m" = "$src" ] || [ "$m" = "$dst" ] || [ "$m" = "$ap" ] || [ "$m" = "$cli" ]; then
      found=1; break
    fi
  done
  IFS="$oldifs"
  echo "$found"
}

sentry_process_event() {
  local now; now="$(now_epoch)"
  local state_dir="${STATE_DIR:-/root/loot/defcon_sentry}"
  local state_file="$state_dir/deauth_state.csv"
  local lock="$state_dir/.deauth.lock"
  mkdir -p "$state_dir"

  local src dst ap cli
  src="$(sanitize_mac "${_ALERT_DENIAL_SOURCE_MAC_ADDRESS:-}")"
  dst="$(sanitize_mac "${_ALERT_DENIAL_DESTINATION_MAC_ADDRESS:-}")"
  ap="$(sanitize_mac "${_ALERT_DENIAL_AP_MAC_ADDRESS:-}")"
  cli="$(sanitize_mac "${_ALERT_DENIAL_CLIENT_MAC_ADDRESS:-}")"

  printf '%s,src=%s,dst=%s,ap=%s,cli=%s\n' "$now" "$src" "$dst" "$ap" "$cli" \
    >> "$state_dir/events.log"

  # Targeting is independent of KEY_MODE and must survive the degenerate-key
  # guard below, so a watched MAC always alerts.
  local targeted; targeted="$(_sentry_targeted "$src" "$dst" "$ap" "$cli")"

  local key
  case "${KEY_MODE:-source_ap}" in
    source)        key="$src" ;;
    source_client) key="${src}|${cli}" ;;
    *)             key="${src}|${ap}" ;;
  esac
  # Drop only fully-unusable events that are NOT targeting a watched MAC.
  case "$key" in
    ""|"|")
      [ "$targeted" = "1" ] || return 0
      key="watched"
      ;;
  esac

  with_lock "$lock" _sentry_update "$now" "$state_file" "$key" "$src" "$dst" "$ap" "$cli" "$targeted"
  return 0
}

_sentry_update() { # now state_file key src dst ap cli targeted
  local now="$1" state_file="$2" key="$3" src="$4" dst="$5" ap="$6" cli="$7" targeted="${8:-0}"
  local threshold="${REPEAT_THRESHOLD:-3}" window="${WINDOW_SECONDS:-120}" cooldown="${COOLDOWN_SECONDS:-300}"

  state_prune "$state_file" 3600 "$now"

  local row count ws la
  row="$(state_read_row "$state_file" "$key")"
  if [ -n "$row" ]; then
    count="$(printf '%s' "$row" | cut -d, -f2)"
    ws="$(printf '%s' "$row" | cut -d, -f3)"
    la="$(printf '%s' "$row" | cut -d, -f4)"
  else
    count=0; ws="$now"; la=0
  fi
  if [ $((now - ws)) -gt "$window" ]; then count=0; ws="$now"; fi
  count=$((count + 1))

  local cooled=0; [ $((now - la)) -ge "$cooldown" ] && cooled=1
  if [ "$cooled" -eq 1 ] && { [ "$targeted" = "1" ] || [ "$count" -ge "$threshold" ]; }; then
    la="$now"
    local tag="REPEATED DEAUTH FLOOD"; [ "$targeted" = "1" ] && tag="TARGETED DEAUTH (watched MAC)"
    local when; when="$(date -d "@$now" 2>/dev/null || echo "epoch $now")"
    alert_fire "$tag
Attacker: ${src:-?}
AP/BSSID: ${ap:-?}
Client:   ${cli:-?}
Hits:     ${count} in <=${window}s
Time:     ${when}"
  fi

  state_upsert_row "$state_file" "$key" "$count" "$ws" "$la" "$now"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash defcon-defense/tests/test_sentry.sh`
Expected: all `ok:`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add defcon-defense/lib/pager_alert_lib.sh defcon-defense/tests/test_sentry.sh
git commit -m "feat(pager): add deauth repeat-offense engine"
```

---

### Task 5: `defcon_sentry` handler wrapper + integration test

**Files:**
- Create: `defcon-defense/src/deauth_flood_detected/defcon_sentry/payload.sh`
- Create: `defcon-defense/src/deauth_flood_detected/defcon_sentry/README.md`
- Test: `defcon-defense/tests/test_sentry_payload.sh`

**Interfaces:**
- Consumes: `sentry_process_event` via a sibling `pager_alert_lib.sh` (placed there by `build.sh`; for this test we symlink/copy the lib next to the payload).
- Produces: an armed on-device handler directory. `payload.sh` sets the config block then sources `./pager_alert_lib.sh` and calls `sentry_process_event`.

- [ ] **Step 1: Write the failing test**

Create `defcon-defense/tests/test_sentry_payload.sh`:

```bash
#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

PDIR="$ROOT/src/deauth_flood_detected/defcon_sentry"
# syntax
bash -n "$PDIR/payload.sh"; assert_rc "$?" "0" "payload.sh passes bash -n"

# integration: run payload.sh with lib beside it, stubs on PATH via a wrapper
TMP="$(mktemp -d)"; export REC="$TMP/rec"; : > "$REC"; export STATE_DIR="$TMP/state"
cp "$ROOT/lib/pager_alert_lib.sh" "$PDIR/pager_alert_lib.sh"   # build.sh does this on real deploy
BIN="$TMP/bin"; mkdir -p "$BIN"
for c in ALERT RINGTONE VIBRATE LED LOG; do
  printf '#!/bin/bash\nprintf "%s\\t%%s\\n" "$*" >> "%s"\n' "$c" "$REC" > "$BIN/$c"
  chmod +x "$BIN/$c"
done
run() { NOW_OVERRIDE="$1" PATH="$BIN:$PATH" bash "$PDIR/payload.sh"; }

# default config is threshold 3 / window 120 / cooldown 300
export _ALERT_DENIAL_SOURCE_MAC_ADDRESS="AA:BB:CC:00:00:09"
export _ALERT_DENIAL_AP_MAC_ADDRESS="DE:AD:BE:EF:00:09"
run 5000; run 5001; run 5002
assert_eq "$(grep -c '^ALERT' "$REC")" "1" "payload fires once at threshold end-to-end"

rm -f "$PDIR/pager_alert_lib.sh"   # keep source dir clean (lib is build-injected)
exit $FAIL
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash defcon-defense/tests/test_sentry_payload.sh`
Expected: FAIL — `payload.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `defcon-defense/src/deauth_flood_detected/defcon_sentry/payload.sh`:

```bash
#!/bin/bash
# Title: DEF CON Sentry - Repeat-Offense Deauth Alert
# Description: Warns loudly only when the SAME attacker sustains a deauth/disassoc flood.
# Author: Henry Hu
# Version: 1.0
# Category: Alerts
#
# Fires on the deauth_flood_detected event. Alerts when one offender
# (keyed per KEY_MODE) crosses REPEAT_THRESHOLD events within WINDOW_SECONDS,
# then stays quiet for COOLDOWN_SECONDS. A flood touching any WATCH_MACS entry
# alerts immediately. Every event is logged to STATE_DIR/events.log.

# ---- CONFIG (tune these) ----
REPEAT_THRESHOLD=3                        # same-offense hits to warn
WINDOW_SECONDS=120                        # counting window
COOLDOWN_SECONDS=300                      # silence after a warning (per offender)
KEY_MODE="source_ap"                      # source | source_ap | source_client
WATCH_MACS=""                             # your MACs, comma-separated -> instant warn
RINGTONE_NAME="warning"
LED_STATE="ATTACK"
VIBRATE_PATTERN="300 100 300 100 300"
# STATE_DIR alone honors an inherited env value (used by the integration test);
# on device it's unset, so this resolves to the default path below.
STATE_DIR="${STATE_DIR:-/root/loot/defcon_sentry}"
# ------------------------------

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/pager_alert_lib.sh"

sentry_process_event
```

Create `defcon-defense/src/deauth_flood_detected/defcon_sentry/README.md`:

```markdown
# DEF CON Sentry — Repeat-Offense Deauth Alert

Auto-fires on `deauth_flood_detected`. Instead of buzzing on every frame, it
warns **only when the same attacker keeps flooding**.

## Tuning (edit the CONFIG block in `payload.sh`)
- `REPEAT_THRESHOLD` (default 3) — hits from one offender before warning.
- `WINDOW_SECONDS` (default 120) — window those hits must fall within.
- `COOLDOWN_SECONDS` (default 300) — quiet time after a warning for that offender.
- `KEY_MODE` — `source` (attacker MAC), `source_ap` (attacker+AP, default),
  `source_client` (attacker+victim).
- `WATCH_MACS` — comma-separated MACs that are *yours*; a flood touching one
  warns instantly, bypassing the threshold.

## Output
- `STATE_DIR/events.log` — every deauth event, even when silent.
- `STATE_DIR/deauth_state.csv` — per-offender counters.

## Arming
Ensure this directory is named `defcon_sentry` (no `DISABLED.` prefix), or
enable it in the Pager's Alerts menu. Requires PineAP recon/listening active.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash defcon-defense/tests/test_sentry_payload.sh`
Expected: all `ok:`, exit 0. (The test removes the injected lib copy at the end.)

- [ ] **Step 5: Commit**

```bash
git add defcon-defense/src/deauth_flood_detected/defcon_sentry/ defcon-defense/tests/test_sentry_payload.sh
git commit -m "feat(pager): add defcon_sentry handler + integration test"
```

---

### Task 6: `honeypot_process_event` + `defcon_honeypot` handler

**Files:**
- Modify: `defcon-defense/lib/pager_alert_lib.sh` (append)
- Create: `defcon-defense/src/pineapple_client_connected/defcon_honeypot/payload.sh`
- Create: `defcon-defense/src/pineapple_client_connected/defcon_honeypot/README.md`
- Test: `defcon-defense/tests/test_honeypot.sh`

**Interfaces:**
- Consumes: `now_epoch`, `sanitize_mac`, `is_randomized_mac`, state functions, `with_lock`, `alert_fire`.
- Produces: `honeypot_process_event` → reads `_ALERT_CLIENT_CONNECTED_{CLIENT,AP}_MAC_ADDRESS` and `_ALERT_CLIENT_CONNECTED_SSID`; appends to `$STATE_DIR/honeypot.csv` (`ts,client,ap,ssid,randomized`); warns via `alert_fire` on the first sighting of a client MAC and again only after `COOLDOWN_SECONDS`. Helper `_honeypot_update` runs the locked section. Always returns 0.

- [ ] **Step 1: Write the failing test**

Create `defcon-defense/tests/test_honeypot.sh`:

```bash
#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

setup() {
  TMP="$(mktemp -d)"; export REC="$TMP/rec"; : > "$REC"; export STATE_DIR="$TMP/state"
  . "$HERE/stubs.sh"; . "$ROOT/lib/pager_alert_lib.sh"
  COOLDOWN_SECONDS=600; RINGTONE_NAME="alert"; LED_STATE="SPECIAL"; VIBRATE_PATTERN="1"
  unset _ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS _ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS \
        _ALERT_CLIENT_CONNECTED_SSID
}
alerts() { grep -c '^ALERT' "$REC" 2>/dev/null || true; }
fire() { NOW_OVERRIDE="$1" honeypot_process_event; }

# First connect from a client -> alert; reconnect within cooldown -> silent
setup
export _ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS="AA:BB:CC:11:22:33"
export _ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS="00:DE:CO:00:00:01"
export _ALERT_CLIENT_CONNECTED_SSID="pineapple_decoy"
fire 1000
assert_eq "$(alerts)" "1" "first connect warns"
fire 1100
assert_eq "$(alerts)" "1" "reconnect within cooldown silent"
fire 1700
assert_eq "$(alerts)" "2" "reconnect after cooldown warns again"

# Randomized MAC flagged in honeypot.csv (nibble A => randomized)
setup
export _ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS="DA:11:22:33:44:55"
export _ALERT_CLIENT_CONNECTED_SSID="pineapple_decoy"
fire 2000
assert_eq "$(awk -F, 'NR==1{print $5}' "$STATE_DIR/honeypot.csv")" "yes" "randomized MAC flagged"

# Non-randomized MAC not flagged (nibble 8)
setup
export _ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS="A8:11:22:33:44:55"
fire 3000
assert_eq "$(awk -F, 'NR==1{print $5}' "$STATE_DIR/honeypot.csv")" "no" "stable MAC not flagged"

# Empty client MAC -> no crash, no alert
setup
fire 4000
assert_eq "$(alerts)" "0" "empty client silent"

# payload syntax
bash -n "$ROOT/src/pineapple_client_connected/defcon_honeypot/payload.sh"
assert_rc "$?" "0" "honeypot payload passes bash -n"

exit $FAIL
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash defcon-defense/tests/test_honeypot.sh`
Expected: FAIL — `honeypot_process_event: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `defcon-defense/lib/pager_alert_lib.sh`:

```bash
# --- honeypot connect warning (dedup per client MAC) ---

honeypot_process_event() {
  local now; now="$(now_epoch)"
  local state_dir="${STATE_DIR:-/root/loot/defcon_sentry}"
  local state_file="$state_dir/honeypot_state.csv"
  local lock="$state_dir/.hp.lock"
  mkdir -p "$state_dir"

  local cli ap ssid
  cli="$(sanitize_mac "${_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS:-}")"
  ap="$(sanitize_mac "${_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS:-}")"
  ssid="${_ALERT_CLIENT_CONNECTED_SSID:-}"
  [ -n "$cli" ] || return 0

  local rnd=no; is_randomized_mac "$cli" && rnd=yes
  printf '%s,%s,%s,%s,%s\n' "$now" "$cli" "$ap" "$ssid" "$rnd" >> "$state_dir/honeypot.csv"

  with_lock "$lock" _honeypot_update "$now" "$state_file" "$cli" "$ap" "$ssid" "$rnd"
  return 0
}

_honeypot_update() { # now state_file cli ap ssid rnd
  local now="$1" state_file="$2" cli="$3" ap="$4" ssid="$5" rnd="$6"
  local cooldown="${COOLDOWN_SECONDS:-600}"
  state_prune "$state_file" 86400 "$now"

  local row count la
  row="$(state_read_row "$state_file" "$cli")"
  if [ -n "$row" ]; then
    count="$(printf '%s' "$row" | cut -d, -f2)"
    la="$(printf '%s' "$row" | cut -d, -f4)"
  else
    count=0; la=0
  fi
  count=$((count + 1))

  if [ "$count" -eq 1 ] || [ $((now - la)) -ge "$cooldown" ]; then
    la="$now"
    local note=""; [ "$rnd" = "yes" ] && note="
(randomized MAC)"
    alert_fire "HONEYPOT: client joined decoy AP
Client: ${cli}${note}
SSID:   ${ssid:-?}
AP:     ${ap:-?}
Seen:   ${count}x"
  fi
  state_upsert_row "$state_file" "$cli" "$count" "$now" "$la" "$now"
}
```

Create `defcon-defense/src/pineapple_client_connected/defcon_honeypot/payload.sh`:

```bash
#!/bin/bash
# Title: DEF CON Honeypot - Decoy AP Connect Alert
# Description: Warns when a client joins your intentional decoy AP; dedups reconnects.
# Author: Henry Hu
# Version: 1.0
# Category: Alerts
#
# Fires on the pineapple_client_connected event. Warns on the FIRST sighting of
# each client MAC (that connection IS the signal), then stays quiet for
# COOLDOWN_SECONDS so reassociations don't spam. Randomized MACs are flagged.
# Every connect is logged to STATE_DIR/honeypot.csv.

# ---- CONFIG (tune these) ----
COOLDOWN_SECONDS=600                      # per-client quiet time after a warning
RINGTONE_NAME="alert"
LED_STATE="SPECIAL"
VIBRATE_PATTERN="200 100 200"
# STATE_DIR alone honors an inherited env value (for parity with defcon_sentry
# and test overrides); on device it's unset, resolving to the default below.
STATE_DIR="${STATE_DIR:-/root/loot/defcon_sentry}"
# ------------------------------

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/pager_alert_lib.sh"

honeypot_process_event
```

Create `defcon-defense/src/pineapple_client_connected/defcon_honeypot/README.md`:

```markdown
# DEF CON Honeypot — Decoy AP Connect Alert

Auto-fires on `pineapple_client_connected`. Warns when something joins the
**decoy AP you run on purpose**, so an unexpected connection gets your attention.

## Operator setup (required)
Run an **open** AP in PineAP with a **neutral SSID that does NOT impersonate a
real network** (e.g. `pineapple_decoy`, not a nearby coffee-shop's name).
No karma / association attack — just a plain open AP clients may choose to join.

## Tuning (edit CONFIG in `payload.sh`)
- `COOLDOWN_SECONDS` (default 600) — quiet time per client after a warning.

## Output
- `STATE_DIR/honeypot.csv` — every connect: `ts,client,ap,ssid,randomized`.

## Arming
Name the directory `defcon_honeypot` (no `DISABLED.` prefix) or enable it in the
Alerts menu.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash defcon-defense/tests/test_honeypot.sh`
Expected: all `ok:`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add defcon-defense/lib/pager_alert_lib.sh defcon-defense/src/pineapple_client_connected/ defcon-defense/tests/test_honeypot.sh
git commit -m "feat(pager): add defcon_honeypot handler + dedup logic"
```

---

### Task 7: `build.sh` assembler + `.gitignore` + test runner

**Files:**
- Create: `defcon-defense/build.sh`
- Create: `defcon-defense/.gitignore`
- Create: `defcon-defense/tests/run_tests.sh`
- Test: `defcon-defense/tests/test_build.sh`

**Interfaces:**
- Consumes: curated stock payload directories under `../payloads/library/`, the two custom handler source dirs, and `lib/pager_alert_lib.sh`.
- Produces: `defcon-defense/library/…` device-layout tree; `run_tests.sh` runs all `test_*.sh` and `bash -n` on the whole tree.

- [ ] **Step 1: Write the failing test**

Create `defcon-defense/tests/test_build.sh`:

```bash
#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

bash "$ROOT/build.sh"; assert_rc "$?" "0" "build.sh succeeds"
OUT="$ROOT/library"

for p in \
  alerts/deauth_flood_detected/defcon_sentry/payload.sh \
  alerts/deauth_flood_detected/defcon_sentry/pager_alert_lib.sh \
  alerts/pineapple_client_connected/defcon_honeypot/payload.sh \
  alerts/pineapple_client_connected/defcon_honeypot/pager_alert_lib.sh \
  user/general/PORT_ALERT/payload.sh \
  user/general/ICMP_ALERT/payload.sh \
  user/reconnaissance/find_hackers/payload.sh \
  user/reconnaissance/alien_ap/payload.sh \
  user/reconnaissance/alien_ap/filter.awk \
  user/reconnaissance/SignalFence/payload.sh ; do
  [ -f "$OUT/$p" ]; assert_rc "$?" "0" "built: $p"
done

# no offensive payloads leaked in
[ ! -e "$OUT/user/interception/fenris" ]; assert_rc "$?" "0" "no fenris in output"

# every built payload.sh is syntactically valid
err=0; while IFS= read -r f; do bash -n "$f" || err=1; done < <(find "$OUT" -name '*.sh')
assert_rc "$err" "0" "all built shell scripts pass bash -n"

exit $FAIL
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash defcon-defense/tests/test_build.sh`
Expected: FAIL — `build.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `defcon-defense/build.sh`:

```bash
#!/bin/bash
# Assemble the device-layout library/ tree for USB deploy to the Pager.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUB="$HERE/../payloads/library"
OUT="$HERE/library"
LIB="$HERE/lib/pager_alert_lib.sh"

[ -d "$SUB" ] || { echo "ERROR: submodule library not found at $SUB (run: git submodule update --init)"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/alerts/deauth_flood_detected" \
         "$OUT/alerts/pineapple_client_connected" \
         "$OUT/user/general" "$OUT/user/reconnaissance"

# Custom handlers + shared lib injected beside each payload.sh
cp -R "$HERE/src/deauth_flood_detected/defcon_sentry"           "$OUT/alerts/deauth_flood_detected/"
cp -R "$HERE/src/pineapple_client_connected/defcon_honeypot"    "$OUT/alerts/pineapple_client_connected/"
cp "$LIB" "$OUT/alerts/deauth_flood_detected/defcon_sentry/pager_alert_lib.sh"
cp "$LIB" "$OUT/alerts/pineapple_client_connected/defcon_honeypot/pager_alert_lib.sh"

# Curated stock detectors (whole directories, verbatim)
for d in user/general/PORT_ALERT user/general/ICMP_ALERT \
         user/reconnaissance/find_hackers user/reconnaissance/alien_ap \
         user/reconnaissance/SignalFence ; do
  cp -R "$SUB/$d" "$OUT/$(dirname "$d")/"
done

# Syntax-check the whole output
err=0
while IFS= read -r f; do
  bash -n "$f" || { echo "SYNTAX FAIL: $f"; err=1; }
done < <(find "$OUT" -name '*.sh')
[ "$err" -eq 0 ] && echo "BUILD OK -> $OUT"
exit "$err"
```

Create `defcon-defense/.gitignore`:

```gitignore
# build output — regenerated by build.sh, not source
library/
# injected lib copies in source handler dirs (build-time only)
src/**/pager_alert_lib.sh
```

Create `defcon-defense/tests/run_tests.sh`:

```bash
#!/bin/bash
# Run all host-side tests + full-tree syntax check.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
rc=0
for t in "$HERE"/test_*.sh; do
  echo "=== $(basename "$t") ==="
  bash "$t" || rc=1
done
echo "=== bash -n over src/ + lib/ ==="
while IFS= read -r f; do bash -n "$f" || rc=1; done < <(find "$ROOT/src" "$ROOT/lib" -name '*.sh')
[ "$rc" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$rc"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash defcon-defense/tests/test_build.sh`
Expected: all `ok:`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add defcon-defense/build.sh defcon-defense/.gitignore defcon-defense/tests/run_tests.sh defcon-defense/tests/test_build.sh
git commit -m "feat(pager): add build.sh assembler, gitignore, test runner"
```

---

### Task 8: Operator README + threat-model cheat sheet + final verification

**Files:**
- Create: `defcon-defense/README.md`
- Test: full suite via `defcon-defense/tests/run_tests.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: the operator-facing install/arming/threat-model doc; a green full-suite run.

- [ ] **Step 1: Write the README**

Create `defcon-defense/README.md`:

````markdown
# DEF CON Defensive Loadout — WiFi Pineapple Pager

A **passive, fatigue-resistant** early-warning kit. It detects and warns; it
never transmits attacks against other people. Core idea: **warn loudly only on
a repeated same-offense**, stay quiet on ambient DEF CON noise.

## What's included

| Payload | Type | Warns you when… |
|---|---|---|
| `alerts/deauth_flood_detected/defcon_sentry` | auto (custom) | the **same** attacker sustains a deauth/disassoc flood (3 hits/2 min, 5 min cooldown; watched MACs escalate instantly) |
| `alerts/pineapple_client_connected/defcon_honeypot` | auto (custom) | a client joins **your decoy AP** (first sighting per client, dedup reconnects) |
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
   cd defcon-defense && ./build.sh
   ```
   This writes `defcon-defense/library/`.
2. Copy `defcon-defense/library/*` into the Pager's `/mmc/root/payloads/library/`
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
- **Walking the floor / feeling watched:** launch `find_hackers`, then `alien_ap`
  for a rogue-AP sweep. Add `SignalFence` if you want a proximity tripwire.
- **On a wired/again-connected network you control:** run `PORT_ALERT` /
  `ICMP_ALERT` to catch someone scanning the Pager itself.

## Tuning

Each custom handler has a CONFIG block at the top of its `payload.sh`:
- `defcon_sentry`: `REPEAT_THRESHOLD`, `WINDOW_SECONDS`, `COOLDOWN_SECONDS`,
  `KEY_MODE`, `WATCH_MACS` (put **your** device MACs here for instant targeted
  warnings).
- `defcon_honeypot`: `COOLDOWN_SECONDS`.

Stock detectors: `find_hackers` has `MIN_SPOOFING_COUNT`; `PORT_ALERT` has a SYN
threshold — see each payload's own comments/README.

## Loot / logs (on device)

- `/root/loot/defcon_sentry/events.log` — every deauth event (even when silent).
- `/root/loot/defcon_sentry/deauth_state.csv` — per-offender counters.
- `/root/loot/defcon_sentry/honeypot.csv` — every decoy-AP connect.

## This is not a substitute for opsec

Use a VPN, keep device MAC randomization on, turn radios off when idle, and
don't auto-join open networks. This kit is your **radar**, not your armor.

## Legal / authorized use

Scope is limited to passively monitoring RF you can already hear, your own
device's inbound traffic, and your own decoy AP. Do **not** impersonate real
SSIDs. See the repository's Legal section — Hak5 gear is for authorized auditing
and security analysis only; you are solely responsible for compliance.
````

- [ ] **Step 2: Run the full suite**

Run: `bash defcon-defense/tests/run_tests.sh`
Expected: each `test_*.sh` prints `ok:` lines, final line `ALL TESTS PASSED`, exit 0.

- [ ] **Step 3: Rebuild and confirm output**

Run: `bash defcon-defense/build.sh && find defcon-defense/library -name payload.sh | sort`
Expected: `BUILD OK` then the 7 payload.sh paths (2 custom + 5 stock).

- [ ] **Step 4: Commit**

```bash
git add defcon-defense/README.md
git commit -m "docs(pager): add operator README + threat-model cheat sheet"
```

---

## Self-Review

**1. Spec coverage:**
- Passive/defensive posture + honeypot → Tasks 4–6, README. ✓
- Excluded offensive payloads → Task 7 asserts none leak; README documents. ✓
- `defcon_sentry` repeat-offense engine (threshold/window/cooldown/targeted/log) → Task 4. ✓
- `defcon_honeypot` dedup + randomized-MAC flag + operator SSID guidance → Task 6. ✓
- Curated stock payloads copied verbatim (incl. `alien_ap/filter.awk`) → Task 7. ✓
- `build.sh`, README, tests, `.gitignore` → Tasks 7–8. ✓
- Alert primitives, state files, non-goals, legal → README (Task 8). ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete content. ✓

**3. Type consistency:** Function names/params consistent across tasks — `sentry_process_event`/`_sentry_update`, `honeypot_process_event`/`_honeypot_update`, `state_{read_row,upsert_row,prune}`, `with_lock`, `alert_fire`, `now_epoch`, `sanitize_mac`, `is_randomized_mac`. CSV schema `key,count,window_start,last_alert,last_seen` used uniformly. ✓

No gaps found.

---

## As-built deltas (post-review hardening)

The inline task code above is the plan of record; these refinements were applied
during review and are the true as-built behavior (see git history + the
`.superpowers/sdd/` ledger):

- **Task 2 — `with_lock`:** scoped the `2>/dev/null` to a brace group (a bare
  `exec ... 2>/dev/null` permanently silenced the caller's stderr); warn on
  `flock` timeout instead of silently running unlocked. *(synced above)*
- **Task 3 — `alert_fire`:** `|| true` on each foreground channel so a failing
  channel can't abort under a caller's `set -e`; `local msg="${1:-}"` for `set -u`. *(synced above)*
- **Task 4 — deauth engine:** targeting (`_sentry_targeted`) is computed before
  the degenerate-key guard so a `WATCH_MACS` hit always alerts even when the
  KEY_MODE fields are empty. *(synced above)*
- **Tasks 4 & 6 — alert ordering:** the alert now fires **after** `with_lock`
  releases (via a `SENTRY_PENDING_ALERT`/`HONEYPOT_PENDING_ALERT` global set
  inside the locked update); `state_upsert_row` still runs under the lock. This
  keeps a possibly-blocking on-screen `ALERT` from holding the lock across a
  concurrent hook.
- **Task 5/6 — `payload.sh`:** `STATE_DIR="${STATE_DIR:-…}"` honors an env
  override (test hermeticity) with identical on-device default. *(synced above)*
- **Task 7 — `build.sh`:** explicit `chmod 644` over the output tree for
  umask-independent, deterministic device-convention perms.
- **Tests:** added `test_colocation.sh` (both handlers share one `STATE_DIR`
  safely) and a `honeypot.csv` per-connect line-count assertion.
````
