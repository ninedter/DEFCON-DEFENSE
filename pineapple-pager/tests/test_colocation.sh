#!/bin/bash
# Both defcon_sentry and defcon_honeypot handlers default STATE_DIR to the
# same on-device path (/root/loot/defcon_sentry). Verify that when they
# share a STATE_DIR, each writes its own distinctly-named files without
# colliding with or clobbering the other's state/logs.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

TMP="$(mktemp -d)"; export REC="$TMP/rec"; : > "$REC"
export STATE_DIR="$TMP/state"
. "$HERE/stubs.sh"; . "$ROOT/lib/pager_alert_lib.sh"

# Sentry config
REPEAT_THRESHOLD=3; WINDOW_SECONDS=120; COOLDOWN_SECONDS=300
KEY_MODE="source_ap"; WATCH_MACS=""
RINGTONE_NAME="warning"; LED_STATE="ATTACK"; VIBRATE_PATTERN="1"

# Fire one sentry (deauth) event
export _ALERT_DENIAL_SOURCE_MAC_ADDRESS="AA:BB:CC:00:00:01"
export _ALERT_DENIAL_AP_MAC_ADDRESS="DE:AD:BE:EF:00:01"
NOW_OVERRIDE=1000 sentry_process_event

# Fire one honeypot (client connect) event into the SAME STATE_DIR
export _ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS="11:22:33:44:55:66"
NOW_OVERRIDE=1000 honeypot_process_event

for f in deauth_state.csv events.log honeypot_state.csv honeypot.csv; do
  [ -f "$STATE_DIR/$f" ]; assert_rc "$?" "0" "colocated file exists: $f"
done

# Distinct + no cross-contamination: each file holds only its own handler's data.
assert_eq "$(wc -l < "$STATE_DIR/events.log" | tr -d ' ')" "1" "events.log has only the sentry event"
assert_eq "$(wc -l < "$STATE_DIR/honeypot.csv" | tr -d ' ')" "1" "honeypot.csv has only the honeypot event"

row="$(state_read_row "$STATE_DIR/deauth_state.csv" "AA:BB:CC:00:00:01|DE:AD:BE:EF:00:01")"
[ -n "$row" ]; assert_rc "$?" "0" "sentry key present in deauth_state.csv"
row="$(state_read_row "$STATE_DIR/honeypot_state.csv" "AA:BB:CC:00:00:01|DE:AD:BE:EF:00:01")"
assert_eq "$row" "" "sentry key absent from honeypot_state.csv"

row="$(state_read_row "$STATE_DIR/honeypot_state.csv" "11:22:33:44:55:66")"
[ -n "$row" ]; assert_rc "$?" "0" "honeypot key present in honeypot_state.csv"
row="$(state_read_row "$STATE_DIR/deauth_state.csv" "11:22:33:44:55:66")"
assert_eq "$row" "" "honeypot key absent from deauth_state.csv"

exit $FAIL
