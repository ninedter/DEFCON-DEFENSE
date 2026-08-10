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
assert_eq "$(wc -l < "$STATE_DIR/honeypot.csv" | tr -d ' ')" "3" "honeypot.csv logs every connect incl deduped"

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
