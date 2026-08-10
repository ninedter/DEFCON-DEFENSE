#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"
TMP="$(mktemp -d)"; export REC="$TMP/rec"; : > "$REC"
. "$HERE/stubs.sh"
. "$ROOT/lib/pager_alert_lib.sh"

LED_STATE="ATTACK"; RINGTONE_NAME="urgent"
alert_fire "hello world"
sleep 0.2   # RINGTONE runs backgrounded

assert_eq "$(grep -c '^ALERT'    "$REC")" "1" "ALERT emitted once"
assert_eq "$(grep -c '^LOG'      "$REC")" "1" "LOG emitted once"
assert_eq "$(grep -c '^LED'      "$REC")" "1" "LED emitted once"
assert_eq "$(grep -c '^RINGTONE' "$REC")" "1" "RINGTONE emitted once"
assert_eq "$(awk -F'\t' '/^RINGTONE/{print $2}' "$REC")" "--vibrate urgent" "RINGTONE plays tone with sync vibrate"
assert_eq "$(awk -F'\t' '/^ALERT/{print $2}' "$REC")" "hello world" "ALERT carries message"
assert_eq "$(awk -F'\t' '/^LED/{print $2}' "$REC")" "ATTACK" "LED uses LED_STATE"

# discreet vibrate-only mode uses VIBRATE (by name), not RINGTONE
: > "$REC"; RINGTONE_VIBRATE_ONLY=1 alert_fire "quiet"; sleep 0.2
assert_eq "$(grep -c '^VIBRATE'  "$REC")" "1" "vibrate-only: VIBRATE emitted"
assert_eq "$(grep -c '^RINGTONE' "$REC")" "0" "vibrate-only: RINGTONE not used"

# alert_fire honors "always return 0" even under caller set -e when a channel fails
LED() { return 1; }                       # force a channel command to fail
( set -e; alert_fire "boom" ); assert_rc "$?" "0" "alert_fire returns 0 under set -e despite failing channel"

exit $FAIL
