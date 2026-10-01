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
PROMPT()      { printf 'PROMPT\t%s\n' "$*" >> "$REC"; }

DEFCON_DEFENSE_SOURCE_ONLY=1
DEFCON_DEFENSE_LOOT_DIR="$TMP/loot"
DEFCON_DEFENSE_PCAP_DIR="$TMP/pcap"
DEFCON_DEFENSE_INSTALL_DIR="$ROOT/src/user/general/DEFCON_DEFENSE"
export DEFCON_DEFENSE_SOURCE_ONLY DEFCON_DEFENSE_LOOT_DIR DEFCON_DEFENSE_PCAP_DIR DEFCON_DEFENSE_INSTALL_DIR
. "$ROOT/src/user/general/DEFCON_DEFENSE/payload.sh"

# Pager 24.10.1 does not reliably support `pgrep -x`. The exact pidof path
# must report the firmware UI state without falling back to fuzzy matching.
(pidof() { [ "$1" = "pineapple" ]; }; pager_firmware_ui_running)
assert_rc "$?" "0" "firmware UI helper accepts the Pager pidof match"
(pidof() { return 1; }; pager_firmware_ui_running)
assert_rc "$?" "1" "firmware UI helper rejects an absent Pager process"

# Synthetic fixtures below use small deterministic epochs. Disable runtime
# freshness gates for the existing alert-flow assertions; dedicated guard
# tests exercise stale-cache and restart replay behavior.
RECON_OBSERVATION_MAX_AGE=0
MONITOR_SESSION_EPOCH=0

assert_eq "$DIR" "$DEFCON_DEFENSE_INSTALL_DIR" "unified payload prefers stable installed directory"
assert_eq "$(signal_indicator -45)" "green|EXCELLENT|[##########]" \
  "live status maps excellent signal strength"
assert_eq "$(signal_indicator -75)" "yellow|FAIR|[####------]" \
  "live status maps fair signal strength"
assert_eq "$(threat_label_for TRUSTED_SSID_NEW_BSSID 0)" "POSSIBLE EVIL TWIN / NEW BSSID" \
  "threat page gives identity anomalies a readable label"
assert_eq "$(threat_label_for NONE 4)" "DEAUTH/DISASSOC: 4 events in 2 min" \
  "threat page labels active deauth traffic"

UI_HTTP_TOKEN_FILE="$TMP/ui-http-token"
UI_HTTP_TOKEN=""
ensure_ui_http_token
token_shape_rc=1
[ "$(wc -c < "$UI_HTTP_TOKEN_FILE" | tr -d ' ')" = "33" ] && \
  grep -Eq '^[0-9a-f]{32}$' "$UI_HTTP_TOKEN_FILE" && token_shape_rc=0
assert_rc "$token_shape_rc" "0" "Virtual Pager access token is random-looking and newline terminated"
assert_eq "$(ls -l "$UI_HTTP_TOKEN_FILE" | cut -c1-10)" "-rw-------" \
  "Virtual Pager access token is owner-readable only"

# Foreground UI refresh and the background monitor may read Recon at the same
# time. Their staging paths must not collide even though Bash keeps $$ stable in
# subshells.
_pineap() { sleep 0.1; printf '[]\n'; }
rf_normalize_json() { sleep 0.1; : > "$2"; }
capture_snapshot 1 & capture_one=$!
capture_snapshot 1 & capture_two=$!
wait "$capture_one"; capture_one_rc=$?
wait "$capture_two"; capture_two_rc=$?
assert_rc "$capture_one_rc" "0" "foreground Recon refresh completes during concurrent refresh"
assert_rc "$capture_two_rc" "0" "background Recon refresh completes without temp-file collision"

_pineap() { sleep 2; printf '[]\n'; }
RECON_COMMAND_TIMEOUT=0.1
capture_recon_json "$TMP/timed-recon.json"; timed_recon_rc=$?
assert_rc "$timed_recon_rc" "124" "stalled PineAP Recon is terminated by the bounded watchdog"
[ ! -e "$TMP/timed-recon.json.timeout" ]; assert_rc "$?" "0" "Recon timeout marker is cleaned after recovery"
RECON_COMMAND_TIMEOUT=8

# Backend and action workers are Bash subshells, so $$ alone is not a unique
# atomic-state filename. Concurrent writes must leave one complete state and no
# shared staging file behind.
(
  rf_count_band() { echo 0; }
  rf_build_threat_snapshot() { : > "$6"; }
  rf_watch_count() { echo 0; }
  pcap_evidence_import_existing() { return 0; }
  write_custom_ui_state ACTIVE 100 0 & state_one=$!
  write_custom_ui_state DEGRADED 90 1 & state_two=$!
  wait "$state_one"; state_one_rc=$?
  wait "$state_two"; state_two_rc=$?
  assert_rc "$state_one_rc" "0" "monitor worker state write completes during action write"
  assert_rc "$state_two_rc" "0" "action worker state write completes without temp-file collision"
  assert_eq "$(awk -F= '$1=="version" {print $2}' "$UI_STATE")" "4" "concurrent state writes leave a complete schema"
  state_temp_count="$(find "$LOOT_DIR" -name 'ui_state.psv.tmp.*' | wc -l | tr -d ' ')"
  assert_eq "$state_temp_count" "0" "concurrent state writes leave no shared staging file"
)

