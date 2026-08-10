#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/defcon-unified-test.XXXXXX")"
cleanup() { [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT
REC="$TMP/recorder.log"
: > "$REC"

mkdir -p "$TMP/runtime"
cp "$ROOT/src/user/general/DEFCON_DEFENSE/payload.sh" "$TMP/runtime/payload.sh"
DEFCON_DEFENSE_SOURCE_ONLY=1 \
DEFCON_DEFENSE_LOOT_DIR="$TMP/runtime-loot" \
DEFCON_DEFENSE_PCAP_DIR="$TMP/runtime-pcap" \
DEFCON_DEFENSE_INSTALL_DIR="$ROOT/src/user/general/DEFCON_DEFENSE" \
  bash "$TMP/runtime/payload.sh"
assert_rc "$?" "0" "temporary runner resolves support files from stable installed directory"

ALERT()       { printf 'ALERT\t%s\n' "$*" >> "$REC"; }
RINGTONE()    { printf 'RINGTONE\t%s\n' "$*" >> "$REC"; }
LED()         { printf 'LED\t%s\n' "$*" >> "$REC"; }
LOG()         { printf 'LOG\t%s\n' "$*" >> "$REC"; }
ERROR_DIALOG(){ printf 'ERROR\t%s\n' "$*" >> "$REC"; }

DEFCON_DEFENSE_SOURCE_ONLY=1
DEFCON_DEFENSE_LOOT_DIR="$TMP/loot"
DEFCON_DEFENSE_PCAP_DIR="$TMP/pcap"
DEFCON_DEFENSE_INSTALL_DIR="$ROOT/src/user/general/DEFCON_DEFENSE"
export DEFCON_DEFENSE_SOURCE_ONLY DEFCON_DEFENSE_LOOT_DIR DEFCON_DEFENSE_PCAP_DIR DEFCON_DEFENSE_INSTALL_DIR
. "$ROOT/src/user/general/DEFCON_DEFENSE/payload.sh"

assert_eq "$DIR" "$DEFCON_DEFENSE_INSTALL_DIR" "unified payload prefers stable installed directory"
assert_eq "$(signal_indicator -45)" "green|EXCELLENT|[##########]" \
  "live status maps excellent signal strength"
assert_eq "$(signal_indicator -75)" "yellow|FAIR|[####------]" \
  "live status maps fair signal strength"
assert_eq "$(threat_label_for TRUSTED_SSID_NEW_BSSID 0)" "POSSIBLE EVIL TWIN / NEW BSSID" \
  "threat page gives identity anomalies a readable label"
assert_eq "$(threat_label_for NONE 4)" "DEAUTH/DISASSOC: 4 events in 2 min" \
  "threat page labels active deauth traffic"

# Threat Activity Live must continue refreshing and render malicious rows red.
: > "$REC"
DASH_WAIT_FILE="$TMP/dashboard-waits"
printf '0\n' > "$DASH_WAIT_FILE"
set_recon_bands() { return 0; }
drain_button_queue() { return 0; }
load_active_threats() {
  THREAT_BSSIDS=('00:11:22:33:44:55')
  THREAT_SSIDS=('SOC-Operations')
  THREAT_CHANNELS=('6')
  THREAT_BANDS=('2.4GHz')
  THREAT_SIGNALS=('-48')
  THREAT_PACKETS=('900')
  THREAT_REASONS=('DEAUTH/DISASSOC: 4 events in 2 min')
  THREAT_COLORS=('red')
  THREAT_COUNT=1
  DASH_LOADS=$((DASH_LOADS + 1))
  return 0
}
wait_for_input_or_timeout() {
  local n
  n="$(cat "$DASH_WAIT_FILE")"; n=$((n + 1)); printf '%s\n' "$n" > "$DASH_WAIT_FILE"
  [ "$n" -ge 4 ] && printf 'B'
}
DASH_LOADS=0
threat_activity_dashboard
assert_eq "$DASH_LOADS" "4" "Threat Activity Live continues beyond three refreshes"
red_live_rows="$(awk -F '\t' '$1=="LOG" && $2 ~ /^red MALICIOUS TRAFFIC LIVE/ {count++} END {print count+0}' "$REC")"
assert_eq "$red_live_rows" "4" "Threat Activity Live renders every malicious refresh red"

DEAUTH_EVENTS="$TMP/deauth-events.log"
DEAUTH_NOW="$(date +%s)"
printf '%s,src=%s,dst=%s,ap=%s,cli=%s\n' "$DEAUTH_NOW" \
  'AA:AA:AA:AA:AA:AA' '' '00:11:22:33:44:55' '' > "$DEAUTH_EVENTS"
assert_eq "$(recent_deauth_count '00:11:22:33:44:55' 120)" "1" \
  "live status correlates recent deauth traffic to the selected AP"
assert_eq "$(recent_deauth_count '00:11:22:33:44:66' 120)" "0" \
  "unrelated AP does not inherit a deauth threat indication"

SNAPSHOT="$LOOT_DIR/latest_snapshot.tsv"
BASELINE="$LOOT_DIR/baseline_bssids.txt"
FINDINGS="$LOOT_DIR/findings.tsv"
ALERT_STATE="$LOOT_DIR/alert_state.psv"
WATCHED_APS="$LOOT_DIR/watched_aps.tsv"
TRUSTED_APS="$TMP/trusted_aps.conf"
mkdir -p "$LOOT_DIR"
printf '%s\n' 'SOC-Operations|00:11:22:33:44:55|1,6,11' > "$TRUSTED_APS"
printf '%s\n' '00:11:22:33:44:55' > "$BASELINE"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  'AA:BB:CC:DD:EE:01' 'SOC-Operations' '36' '5180' '-50' '100' '2' '5GHz' > "$SNAPSHOT"

analyze_snapshot
wait

assert_eq "$(awk -F '\t' '$1=="ALERT" {count++} END {print count+0}' "$REC")" "1" \
  "unified payload alerts on trusted-SSID impersonation"
assert_eq "$(awk -F '\t' '$1=="RINGTONE" {count++} END {print count+0}' "$REC")" "1" \
  "unified payload triggers ringtone and vibration path"
assert_eq "$(awk -F '\t' 'NR==2 {print $2}' "$FINDINGS")" "TRUSTED_SSID_NEW_BSSID" \
  "unified payload records classified evidence"
assert_eq "$(awk -F '\t' 'NR==2 {print $3}' "$FINDINGS")" "AA:BB:CC:DD:EE:01" \
  "unified payload records suspect BSSID"

# Operators can select a network from live Recon and monitor it without ever
# creating a venue-wide baseline.
: > "$REC"
rm -f "$BASELINE" "$FINDINGS" "$ALERT_STATE"
: > "$TRUSTED_APS"
rf_watch_upsert "$WATCHED_APS" '00:11:22:33:44:55' 'Selected-Network' 6 2.4GHz
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  'AA:BB:CC:DD:EE:09' 'Selected-Network' '6' '2437' '-50' '200' '20' '2.4GHz' > "$SNAPSHOT"

analyze_snapshot
analyze_snapshot
wait

assert_eq "$(awk -F '\t' '$1=="ALERT" {count++} END {print count+0}' "$REC")" "1" \
  "selected-network monitoring alerts without a baseline after repeat confirmation"
assert_eq "$(awk -F '\t' 'NR==2 {print $2}' "$FINDINGS")" "WATCHED_SSID_NEW_BSSID" \
  "baseline-free watched-network evidence is classified"

exit "$FAIL"
