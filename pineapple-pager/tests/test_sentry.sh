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