# The selected general-screen design keeps monitoring, threats, and PCAP
# evidence in the first three native list rows.
GENERAL_REC="$TMP/general-screen"
: > "$GENERAL_REC"
(
set_recon_bands() { return 0; }
start_background_monitor() { BACKGROUND_MONITOR_PID=12345; }
background_monitor_status() { echo "ACTIVE"; }
drain_button_queue() { return 0; }
load_active_threats() {
  AP_COUNT=54
  THREAT_COLORS=()
  THREAT_COUNT=0
  return 0
}
pcap_evidence_count() { echo 3; }
pcap_evidence_state_status() { echo "SAVED"; }
rf_watch_count() { echo 2; }
LIST_PICKER() {
  printf '%s\n' "$@" > "$GENERAL_REC"
  echo "Exit DEFCON Defense"
}
general_screen
)
assert_eq "$(sed -n '2p' "$GENERAL_REC")" "Live RF | ACTIVE | 54 AP" \
  "general screen leads with live monitoring state"
assert_eq "$(sed -n '3p' "$GENERAL_REC")" "Threat Details | CLEAR" \
  "general screen places threat status second"
assert_eq "$(sed -n '4p' "$GENERAL_REC")" "PCAP Evidence | 3 saved" \
  "general screen places evidence browsing third"

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

AUTO_PCAP_REC="$TMP/auto-pcap"
: > "$AUTO_PCAP_REC"
pcap_evidence_auto_start() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$AUTO_PCAP_REC"
  echo "CAPTURING|test-id|$DEFCON_DEFENSE_PCAP_DIR/test.pcap|$(date +%s)"
}

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
assert_eq "$(awk -F '\t' 'NR==1 {print $1}' "$AUTO_PCAP_REC")" "TRUSTED_SSID_NEW_BSSID" \
  "confirmed identity anomaly starts automatic PCAP evidence capture"
assert_eq "$(awk -F '\t' 'NR==1 {print $2}' "$AUTO_PCAP_REC")" "HIGH" \
  "automatic identity capture is restricted to high-severity findings"

# Digest verification is explicit so large captures never block the general
# screen or evidence import.
VERIFY_PCAP="$DEFCON_DEFENSE_PCAP_DIR/verify-on-demand.pcap"
printf 'verify-this-capture\n' > "$VERIFY_PCAP"
pcap_evidence_index_init
printf '1\tverify-id\tMANUAL_FOCUS\tINFO\tSOC\t00:11:22:33:44:55\t5GHz\t44\t-55\t5\t20\tpending\tSAVED\tmanual\t%s\n' \
  "$VERIFY_PCAP" >> "$PCAP_EVIDENCE_INDEX"
PCAP_IDS=("verify-id"); PCAP_PATHS=("$VERIFY_PCAP"); PCAP_HASHES=("pending")
verify_pcap_hash 0
verified_digest="$(awk -F '\t' '$2=="verify-id" {print $12}' "$PCAP_EVIDENCE_INDEX")"
[ "$verified_digest" != "pending" ] && [ "${#verified_digest}" -eq 64 ]; \
  assert_rc "$?" "0" "evidence browser computes SHA-256 only when requested"

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

# The native UI action queue can add an AP selected from observed Recon traffic
# and can remove an entry from the user's saved watch list.
(
write_custom_ui_state() { return 0; }
printf '%s\n' 'WATCH|ADD|Observed-AP|AA:BB:CC:DD:EE:77|5GHz|44|-57' > "$UI_ACTION"
process_custom_ui_action
assert_rc "$?" "0" "native observed-AP selection action is processed"
rf_watch_contains "$WATCHED_APS" 'AA:BB:CC:DD:EE:77'
assert_rc "$?" "0" "observed AP selection is saved in the user watch list"

printf '%s\n' 'WATCH|REMOVE|Observed-AP|AA:BB:CC:DD:EE:77|5GHz|44|-57' > "$UI_ACTION"
process_custom_ui_action
assert_rc "$?" "0" "native saved-list removal action is processed"
if rf_watch_contains "$WATCHED_APS" 'AA:BB:CC:DD:EE:77'; then removed_rc=1; else removed_rc=0; fi
assert_rc "$removed_rc" "0" "saved AP can be removed from the user watch list"
)

# The fourth custom-UI option clears the current alert/evidence session while
# preserving monitoring configuration for the next session.
printf 'finding\n' > "$FINDINGS"
printf 'alert-state\n' > "$ALERT_STATE"
printf 'threat\n' > "$LOOT_DIR/latest_threats.tsv"
printf 'recon\n' > "$RECON_JSON"
printf 'deauth\n' > "$DEAUTH_EVENTS"
printf 'baseline\n' > "$BASELINE"
watch_before="$(cat "$WATCHED_APS")"
trusted_before="$(cat "$TRUSTED_APS")"
printf 'session-pcap\n' > "$PCAP_DIR/session-clear-test.pcap"
printf 'CLEAR_SESSION\n' > "$UI_ACTION"
process_custom_ui_action

for cleared in "$FINDINGS" "$ALERT_STATE" "$LOOT_DIR/latest_threats.tsv" \
  "$SNAPSHOT" "$RECON_JSON" "$DEAUTH_EVENTS" "$PCAP_DIR/session-clear-test.pcap"; do
  [ ! -e "$cleared" ]; assert_rc "$?" "0" "clear-session removes $(basename "$cleared")"
done
assert_eq "$(pcap_evidence_count)" "0" "clear-session resets captured PCAP evidence"
assert_eq "$(cat "$WATCHED_APS")" "$watch_before" "clear-session preserves monitored networks"
assert_eq "$(cat "$TRUSTED_APS")" "$trusted_before" "clear-session preserves trusted rules"
assert_eq "$(cat "$BASELINE")" "baseline" "clear-session preserves the reviewed baseline"

exit "$FAIL"
