#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"
. "$ROOT/src/user/defcon/DEFCON-DEFENSE/rf_guard_lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/defcon-rf-test.XXXXXX")"
cleanup() { [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT

assert_eq "$(rf_band_for 2412 1)" "2.4GHz" "2412 MHz is 2.4 GHz"
assert_eq "$(rf_band_for 5180 36)" "5GHz" "5180 MHz is 5 GHz"
assert_eq "$(rf_band_for 0 11)" "2.4GHz" "channel fallback detects 2.4 GHz"
assert_eq "$(rf_band_for 0 149)" "5GHz" "channel fallback detects 5 GHz"
assert_eq "$(rf_band_for 5955 1)" "other" "6 GHz stays outside configured monitor bands"

FIXTURE="$TMP/recon.json"
cat > "$FIXTURE" <<'JSON'
[
  {
    "mac": "00:11:22:33:44:55",
    "packets": 10,
    "beacon": [
      {"ssid":"","channel":6,"freq":2437,"signal":-44,"time":99,"count":4},
      {"ssid":"SOC-Operations","channel":6,"freq":2437,"signal":-45,"time":100,"count":4}
    ],
    "response": {
      "1": {"ssid":"SOC-Operations","channel":6,"freq":2437,"signal":-43,"time":101,"count":1}
    }
  },
  {
    "mac": "AA:BB:CC:DD:EE:01",
    "beacon": [{"ssid":"SOC-Operations","channel":36,"freq":5180,"signal":-50,"time":101,"count":2}],
    "response": []
  },
  {
    "mac": "AA:BB:CC:DD:EE:02",
    "beacon": [{"ssid":"Venue Guest","channel":149,"freq":5745,"signal":-62,"time":102,"count":2}],
    "response": []
  },
  {
    "mac": "AA:BB:CC:DD:EE:03",
    "beacon": [{"ssid":"Six GHz","channel":1,"freq":5955,"signal":-40,"time":103,"count":1}],
    "response": []
  }
]
JSON

SNAPSHOT="$TMP/snapshot.tsv"
rf_normalize_json "$FIXTURE" "$SNAPSHOT"; assert_rc "$?" "0" "Recon JSON normalizes"
assert_eq "$(wc -l < "$SNAPSHOT" | tr -d ' ')" "4" "duplicate observations are removed"
assert_eq "$(rf_count_band "$SNAPSHOT" "2.4GHz")" "1" "2.4 GHz BSSID count"
assert_eq "$(rf_count_band "$SNAPSHOT" "5GHz")" "2" "5 GHz BSSID count"
assert_eq "$(awk -F '\t' '$1=="00:11:22:33:44:55" {print $2}' "$SNAPSHOT")" \
  "SOC-Operations" "visible response wins over a hidden beacon for one BSSID"
assert_eq "$(awk -F '\t' '$1=="00:11:22:33:44:55" {print $7}' "$SNAPSHOT")" \
  "10" "live inventory exposes Recon packet activity"

rf_observation_is_actionable 1040 1050 45 1000
assert_rc "$?" "0" "fresh post-launch observation is actionable"
rf_observation_is_actionable 900 1050 45 800
assert_rc "$?" "1" "stale Recon cache is not actionable"
rf_observation_is_actionable 1000 1050 60 1000
assert_rc "$?" "1" "pre-launch cached observation is not replayed"

WATCHED="$TMP/watched.tsv"
rf_watch_upsert "$WATCHED" '00:11:22:33:44:55' 'SOC-Operations' 6 2.4GHz
assert_rc "$?" "0" "watched AP is saved"
assert_eq "$(rf_watch_count "$WATCHED")" "1" "watched AP count"
rf_watch_contains "$WATCHED" '00:11:22:33:44:55'; assert_rc "$?" "0" "watched BSSID is found"
assert_eq "$(rf_watch_classify "$WATCHED" '00:11:22:33:44:55' 'SOC-Operations' 6)" \
  "NONE" "unchanged watched AP stays quiet"
assert_eq "$(rf_watch_classify "$WATCHED" '00:11:22:33:44:55' 'Renamed' 6)" \
  "WATCHED_BSSID_SSID_CHANGE" "watched BSSID SSID change is flagged"
assert_eq "$(rf_watch_classify "$WATCHED" '00:11:22:33:44:55' 'SOC-Operations' 11)" \
  "WATCHED_AP_CHANNEL_CHANGE" "watched AP channel change is flagged"
assert_eq "$(rf_watch_classify "$WATCHED" 'AA:BB:CC:DD:EE:09' 'SOC-Operations' 6)" \
  "WATCHED_SSID_NEW_BSSID" "watched SSID from a new BSSID is flagged"
rf_watch_remove "$WATCHED" '00:11:22:33:44:55'
assert_eq "$(rf_watch_count "$WATCHED")" "0" "watched AP can be removed"

TRUSTED="$TMP/trusted.conf"
cat > "$TRUSTED" <<'EOF'
# SSID|BSSID|channels
SOC-Operations|00:11:22:33:44:55|1,6,11
SOC-Operations|00:11:22:33:44:66|36,40,44,48
EOF
BASELINE="$TMP/baseline.txt"
printf '%s\n' '00:11:22:33:44:55' '00:11:22:33:44:66' > "$BASELINE"

assert_eq "$(rf_classify_observation "$TRUSTED" "$BASELINE" '00:11:22:33:44:55' 'SOC-Operations' 6)" \
  "NONE" "trusted AP on an allowed channel is quiet"
assert_eq "$(rf_classify_observation "$TRUSTED" "$BASELINE" 'AA:BB:CC:DD:EE:01' 'SOC-Operations' 36)" \
  "TRUSTED_SSID_NEW_BSSID" "trusted SSID on unknown BSSID is flagged"
assert_eq "$(rf_classify_observation "$TRUSTED" "$BASELINE" '00:11:22:33:44:55' 'Renamed Network' 6)" \
  "TRUSTED_BSSID_SSID_CHANGE" "trusted BSSID changing SSID is flagged"
assert_eq "$(rf_classify_observation "$TRUSTED" "$BASELINE" '00:11:22:33:44:66' 'SOC-Operations' 149)" \
  "TRUSTED_AP_CHANNEL_CHANGE" "trusted AP on unexpected channel is flagged"
assert_eq "$(rf_classify_observation "$TRUSTED" "$BASELINE" 'AA:BB:CC:DD:EE:02' 'Venue Guest' 149)" \
  "NEW_BSSID" "non-baseline BSSID is flagged"

DEAUTH="$TMP/deauth-events.log"
printf '%s,src=%s,dst=,ap=%s,cli=\n' 1000 '12:34:56:78:9A:BC' 'AA:BB:CC:DD:EE:02' > "$DEAUTH"
THREATS="$TMP/threats.tsv"
rf_build_threat_snapshot "$WATCHED" "$TRUSTED" "$BASELINE" "$SNAPSHOT" "$DEAUTH" 1050 "$THREATS"
assert_rc "$?" "0" "single-pass threat snapshot builds"
assert_eq "$(awk -F '\t' '$1=="AA:BB:CC:DD:EE:01" {print $7}' "$THREATS")" \
  "TRUSTED_SSID_NEW_BSSID" "threat snapshot includes trusted identity anomaly"
assert_eq "$(awk -F '\t' '$1=="AA:BB:CC:DD:EE:02" {print $7 ":" $8 ":" $9}' "$THREATS")" \
  "DEAUTH_ACTIVITY:1:red" "threat snapshot correlates recent deauth activity in red"
assert_eq "$(awk -F '\t' '$1=="AA:BB:CC:DD:EE:03" {count++} END {print count+0}' "$THREATS")" \
  "0" "threat snapshot excludes non-2.4/5 GHz observations"
assert_eq "$(rf_ui_metrics "$SNAPSHOT" "$THREATS" "$WATCHED")" "1|2|2|0" \
  "one metrics pass counts both bands, threats, and watched APs"

FRESH_THREATS="$TMP/fresh-threats.tsv"
FRESH_SNAPSHOT="$TMP/fresh-snapshot.tsv"
awk -F '\t' -v OFS='\t' '$1=="AA:BB:CC:DD:EE:01" {$6=1040} {print}' \
  "$SNAPSHOT" > "$FRESH_SNAPSHOT"
rf_build_threat_snapshot "$WATCHED" "$TRUSTED" "$BASELINE" "$FRESH_SNAPSHOT" "$DEAUTH" 1050 \
  "$FRESH_THREATS" 45 1000
assert_eq "$(wc -l < "$FRESH_THREATS" | tr -d ' ')" "1" \
  "threat snapshot excludes stale and pre-launch Recon rows"

STATE="$TMP/state.psv"
assert_eq "$(rf_state_should_alert "$STATE" NEW_BSSID AA:BB:CC:DD:EE:02 100 2 60 300)" "0" \
  "first new-BSSID sighting stays quiet"
assert_eq "$(rf_state_should_alert "$STATE" NEW_BSSID AA:BB:CC:DD:EE:02 115 2 60 300)" "1" \
  "second sighting inside window alerts"
assert_eq "$(rf_state_should_alert "$STATE" NEW_BSSID AA:BB:CC:DD:EE:02 130 2 60 300)" "0" \
  "cooldown suppresses repeat alert"
assert_eq "$(rf_state_should_alert "$STATE" NEW_BSSID AA:BB:CC:DD:EE:02 500 2 60 300)" "0" \
  "stale observation window resets count"
assert_eq "$(rf_state_should_alert "$STATE" NEW_BSSID AA:BB:CC:DD:EE:02 515 2 60 300)" "1" \
  "new repeat sequence alerts after cooldown"

rf_signal_meets_threshold -72 -72; assert_rc "$?" "0" "threshold signal is included"
rf_signal_meets_threshold -73 -72; assert_rc "$?" "1" "weak new BSSID is suppressed"
rf_signal_meets_threshold '?' -72; assert_rc "$?" "0" "unknown signal is retained for safety"

FINDINGS="$TMP/findings.tsv"
rf_append_finding "$FINDINGS" 100 NEW_BSSID AA:BB:CC:DD:EE:02 $'Bad\tSSID' 149 5745 -62 5GHz
assert_eq "$(wc -l < "$FINDINGS" | tr -d ' ')" "2" "finding writer adds header and record"
assert_eq "$(awk -F '\t' 'NR==2 {print NF}' "$FINDINGS")" "8" "finding stays valid TSV"

exit "$FAIL"
