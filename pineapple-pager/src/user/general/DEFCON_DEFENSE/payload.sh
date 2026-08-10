#!/bin/bash
# Title: DEFCON Defense
# Description: Unified passive 2.4/5 GHz monitoring, alerting, evidence, and defensive-tool launcher.
# Author: Henry Hu
# Version: 4.2
# Category: General

PAYLOAD_ROOT="/root/payloads"
# The Pager payload runner may execute payload.sh from a temporary directory,
# so prefer the stable installed payload path for colocated support files.
INSTALLED_DIR="${DEFCON_DEFENSE_INSTALL_DIR:-$PAYLOAD_ROOT/user/general/DEFCON_DEFENSE}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -f "$INSTALLED_DIR/rf_guard_lib.sh" ]; then
  DIR="$INSTALLED_DIR"
elif [ -f "$SOURCE_DIR/rf_guard_lib.sh" ]; then
  DIR="$SOURCE_DIR"
elif [ -f "/mmc/root/payloads/user/general/DEFCON_DEFENSE/rf_guard_lib.sh" ]; then
  DIR="/mmc/root/payloads/user/general/DEFCON_DEFENSE"
else
  DIR="$SOURCE_DIR"
fi
RF_LIB="$DIR/rf_guard_lib.sh"
TRUSTED_APS="$DIR/trusted_aps.conf"
LOOT_DIR="${DEFCON_DEFENSE_LOOT_DIR:-/root/loot/defcon_defense}"
SNAPSHOT="$LOOT_DIR/latest_snapshot.tsv"
RECON_JSON="$LOOT_DIR/latest_recon.json"
BASELINE="$LOOT_DIR/baseline_bssids.txt"
BASELINE_SNAPSHOT="$LOOT_DIR/baseline_snapshot.tsv"
FINDINGS="$LOOT_DIR/findings.tsv"
ALERT_STATE="$LOOT_DIR/alert_state.psv"
WATCHED_APS="$LOOT_DIR/watched_aps.tsv"
PCAP_DIR="${DEFCON_DEFENSE_PCAP_DIR:-/root/loot/pcap}"
DEAUTH_EVENTS="${DEFCON_DEFENSE_DEAUTH_EVENTS:-/root/loot/defcon_sentry/events.log}"
PCAP_LIB="${DEFCON_DEFENSE_PCAP_LIB:-$DIR/pcap_evidence_lib.sh}"
if [ ! -f "$PCAP_LIB" ] && [ -f "$DIR/../../../../lib/pcap_evidence_lib.sh" ]; then
  PCAP_LIB="$DIR/../../../../lib/pcap_evidence_lib.sh"
fi

# Fatigue-resistant defaults for a crowded venue.
MONITOR_INTERVAL=15
NEW_BSSID_THRESHOLD=2
OBSERVATION_WINDOW=60
ALERT_COOLDOWN=300
MIN_NEW_BSSID_SIGNAL=-72
THREAT_LIVE_INTERVAL=5
THREAT_LIVE_MAX_ROWS=3

if [ ! -f "$RF_LIB" ]; then
  ERROR_DIALOG "DEFCON Defense is incomplete:\nmissing rf_guard_lib.sh"
  exit 1
fi
if [ ! -f "$PCAP_LIB" ]; then
  ERROR_DIALOG "DEFCON Defense is incomplete:\nmissing pcap_evidence_lib.sh"
  exit 1
fi
# shellcheck source=/dev/null
. "$RF_LIB"
# shellcheck source=/dev/null
. "$PCAP_LIB"
PCAP_EVIDENCE_DIR="$LOOT_DIR"
PCAP_EVIDENCE_PCAP_DIR="$PCAP_DIR"
PCAP_EVIDENCE_INDEX="$LOOT_DIR/pcap_index.tsv"
PCAP_EVIDENCE_STATE="$LOOT_DIR/pcap_capture.psv"
PCAP_EVIDENCE_DEDUPE="$LOOT_DIR/pcap_dedupe.psv"
PCAP_EVIDENCE_LOCK="$LOOT_DIR/.pcap_capture.lock"
UI_BINARY="${DEFCON_DEFENSE_UI_BINARY:-$DIR/defcon-ui}"
UI_STATE="$LOOT_DIR/ui_state.psv"
UI_ACTION="$LOOT_DIR/ui_action.psv"
UI_MUTE="$LOOT_DIR/ui_muted"
UI_BRIDGE_SOURCE="$DIR/virtual-pager-bridge.js"
UI_SESSION_LOCK="$LOOT_DIR/.ui_session.lock"
pcap_evidence_configure
mkdir -p "$LOOT_DIR" "$PCAP_DIR"

FOCUS_MONITOR_PID=""
FOCUS_PCAP_ACTIVE=0
FOCUS_SIGNAL_FILE=""
FOCUS_CAPTURE_ID=""
BACKGROUND_MONITOR_PID=""
CUSTOM_UI_BACKEND_PID=""
CUSTOM_UI_ACTION_PID=""
CUSTOM_UI_BRIDGE_PID=""
CUSTOM_UI_LOCKED=0
MONITOR_PAUSE_FILE="$LOOT_DIR/.background_monitor_pause"

cleanup_focused_monitor() {
  if [ -n "$FOCUS_MONITOR_PID" ] && kill -0 "$FOCUS_MONITOR_PID" 2>/dev/null; then
    kill "$FOCUS_MONITOR_PID" 2>/dev/null || true
    wait "$FOCUS_MONITOR_PID" 2>/dev/null || true
  fi
  FOCUS_MONITOR_PID=""
  if [ "$FOCUS_PCAP_ACTIVE" = "1" ]; then
    if [ -n "$FOCUS_CAPTURE_ID" ] && type pcap_evidence_finish >/dev/null 2>&1; then
      if ! pcap_evidence_finish "$FOCUS_CAPTURE_ID" >/dev/null 2>&1; then
        type WIFI_PCAP_STOP >/dev/null 2>&1 && WIFI_PCAP_STOP >/dev/null 2>&1 || true
        pcap_evidence_lock_release
      fi
    elif type WIFI_PCAP_STOP >/dev/null 2>&1; then
      WIFI_PCAP_STOP >/dev/null 2>&1 || true
    fi
  fi
  FOCUS_PCAP_ACTIVE=0
  FOCUS_CAPTURE_ID=""
  if type PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1; then
    PINEAPPLE_EXAMINE_RESET >/dev/null 2>&1 || true
  fi
  [ -z "$FOCUS_SIGNAL_FILE" ] || rm -f "$FOCUS_SIGNAL_FILE"
  FOCUS_SIGNAL_FILE=""
  rm -f "$MONITOR_PAUSE_FILE"
}

cleanup_background_monitor() {
  if [ -n "$BACKGROUND_MONITOR_PID" ] && kill -0 "$BACKGROUND_MONITOR_PID" 2>/dev/null; then
    kill "$BACKGROUND_MONITOR_PID" 2>/dev/null || true
    wait "$BACKGROUND_MONITOR_PID" 2>/dev/null || true
  fi
  BACKGROUND_MONITOR_PID=""
  if [ -n "$CUSTOM_UI_BACKEND_PID" ] && kill -0 "$CUSTOM_UI_BACKEND_PID" 2>/dev/null; then
    kill "$CUSTOM_UI_BACKEND_PID" 2>/dev/null || true
    wait "$CUSTOM_UI_BACKEND_PID" 2>/dev/null || true
  fi
  CUSTOM_UI_BACKEND_PID=""
  if [ -n "$CUSTOM_UI_ACTION_PID" ] && kill -0 "$CUSTOM_UI_ACTION_PID" 2>/dev/null; then
    kill "$CUSTOM_UI_ACTION_PID" 2>/dev/null || true
    wait "$CUSTOM_UI_ACTION_PID" 2>/dev/null || true
  fi
  CUSTOM_UI_ACTION_PID=""
  if [ -n "$CUSTOM_UI_BRIDGE_PID" ] && kill -0 "$CUSTOM_UI_BRIDGE_PID" 2>/dev/null; then
    kill "$CUSTOM_UI_BRIDGE_PID" 2>/dev/null || true
    wait "$CUSTOM_UI_BRIDGE_PID" 2>/dev/null || true
  fi
  CUSTOM_UI_BRIDGE_PID=""
  rm -f "$UI_ACTION" "$UI_ACTION.processing"
  rm -f "$MONITOR_PAUSE_FILE"
}

custom_ui_lock_acquire() {
  local owner=""
  if mkdir "$UI_SESSION_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$UI_SESSION_LOCK/pid"
    CUSTOM_UI_LOCKED=1
    return 0
  fi
  [ -f "$UI_SESSION_LOCK/pid" ] && owner="$(cat "$UI_SESSION_LOCK/pid" 2>/dev/null)"
  # An empty owner can mean another launch won mkdir and has not written its
  # PID yet. Treat it as active rather than breaking a valid lock mid-startup.
  [ -n "$owner" ] || return 1
  if printf '%s' "$owner" | grep -Eq '^[0-9]+$' && kill -0 "$owner" 2>/dev/null; then
    return 1
  fi
  rm -f "$UI_SESSION_LOCK/pid" 2>/dev/null || true
  rmdir "$UI_SESSION_LOCK" 2>/dev/null || return 1
  mkdir "$UI_SESSION_LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$UI_SESSION_LOCK/pid"
  CUSTOM_UI_LOCKED=1
}

custom_ui_lock_release() {
  [ "$CUSTOM_UI_LOCKED" = "1" ] || return 0
  rm -f "$UI_SESSION_LOCK/pid" 2>/dev/null || true
  rmdir "$UI_SESSION_LOCK" 2>/dev/null || true
  CUSTOM_UI_LOCKED=0
}

cleanup_defcon_defense() {
  cleanup_focused_monitor
  cleanup_background_monitor
  custom_ui_lock_release
}
trap cleanup_defcon_defense EXIT
trap 'cleanup_defcon_defense; exit 130' INT
trap 'cleanup_defcon_defense; exit 143' TERM

wait_for_input_or_timeout() { # timeout_seconds
  # WAIT_FOR_INPUT ignores numeric arguments on Pager firmware and blocks until
  # a button is pressed. Run it as a child so live pages can refresh on time.
  local timeout="$1" input_file input_pid timer_pid
  input_file="$LOOT_DIR/.button.$$.$RANDOM"
  WAIT_FOR_INPUT > "$input_file" 2>/dev/null &
  input_pid=$!
  (
    sleep "$timeout"
    kill "$input_pid" 2>/dev/null || true
  ) &
  timer_pid=$!
  wait "$input_pid" 2>/dev/null || true
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
  cat "$input_file" 2>/dev/null || true
  rm -f "$input_file"
}

drain_button_queue() {
  # Virtual and physical Pager buttons can leave a duplicate press queued while
  # a submenu is loading. Discard only the short transition window so one
  # deliberate press maps to one action.
  local i
  for ((i=0; i<2; i++)); do
    [ -n "$(wait_for_input_or_timeout 0.2)" ] || break
  done
}

signal_indicator() { # signal_dbm -> color|label|bar
  local signal="$1"
  awk -v s="$signal" 'BEGIN {
    if (s !~ /^-?[0-9]+([.][0-9]+)?$/) {print "yellow|UNKNOWN|[----------]"; exit}
    if (s >= -50)      print "green|EXCELLENT|[##########]"
    else if (s >= -60) print "green|STRONG|[########--]"
    else if (s >= -70) print "cyan|GOOD|[######----]"
    else if (s >= -80) print "yellow|FAIR|[####------]"
    else               print "red|WEAK|[##--------]"
  }'
}

recent_deauth_count() { # bssid window_seconds
  local bssid="$1" window="${2:-120}" now cutoff
  now="$(date +%s)"; cutoff=$((now - window))
  [ -f "$DEAUTH_EVENTS" ] || { echo 0; return; }
  awk -F ',' -v cutoff="$cutoff" -v wanted="ap=$bssid" \
    '$1 >= cutoff && toupper($4) == toupper(wanted) {count++} END {print count+0}' "$DEAUTH_EVENTS"
}

recent_deauth_total() { # window_seconds
  local window="${1:-120}" now cutoff
  now="$(date +%s)"; cutoff=$((now - window))
  [ -f "$DEAUTH_EVENTS" ] || { echo 0; return; }
  awk -F ',' -v cutoff="$cutoff" '$1 >= cutoff {count++} END {print count+0}' "$DEAUTH_EVENTS"
}

set_recon_bands() {
  if type PINEAPPLE_SET_BANDS >/dev/null 2>&1; then
    PINEAPPLE_SET_BANDS wlan1mon 2 5 >/dev/null 2>&1 || {
      LOG yellow "Could not set Recon bands automatically; check Recon settings."
      return 1
    }
  else
    LOG yellow "PINEAPPLE_SET_BANDS unavailable; enable 2.4 + 5 GHz in Recon."
    return 1
  fi
  return 0
}

capture_snapshot() {
  local quiet="${1:-0}"
  # $$ is unchanged inside a Bash subshell, so it is not unique when the
  # background monitor and foreground UI refresh at the same time. BASHPID and
  # RANDOM keep both atomic staging paths independent.
  local capture_token="${BASHPID:-$$}.${RANDOM:-0}"
  local tmp_json="$LOOT_DIR/.recon.json.$capture_token"
  local tmp_snapshot="$LOOT_DIR/.snapshot.tsv.$capture_token"
  mkdir -p "$LOOT_DIR"
  if ! type _pineap >/dev/null 2>&1; then
    if [ "$quiet" = "1" ]; then LOG yellow "PineAP Recon API is unavailable; retrying."; else ERROR_DIALOG "PineAP Recon API is unavailable."; fi
    return 1
  fi
  if ! _pineap RECON APS format=json > "$tmp_json" 2>/dev/null; then
    rm -f "$tmp_json" "$tmp_snapshot"
    if [ "$quiet" = "1" ]; then LOG yellow "Could not read Recon AP data; retrying."; else ERROR_DIALOG "Could not read Recon AP data. Start Recon and try again."; fi
    return 1
  fi
  if ! rf_normalize_json "$tmp_json" "$tmp_snapshot"; then
    rm -f "$tmp_json" "$tmp_snapshot"
    if [ "$quiet" = "1" ]; then LOG yellow "Recon returned invalid AP data; retrying."; else ERROR_DIALOG "Recon returned invalid AP data."; fi
    return 1
  fi
  mv -f "$tmp_json" "$RECON_JSON"
  mv -f "$tmp_snapshot" "$SNAPSHOT"
  return 0
}

inventory_summary() {
  local count24=0 count5=0 baseline_count=0 trusted_count=0 watched_count=0 findings_count=0 deauth_count=0
  [ -f "$SNAPSHOT" ] && count24="$(rf_count_band "$SNAPSHOT" "2.4GHz")"
  [ -f "$SNAPSHOT" ] && count5="$(rf_count_band "$SNAPSHOT" "5GHz")"
  [ -f "$BASELINE" ] && baseline_count="$(wc -l < "$BASELINE" | tr -d ' ')"
  trusted_count="$(rf_count_config_rows "$TRUSTED_APS")"
  watched_count="$(rf_watch_count "$WATCHED_APS")"
  [ -f "$FINDINGS" ] && findings_count=$(( $(wc -l < "$FINDINGS" | tr -d ' ') - 1 ))
  deauth_count="$(recent_deauth_total 120)"
  [ "$findings_count" -lt 0 ] 2>/dev/null && findings_count=0
  printf '2.4 GHz APs: %s\n5 GHz APs: %s\nWatched networks: %s\nRecent deauth events: %s\nBaseline BSSIDs: %s\nTrusted AP rows: %s\nFindings: %s' \
    "$count24" "$count5" "$watched_count" "$deauth_count" "$baseline_count" "$trusted_count" "$findings_count"
}

show_status() {
  local sentry="NOT ARMED" honeypot="NOT ARMED"
  local port_alert="MISSING" icmp_alert="MISSING"
  local find_hackers="MISSING" alien_ap="MISSING"

  [ -f "$PAYLOAD_ROOT/alerts/deauth_flood_detected/defcon_sentry/payload.sh" ] && sentry="ARMED"
  [ -f "$PAYLOAD_ROOT/alerts/pineapple_client_connected/defcon_honeypot/payload.sh" ] && honeypot="ARMED"
  [ -f "$PAYLOAD_ROOT/user/general/PORT_ALERT/payload.sh" ] && port_alert="READY"
  [ -f "$PAYLOAD_ROOT/user/general/ICMP_ALERT/payload.sh" ] && icmp_alert="READY"
  [ -f "$PAYLOAD_ROOT/user/reconnaissance/find_hackers/payload.sh" ] && find_hackers="READY"
  [ -f "$PAYLOAD_ROOT/user/reconnaissance/alien_ap/payload.sh" ] && alien_ap="READY"

  set_recon_bands || true
  capture_snapshot || true
  local rf_summary; rf_summary="$(inventory_summary)"

  PROMPT "DEFCON DEFENSE STATUS

Deauth Sentry: $sentry
Honeypot: $honeypot
$rf_summary

Manual tools: $port_alert/$icmp_alert
Deep scans: $find_hackers/$alien_ap

Recon bands: 2.4 + 5 GHz
Press a button to return."
}

create_baseline() {
  set_recon_bands || true
  capture_snapshot || return 1
  if [ -s "$BASELINE" ]; then
    [ "$(CONFIRMATION_DIALOG "Replace the current RF baseline with everything visible now?")" = "1" ] || return 0
  else
    [ "$(CONFIRMATION_DIALOG "Trust the current RF inventory as the monitoring baseline?")" = "1" ] || return 0
  fi
  rf_write_baseline "$SNAPSHOT" "$BASELINE" || {
    ERROR_DIALOG "Could not save the RF baseline."
    return 1
  }
  cp "$SNAPSHOT" "$BASELINE_SNAPSHOT"
  PROMPT "RF BASELINE SAVED

$(inventory_summary)

This baseline is optional. Watched networks and
trusted rules work without it.

Trusted SSID/BSSID rules remain separate in:
trusted_aps.conf

Create the baseline only after reviewing the area."
}

alert_rf_finding() { # type bssid ssid channel freq signal band
  local event="$1" bssid="$2" ssid="$3" channel="$4"
  local freq="$5" signal="$6" band="$7" label="$1"
  local severity="HIGH" capture_result="" capture_status="" capture_note=""
  case "$event" in
    TRUSTED_SSID_NEW_BSSID) label="POSSIBLE EVIL TWIN" ;;
    TRUSTED_BSSID_SSID_CHANGE) label="TRUSTED AP CHANGED SSID" ;;
    TRUSTED_AP_CHANNEL_CHANGE) label="TRUSTED AP CHANGED CHANNEL" ;;
    WATCHED_SSID_NEW_BSSID) label="WATCHED SSID NEW BSSID" ;;
    WATCHED_BSSID_SSID_CHANGE) label="WATCHED AP CHANGED SSID" ;;
    WATCHED_AP_CHANNEL_CHANGE) label="WATCHED AP CHANGED CHANNEL" ;;
    NEW_BSSID) label="NEW PERSISTENT AP"; severity="REVIEW" ;;
  esac
  rf_append_finding "$FINDINGS" "$(date +%s)" "$event" "$bssid" "$ssid" "$channel" "$freq" "$signal" "$band"
  if [ "$severity" = "HIGH" ]; then
    capture_result="$(pcap_evidence_auto_start "$event" "$severity" "$ssid" "$bssid" \
      "$band" "$channel" "$signal" 2>/dev/null || true)"
    capture_status="${capture_result%%|*}"
    case "$capture_status" in
      CAPTURING) capture_note="PCAP: CAPTURING 00:${PCAP_EVIDENCE_DURATION:-30}" ;;
      BUSY) capture_note="PCAP: another evidence capture is active" ;;
      COOLDOWN) capture_note="PCAP: recent matching evidence already saved" ;;
      STORAGE_LIMIT) capture_note="PCAP: skipped by storage safety reserve" ;;
      *) capture_note="PCAP: unavailable; finding log preserved" ;;
    esac
  else
    capture_note="PCAP: manual capture available after review"
  fi
  if [ ! -f "$UI_MUTE" ]; then
    RINGTONE --vibrate urgent >/dev/null 2>&1 &
  fi
  LED ATTACK >/dev/null 2>&1 || true
  ALERT "$severity THREAT
$label
Affected: $(rf_clean_field "$ssid")
BSSID: $bssid
Band/channel: $band / $channel
Signal: ${signal} dBm
Time: $(date '+%H:%M:%S')
$capture_note"
  LOG red "$label | $ssid | $bssid | $band ch $channel | ${signal} dBm"
  LOG red "$capture_note"
}

analyze_snapshot() {
  local bssid ssid channel freq signal _seen_time _packets band event threshold should_alert
  local quiet="${1:-0}" alerts=0 observations=0 new_bssids_seen=""
  while IFS=$'\t' read -r bssid ssid channel freq signal _seen_time _packets band; do
    case "$band" in 2.4GHz|5GHz) ;; *) continue ;; esac
    observations=$((observations + 1))
    event="$(rf_watch_classify "$WATCHED_APS" "$bssid" "$ssid" "$channel")"
    if [ "$event" = "NONE" ]; then
      event="$(rf_classify_observation "$TRUSTED_APS" "$BASELINE" "$bssid" "$ssid" "$channel")"
    fi
    [ "$event" != "NONE" ] || continue

    threshold=1
    if [ "$event" = "NEW_BSSID" ] || [ "$event" = "WATCHED_SSID_NEW_BSSID" ]; then
      rf_signal_meets_threshold "$signal" "$MIN_NEW_BSSID_SIGNAL" || continue
      # One hit per BSSID per scan. A multi-SSID AP must not satisfy the
      # repeat threshold from several rows in a single Recon snapshot.
      case "$new_bssids_seen" in *"|$bssid|"*) continue ;; esac
      new_bssids_seen="${new_bssids_seen}|${bssid}|"
      threshold="$NEW_BSSID_THRESHOLD"
    fi
    should_alert="$(rf_state_should_alert "$ALERT_STATE" "$event" "$bssid" "$(date +%s)" \
      "$threshold" "$OBSERVATION_WINDOW" "$ALERT_COOLDOWN")"
    if [ "$should_alert" = "1" ]; then
      alert_rf_finding "$event" "$bssid" "$ssid" "$channel" "$freq" "$signal" "$band"
      alerts=$((alerts + 1))
    fi
  done < "$SNAPSHOT"
  [ "$quiet" = "1" ] || LOG "Observed $observations records; issued $alerts new alerts."
}

background_monitor_loop() {
  while true; do
    if [ ! -f "$MONITOR_PAUSE_FILE" ] && capture_snapshot 1; then
      analyze_snapshot 1
    fi
    sleep "$MONITOR_INTERVAL"
  done
}

start_background_monitor() {
  if [ -n "$BACKGROUND_MONITOR_PID" ] && kill -0 "$BACKGROUND_MONITOR_PID" 2>/dev/null; then
    return 0
  fi
  rm -f "$MONITOR_PAUSE_FILE"
  background_monitor_loop >/dev/null 2>&1 &
  BACKGROUND_MONITOR_PID=$!
}

background_monitor_status() {
  if [ -n "$BACKGROUND_MONITOR_PID" ] && kill -0 "$BACKGROUND_MONITOR_PID" 2>/dev/null; then
    echo "ACTIVE"
  else
    echo "PAUSED"
  fi
}

write_custom_ui_state() {
  local tmp="$UI_STATE.tmp.$$" threat_snapshot="$LOOT_DIR/latest_threats.tsv"
  local count24=0 count5=0 ap_count=0 threat_count=0 watched_count=0
  if [ -s "$SNAPSHOT" ]; then
    count24="$(rf_count_band "$SNAPSHOT" "2.4GHz")"
    count5="$(rf_count_band "$SNAPSHOT" "5GHz")"
    ap_count=$((count24 + count5))
    rf_build_threat_snapshot "$WATCHED_APS" "$TRUSTED_APS" "$BASELINE" "$SNAPSHOT" \
      "$DEAUTH_EVENTS" "$(date +%s)" "$threat_snapshot" >/dev/null 2>&1 || true
  fi
  [ -s "$threat_snapshot" ] && threat_count="$(wc -l < "$threat_snapshot" | tr -d ' ')"
  watched_count="$(rf_watch_count "$WATCHED_APS")"
  pcap_evidence_import_existing >/dev/null 2>&1 || true
  {
    printf 'version=4\n'
    printf 'monitoring=ACTIVE\n'
    printf 'updated_epoch=%s\n' "$(date +%s)"
    printf 'ap_count=%s\n' "$ap_count"
    printf 'count_24=%s\n' "$count24"
    printf 'count_5=%s\n' "$count5"
    printf 'threat_count=%s\n' "$threat_count"
    printf 'watched_count=%s\n' "$watched_count"
  } > "$tmp" && mv -f "$tmp" "$UI_STATE"
}

custom_ui_backend_loop() {
  while true; do
    if capture_snapshot 1; then
      analyze_snapshot 1
    fi
    write_custom_ui_state
    sleep "$MONITOR_INTERVAL"
  done
}

verify_custom_ui_evidence() { # evidence id
  local id="$1" path sha tmp
  path="$(awk -F '\t' -v wanted="$id" 'NR>1 && $2==wanted {print $15; exit}' \
    "$PCAP_EVIDENCE_INDEX" 2>/dev/null)"
  case "$path" in
    "$PCAP_DIR"/*) ;;
    *) return 1 ;;
  esac
  [ -f "$path" ] || return 1
  sha="$(pcap_evidence_sha256 "$path")"
  [ -n "$sha" ] || sha="unavailable"
  tmp="$PCAP_EVIDENCE_INDEX.tmp.$$"
  awk -F '\t' -v OFS='\t' -v wanted="$id" -v digest="$sha" \
    '$2==wanted {$12=digest} {print}' "$PCAP_EVIDENCE_INDEX" > "$tmp" && \
    mv -f "$tmp" "$PCAP_EVIDENCE_INDEX"
}

custom_ui_action_loop() {
  local action event ssid bssid band channel signal id
  while true; do
    if [ -s "$UI_ACTION" ] && mv -f "$UI_ACTION" "$UI_ACTION.processing" 2>/dev/null; then
      IFS='|' read -r action event ssid bssid band channel signal < "$UI_ACTION.processing" || true
      rm -f "$UI_ACTION.processing"
      case "$action" in
        CAPTURE)
          pcap_evidence_bounded_start "${event:-MANUAL_INVESTIGATE}" "INFO" \
            "$ssid" "$bssid" "$band" "$channel" "$signal" \
            "manual-investigate" 0 "${PCAP_EVIDENCE_DURATION:-30}" >/dev/null 2>&1 || true
          ;;
        VERIFY)
          id="$event"
          verify_custom_ui_evidence "$id" >/dev/null 2>&1 || true
          ;;
      esac
      write_custom_ui_state
    fi
    sleep 1
  done
}

install_virtual_pager_bridge() {
  local ui_root="/pineapple/ui"
  local index="$ui_root/index.html"
  local target="$ui_root/defcon-ui-bridge.js"
  local inline="$ui_root/defcon-ui-bridge.inline"
  local tmp="$ui_root/index.html.defcon-defense.tmp"
  [ -f "$UI_BRIDGE_SOURCE" ] && [ -f "$index" ] || return 1
  cp "$UI_BRIDGE_SOURCE" "$target" || return 1
  if grep -Fq '__defconDefenseBridgeVersion = "4.2.3"' "$index"; then
    return 0
  fi
  [ -f "$ui_root/index.html.defcon-defense-backup" ] || \
    cp "$index" "$ui_root/index.html.defcon-defense-backup" || return 1
  # Rebuild from the pristine page with BusyBox sed. The prior awk string
  # accumulator emitted the 140 KB portal extremely slowly on this hardware.
  # A small prebuilt inline block keeps the rewrite fast and correctly places
  # the bridge before the closing body tag.
  {
    printf '<script>\n'
    cat "$UI_BRIDGE_SOURCE"
    printf '\n</script>\n</body>\n'
  } > "$inline" || return 1
  sed "/<\\/body>/{
r $inline
d
}" "$ui_root/index.html.defcon-defense-backup" > "$tmp" || return 1
  mv -f "$tmp" "$index"
}

custom_ui_session() {
  if ! custom_ui_lock_acquire; then
    return 0
  fi
  set_recon_bands || true
  # Render immediately from the last good state. Recon refresh belongs in the
  # background so the operator never waits at a blank stock payload screen.
  write_custom_ui_state
  install_virtual_pager_bridge >/dev/null 2>&1 &
  CUSTOM_UI_BRIDGE_PID=$!
  custom_ui_backend_loop >/dev/null 2>&1 &
  CUSTOM_UI_BACKEND_PID=$!
  custom_ui_action_loop >/dev/null 2>&1 &
  CUSTOM_UI_ACTION_PID=$!
  "$UI_BINARY" \
    --framebuffer /dev/fb0 \
    --data-dir "$LOOT_DIR" \
    --pcap-dir "$PCAP_DIR" \
    --action-file "$UI_ACTION" \
    --mute-file "$UI_MUTE"
}

AP_BSSIDS=()
AP_SSIDS=()
AP_CHANNELS=()
AP_FREQS=()
AP_SIGNALS=()
AP_TIMES=()
AP_PACKETS=()
AP_BANDS=()
AP_COUNT=0
LIVE_PREV_BSSID=""
LIVE_PREV_PACKETS=""

load_recon_targets() {
  local bssid ssid channel freq signal seen_time packets band
  capture_snapshot "${1:-0}" || return 1
  AP_BSSIDS=(); AP_SSIDS=(); AP_CHANNELS=(); AP_FREQS=()
  AP_SIGNALS=(); AP_TIMES=(); AP_PACKETS=(); AP_BANDS=()
  while IFS=$'\t' read -r bssid ssid channel freq signal seen_time packets band; do
    case "$band" in 2.4GHz|5GHz) ;; *) continue ;; esac
    AP_BSSIDS+=("$bssid")
    AP_SSIDS+=("$ssid")
    AP_CHANNELS+=("$channel")
    AP_FREQS+=("$freq")
    AP_SIGNALS+=("$signal")
    AP_TIMES+=("$seen_time")
    AP_PACKETS+=("$packets")
    AP_BANDS+=("$band")
  done < "$SNAPSHOT"
  AP_COUNT="${#AP_BSSIDS[@]}"
  return 0
}

recon_index_for_bssid() { # bssid
  local wanted="$1" i
  for ((i=0; i<AP_COUNT; i++)); do
    [ "${AP_BSSIDS[$i]}" = "$wanted" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

show_recon_target() { # index
  local index="$1" watch_state="NO" ssid indicator color label bar packet_delta=0
  local current_packets
  rf_watch_contains "$WATCHED_APS" "${AP_BSSIDS[$index]}" && watch_state="YES"
  ssid="$(printf '%s' "${AP_SSIDS[$index]}" | cut -c1-30)"
  current_packets="${AP_PACKETS[$index]}"
  if [ "$LIVE_PREV_BSSID" = "${AP_BSSIDS[$index]}" ] && \
     printf '%s' "$LIVE_PREV_PACKETS" | grep -Eq '^[0-9]+$' && \
     printf '%s' "$current_packets" | grep -Eq '^[0-9]+$'; then
    [ "$current_packets" -ge "$LIVE_PREV_PACKETS" ] 2>/dev/null && \
      packet_delta=$((current_packets - LIVE_PREV_PACKETS))
  fi
  LIVE_PREV_BSSID="${AP_BSSIDS[$index]}"; LIVE_PREV_PACKETS="$current_packets"
  indicator="$(signal_indicator "${AP_SIGNALS[$index]}")"
  color="${indicator%%|*}"; indicator="${indicator#*|}"
  label="${indicator%%|*}"; bar="${indicator#*|}"
  LOG " "
  LOG cyan "LIVE RF TRAFFIC [$((index + 1))/$AP_COUNT] $(date '+%H:%M:%S')"
  LOG green "$ssid"
  LOG "${AP_BSSIDS[$index]}"
  LOG "$color" "Signal ${AP_SIGNALS[$index]} dBm $bar $label"
  LOG "${AP_BANDS[$index]} ch ${AP_CHANNELS[$index]} | packets $current_packets (+$packet_delta)"
  LOG green "Watched: $watch_state | Threat details: separate page"
  LOG "UP/DOWN AP | A(GREEN) watch"
  LOG "RIGHT live focus | LEFT/B(RED) back"
}

focused_live_monitor() { # bssid ssid band channel
  local bssid="$1" ssid="$2" band="$3" channel="$4"
  local pcap="" capture_result="" capture_status="" button signal line_count=0 previous_count=0 samples=0
  local indicator color label bar deauth_count last_deauth_count=0
  local focus_started focus_max_seconds=30
  FOCUS_SIGNAL_FILE="$LOOT_DIR/.focus-signal.$$"
  : > "$MONITOR_PAUSE_FILE"
  : > "$FOCUS_SIGNAL_FILE"

  LOG " "
  LOG cyan "FOCUSED PASSIVE RECON"
  LOG green "$(printf '%s' "$ssid" | cut -c1-30)"
  LOG "$bssid"
  LOG "$band ch $channel | LIVE activity"
  LOG "Receiver follows AP + nearby clients."
  LOG green "A (GREEN) = stop/save"
  LOG red "B (RED) = Pager stop dialog"
  LOG "Auto-save after ${focus_max_seconds}s"

  if type PINEAPPLE_EXAMINE_BSSID >/dev/null 2>&1; then
    PINEAPPLE_EXAMINE_BSSID "$bssid" 3600 >/dev/null 2>&1 || \
      LOG yellow "Could not lock Recon to this BSSID; continuing on current Recon settings."
  fi
  capture_result="$(pcap_evidence_manual_start "MANUAL_FOCUS" "INFO" "$ssid" "$bssid" \
    "$band" "$channel" "?" 2>/dev/null || true)"
  capture_status="${capture_result%%|*}"
  if [ "$capture_status" = "CAPTURING" ]; then
    FOCUS_CAPTURE_ID="$(printf '%s' "$capture_result" | cut -d '|' -f2)"
    pcap="$(printf '%s' "$capture_result" | cut -d '|' -f3)"
    FOCUS_PCAP_ACTIVE=1
    LOG "PCAP evidence: $pcap"
  else
    case "$capture_status" in
      BUSY) LOG yellow "PCAP busy: automatic evidence capture is already active." ;;
      STORAGE_LIMIT) LOG yellow "PCAP skipped: storage safety reserve reached." ;;
      *) LOG yellow "PCAP capture unavailable; live signal monitoring continues." ;;
    esac
  fi

  _pineap MONITOR "$bssid" any rate=500 timeout=3600 > "$FOCUS_SIGNAL_FILE" 2>&1 &
  FOCUS_MONITOR_PID=$!
  focus_started="$(date +%s)"
  sleep 1
  if ! kill -0 "$FOCUS_MONITOR_PID" 2>/dev/null; then
    cleanup_focused_monitor
    ERROR_DIALOG "Focused Recon monitor could not start."
    return 1
  fi

  while kill -0 "$FOCUS_MONITOR_PID" 2>/dev/null; do
    [ "$(( $(date +%s) - focus_started ))" -lt "$focus_max_seconds" ] || break
    button="$(wait_for_input_or_timeout 0.5)"
    case "$button" in A|B|LEFT) break ;; esac
    line_count="$(wc -l < "$FOCUS_SIGNAL_FILE" | tr -d ' ')"
    if [ "$line_count" -gt "$previous_count" ] 2>/dev/null; then
      signal="$(tail -n 1 "$FOCUS_SIGNAL_FILE" | tr -d ' \t\r\n')"
      samples=$((samples + line_count - previous_count))
      previous_count="$line_count"
      if printf '%s' "$signal" | grep -Eq '^-?[0-9]+([.][0-9]+)?$'; then
        indicator="$(signal_indicator "$signal")"
        color="${indicator%%|*}"; indicator="${indicator#*|}"
        label="${indicator%%|*}"; bar="${indicator#*|}"
        LOG "$color" "LIVE ${signal} dBm $bar $label | samples $samples"
      fi
    fi
    deauth_count="$(recent_deauth_count "$bssid" 120)"
    if [ "$deauth_count" -gt "$last_deauth_count" ] 2>/dev/null; then
      LOG red "THREAT: DEAUTH/DISASSOC detected ($deauth_count events / 2 min)"
      last_deauth_count="$deauth_count"
    fi
  done
  cleanup_focused_monitor
  if [ -n "$pcap" ] && [ -s "$pcap" ]; then
    LOG green "Saved passive RF evidence: $pcap"
  else
    [ -z "$pcap" ] || rm -f "$pcap"
    LOG "Focused Recon stopped; no PCAP data was written."
  fi
  return 0
}

live_rf_dashboard() {
  local button i total_packets count_24 count_5 top_limit indicator color label bar refreshes=0
  set_recon_bands || true
  drain_button_queue
  while true; do
    load_recon_targets || { ERROR_DIALOG "Recon traffic could not be read."; return 1; }
    total_packets=0; count_24=0; count_5=0
    for ((i=0; i<AP_COUNT; i++)); do
      total_packets=$((total_packets + ${AP_PACKETS[$i]:-0}))
      case "${AP_BANDS[$i]}" in 2.4GHz) count_24=$((count_24 + 1)) ;; 5GHz) count_5=$((count_5 + 1)) ;; esac
    done
    LOG " "
    LOG cyan "LIVE RF TRAFFIC $(date '+%H:%M:%S')"
    LOG "APs $AP_COUNT | 2.4G $count_24 | 5G $count_5 | packets $total_packets"
    top_limit="$AP_COUNT"; [ "$top_limit" -gt 3 ] && top_limit=3
    for ((i=0; i<top_limit; i++)); do
      indicator="$(signal_indicator "${AP_SIGNALS[$i]}")"
      color="${indicator%%|*}"; indicator="${indicator#*|}"
      label="${indicator%%|*}"; bar="${indicator#*|}"
      LOG "$color" "${AP_SIGNALS[$i]}dBm $bar $label | ${AP_SSIDS[$i]}"
      LOG "${AP_BANDS[$i]} ch${AP_CHANNELS[$i]} | packets ${AP_PACKETS[$i]}"
    done
    LOG green "A (GREEN) = return to menu"
    LOG red "B (RED) = Pager stop dialog"
    LOG "Auto-return after 3 refreshes"
    button="$(wait_for_input_or_timeout 2)"
    [ "$button" = "A" ] && return 0
    [ "$button" = "B" ] && return 0
    refreshes=$((refreshes + 1))
    [ "$refreshes" -lt 3 ] || return 0
  done
}

live_recon_browser() {
  local choice action watch_action index i indicator label ssid_clean
  local refresh_choice="Refresh live traffic"
  local back_choice="Back to DEFCON Defense"
  local focus_choice="Focus live + save PCAP"
  local action_back="Back to live traffic"
  local main_back="Back to DEFCON Defense"
  local -a picker_options=()

  set_recon_bands || true
  while true; do
    load_recon_targets || return 1
    if [ "$AP_COUNT" -eq 0 ]; then
      ERROR_DIALOG "Recon has not observed any 2.4/5 GHz APs yet. Keep Recon running and try again."
      return 1
    fi

    picker_options=()
    for ((i=0; i<AP_COUNT; i++)); do
      indicator="$(signal_indicator "${AP_SIGNALS[$i]}")"
      indicator="${indicator#*|}"; label="${indicator%%|*}"
      ssid_clean="$(printf '%s' "${AP_SSIDS[$i]}" | tr '\n\r\t' '   ' | cut -c1-22)"
      picker_options+=("$(printf '%sdBm %s | %s ch%s | p%s | %s | %s' \
        "${AP_SIGNALS[$i]}" "$label" "${AP_BANDS[$i]}" "${AP_CHANNELS[$i]}" \
        "${AP_PACKETS[$i]}" "$ssid_clean" "${AP_BSSIDS[$i]}")")
    done
    picker_options+=("$refresh_choice" "$back_choice")

    choice="$(LIST_PICKER "Live RF Traffic ($AP_COUNT APs)" \
      "${picker_options[@]}" "${picker_options[0]}")" || return 0
    drain_button_queue
    [ "$choice" = "$back_choice" ] && return 0
    [ "$choice" = "$refresh_choice" ] && continue

    index=""
    for ((i=0; i<AP_COUNT; i++)); do
      [ "$choice" = "${picker_options[$i]}" ] && { index="$i"; break; }
    done
    [ -n "$index" ] || continue

    if rf_watch_contains "$WATCHED_APS" "${AP_BSSIDS[$index]}"; then
      watch_action="Stop watching this network"
    else
      watch_action="Watch this network"
    fi
    action="$(LIST_PICKER "${AP_SSIDS[$index]} ${AP_SIGNALS[$index]}dBm" \
      "$focus_choice" "$watch_action" "$action_back" "$main_back" "$action_back")" || continue
    drain_button_queue
    case "$action" in
      "$focus_choice")
        drain_button_queue
        focused_live_monitor "${AP_BSSIDS[$index]}" "${AP_SSIDS[$index]}" \
          "${AP_BANDS[$index]}" "${AP_CHANNELS[$index]}"
        ;;
      "Watch this network")
        rf_watch_upsert "$WATCHED_APS" "${AP_BSSIDS[$index]}" "${AP_SSIDS[$index]}" \
          "${AP_CHANNELS[$index]}" "${AP_BANDS[$index]}" || \
          ERROR_DIALOG "Could not save this watched network."
        ;;
      "Stop watching this network")
        rf_watch_remove "$WATCHED_APS" "${AP_BSSIDS[$index]}"
        ;;
      "$main_back") return 0 ;;
    esac
  done
}

THREAT_BSSIDS=()
THREAT_SSIDS=()
THREAT_CHANNELS=()
THREAT_BANDS=()
THREAT_SIGNALS=()
THREAT_PACKETS=()
THREAT_REASONS=()
THREAT_COLORS=()
THREAT_COUNT=0

threat_label_for() { # event deauth_count
  local event="$1" deauth_count="$2"
  if [ "$deauth_count" -gt 0 ] 2>/dev/null; then
    printf 'DEAUTH/DISASSOC: %s events in 2 min' "$deauth_count"
    return
  fi
  case "$event" in
    WATCHED_SSID_NEW_BSSID|TRUSTED_SSID_NEW_BSSID) echo "POSSIBLE EVIL TWIN / NEW BSSID" ;;
    WATCHED_BSSID_SSID_CHANGE|TRUSTED_BSSID_SSID_CHANGE) echo "KNOWN BSSID CHANGED SSID" ;;
    WATCHED_AP_CHANNEL_CHANGE|TRUSTED_AP_CHANNEL_CHANGE) echo "KNOWN AP CHANGED CHANNEL" ;;
    NEW_BSSID) echo "PERSISTENT AP OUTSIDE OPTIONAL BASELINE" ;;
    *) echo "$event" ;;
  esac
}

load_active_threats() {
  local bssid ssid channel band signal packets event deauth_count color reason
  local threat_snapshot="$LOOT_DIR/latest_threats.tsv"
  load_recon_targets "${1:-0}" || return 1
  THREAT_BSSIDS=(); THREAT_SSIDS=(); THREAT_CHANNELS=(); THREAT_BANDS=()
  THREAT_SIGNALS=(); THREAT_PACKETS=(); THREAT_REASONS=(); THREAT_COLORS=()
  rf_build_threat_snapshot "$WATCHED_APS" "$TRUSTED_APS" "$BASELINE" "$SNAPSHOT" \
    "$DEAUTH_EVENTS" "$(date +%s)" "$threat_snapshot" || return 1
  while IFS=$'\t' read -r bssid ssid channel band signal packets event deauth_count color; do
    [ -n "$bssid" ] || continue
    reason="$(threat_label_for "$event" "$deauth_count")"
    THREAT_BSSIDS+=("$bssid"); THREAT_SSIDS+=("$ssid")
    THREAT_CHANNELS+=("$channel"); THREAT_BANDS+=("$band")
    THREAT_SIGNALS+=("$signal"); THREAT_PACKETS+=("$packets")
    THREAT_REASONS+=("$reason"); THREAT_COLORS+=("$color")
  done < "$threat_snapshot"
  THREAT_COUNT="${#THREAT_BSSIDS[@]}"
}

threat_index_for_bssid() { # bssid
  local wanted="$1" i
  for ((i=0; i<THREAT_COUNT; i++)); do
    [ "${THREAT_BSSIDS[$i]}" = "$wanted" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

show_threat_target() { # index
  local index="$1" indicator color label bar evidence_state evidence_color="yellow"
  indicator="$(signal_indicator "${THREAT_SIGNALS[$index]}")"
  color="${indicator%%|*}"; indicator="${indicator#*|}"
  label="${indicator%%|*}"; bar="${indicator#*|}"
  evidence_state="$(pcap_evidence_state_for_bssid "${THREAT_BSSIDS[$index]}")"
  case "$evidence_state" in CAPTURING*) evidence_color="red" ;; "EVIDENCE SAVED") evidence_color="green" ;; esac
  LOG " "
  LOG red "HIGH THREAT [$((index + 1))/$THREAT_COUNT] | $(date '+%H:%M:%S')"
  LOG red "${THREAT_REASONS[$index]}"
  LOG "AFFECTED: $(printf '%s' "${THREAT_SSIDS[$index]}" | cut -c1-30)"
  LOG "$evidence_color" "EVIDENCE: $evidence_state"
  LOG "${THREAT_BSSIDS[$index]} | ${THREAT_BANDS[$index]} ch${THREAT_CHANNELS[$index]}"
  LOG "$color" "${THREAT_SIGNALS[$index]} dBm $bar $label | packets ${THREAT_PACKETS[$index]}"
  LOG green "A investigate/capture | B back"
  LOG cyan "LEFT/RIGHT details | UP/DOWN threat"
}

threat_detail_view() { # initial_index
  local index="$1" button
  [ "$THREAT_COUNT" -gt 0 ] || return 0
  while true; do
    show_threat_target "$index"
    button="$(WAIT_FOR_INPUT || true)"
    case "$button" in
      A)
        drain_button_queue
        focused_live_monitor "${THREAT_BSSIDS[$index]}" "${THREAT_SSIDS[$index]}" \
          "${THREAT_BANDS[$index]}" "${THREAT_CHANNELS[$index]}"
        ;;
      RIGHT|DOWN) index=$(( (index + 1) % THREAT_COUNT )) ;;
      LEFT|UP) index=$(( (index + THREAT_COUNT - 1) % THREAT_COUNT )) ;;
      B) return 0 ;;
    esac
  done
}

threat_activity_dashboard() {
  local button action i wanted_color row_color shown red_count failure_count=0
  local signal_info signal_label signal_bar
  set_recon_bands || true
  drain_button_queue
  LOG " "
  LOG cyan "THREAT ACTIVITY LIVE"
  LOG "Continuous passive Recon correlation"
  LOG green "A (GREEN) = actions / investigate"
  LOG red "B (RED) = Pager stop dialog"

  while true; do
    if ! load_active_threats 1; then
      failure_count=$((failure_count + 1))
      LOG yellow "Threat refresh failed ($failure_count/3)."
      if [ "$failure_count" -ge 3 ]; then
        LOG red "THREAT ACTIVITY LIVE stopped after repeated Recon failures."
        return 1
      fi
    else
      failure_count=0
      red_count=0
      for ((i=0; i<THREAT_COUNT; i++)); do
        [ "${THREAT_COLORS[$i]}" = "red" ] && red_count=$((red_count + 1))
      done
      LOG " "
      if [ "$red_count" -gt 0 ]; then
        LOG red "MALICIOUS TRAFFIC LIVE $(date '+%H:%M:%S') | red $red_count | total $THREAT_COUNT"
      elif [ "$THREAT_COUNT" -gt 0 ]; then
        LOG yellow "THREAT ACTIVITY LIVE $(date '+%H:%M:%S') | review $THREAT_COUNT"
      else
        LOG green "THREAT ACTIVITY LIVE $(date '+%H:%M:%S') | CLEAR"
      fi

      shown=0
      # Put malicious red indicators before optional-baseline review items so
      # a weaker deauth/identity event cannot be hidden below a stronger AP.
      for wanted_color in red yellow; do
        for ((i=0; i<THREAT_COUNT && shown<THREAT_LIVE_MAX_ROWS; i++)); do
          row_color="${THREAT_COLORS[$i]}"
          [ "$row_color" = "$wanted_color" ] || continue
          signal_info="$(signal_indicator "${THREAT_SIGNALS[$i]}")"
          signal_info="${signal_info#*|}"; signal_label="${signal_info%%|*}"; signal_bar="${signal_info#*|}"
          LOG "$row_color" "${THREAT_REASONS[$i]}"
          LOG "$row_color" "${THREAT_SSIDS[$i]} | ${THREAT_BSSIDS[$i]}"
          LOG "$row_color" "${THREAT_SIGNALS[$i]}dBm $signal_bar $signal_label | ${THREAT_BANDS[$i]} ch${THREAT_CHANNELS[$i]} | packets ${THREAT_PACKETS[$i]}"
          shown=$((shown + 1))
        done
      done
    fi

    LOG green "A (GREEN) = actions / investigate"
    button="$(wait_for_input_or_timeout "$THREAT_LIVE_INTERVAL")"
    case "$button" in
      A)
        drain_button_queue
        action="$(LIST_PICKER "Threat Live Actions" "Investigate Threats" \
          "Back to DEFCON Defense" "Continue Live" "Investigate Threats")" || continue
        drain_button_queue
        case "$action" in
          "Investigate Threats") investigate_threats ;;
          "Back to DEFCON Defense") return 0 ;;
        esac
        ;;
      LEFT|B) return 0 ;;
    esac
  done
}

investigate_threats() {
  local choice index i reason_clean ssid_clean
  local refresh_choice="Refresh threat activity"
  local back_choice="Back to DEFCON Defense"
  local -a picker_options=()

  set_recon_bands || true
  while true; do
    if ! load_active_threats; then
      ERROR_DIALOG "Threat feed refresh failed. Try again."
      return 1
    elif [ "$THREAT_COUNT" -eq 0 ]; then
      choice="$(LIST_PICKER "Investigate Threats: clear" \
        "$refresh_choice" "$back_choice" "$refresh_choice")" || return 0
      drain_button_queue
      [ "$choice" = "$back_choice" ] && return 0
      continue
    fi

    picker_options=()
    for ((i=0; i<THREAT_COUNT; i++)); do
      reason_clean="$(printf '%s' "${THREAT_REASONS[$i]}" | tr '\n\r\t' '   ' | cut -c1-28)"
      ssid_clean="$(printf '%s' "${THREAT_SSIDS[$i]}" | tr '\n\r\t' '   ' | cut -c1-18)"
      picker_options+=("$(printf '! %s | %s | %sdBm | %s' \
        "$reason_clean" "$ssid_clean" "${THREAT_SIGNALS[$i]}" "${THREAT_BSSIDS[$i]}")")
    done
    picker_options+=("$refresh_choice" "$back_choice")
    LOG red "THREAT ACTIVITY: $THREAT_COUNT active indicator(s)"
    choice="$(LIST_PICKER "Investigate Threats ($THREAT_COUNT)" \
      "${picker_options[@]}" "${picker_options[0]}")" || return 0
    drain_button_queue
    [ "$choice" = "$back_choice" ] && return 0
    [ "$choice" = "$refresh_choice" ] && continue

    index=""
    for ((i=0; i<THREAT_COUNT; i++)); do
      [ "$choice" = "${picker_options[$i]}" ] && { index="$i"; break; }
    done
    [ -n "$index" ] || continue

    drain_button_queue
    threat_detail_view "$index"
  done
}

PCAP_EPOCHS=()
PCAP_IDS=()
PCAP_EVENTS=()
PCAP_SEVERITIES=()
PCAP_SSIDS=()
PCAP_BSSIDS=()
PCAP_BANDS=()
PCAP_CHANNELS=()
PCAP_SIGNALS=()
PCAP_DURATIONS=()
PCAP_SIZES=()
PCAP_HASHES=()
PCAP_STATUSES=()
PCAP_TRIGGERS=()
PCAP_PATHS=()
PCAP_COUNT=0

pcap_event_label() { # event
  case "$1" in
    DEAUTH_ACTIVITY) echo "DEAUTH" ;;
    TRUSTED_SSID_NEW_BSSID|WATCHED_SSID_NEW_BSSID) echo "EVIL TWIN" ;;
    TRUSTED_BSSID_SSID_CHANGE|WATCHED_BSSID_SSID_CHANGE) echo "SSID CHANGE" ;;
    TRUSTED_AP_CHANNEL_CHANGE|WATCHED_AP_CHANNEL_CHANGE) echo "CHANNEL CHANGE" ;;
    MANUAL_FOCUS) echo "MANUAL FOCUS" ;;
    LEGACY_CAPTURE) echo "LEGACY CAPTURE" ;;
    *) printf '%s' "$1" | tr '_' ' ' | cut -c1-18 ;;
  esac
}

pcap_event_time() { # epoch format
  local epoch="$1" format="${2:-+%H:%M}"
  date -d "@$epoch" "$format" 2>/dev/null || date -r "$epoch" "$format" 2>/dev/null || echo "$epoch"
}

load_pcap_evidence() {
  local epoch id event severity ssid bssid band channel signal duration size hash status trigger path
  PCAP_EPOCHS=(); PCAP_IDS=(); PCAP_EVENTS=(); PCAP_SEVERITIES=(); PCAP_SSIDS=()
  PCAP_BSSIDS=(); PCAP_BANDS=(); PCAP_CHANNELS=(); PCAP_SIGNALS=(); PCAP_DURATIONS=()
  PCAP_SIZES=(); PCAP_HASHES=(); PCAP_STATUSES=(); PCAP_TRIGGERS=(); PCAP_PATHS=()
  pcap_evidence_import_existing
  while IFS=$'\t' read -r epoch id event severity ssid bssid band channel signal duration size hash status trigger path; do
    [ "$status" = "SAVED" ] || continue
    PCAP_EPOCHS+=("$epoch"); PCAP_IDS+=("$id"); PCAP_EVENTS+=("$event")
    PCAP_SEVERITIES+=("$severity"); PCAP_SSIDS+=("$ssid"); PCAP_BSSIDS+=("$bssid")
    PCAP_BANDS+=("$band"); PCAP_CHANNELS+=("$channel"); PCAP_SIGNALS+=("$signal")
    PCAP_DURATIONS+=("$duration"); PCAP_SIZES+=("$size"); PCAP_HASHES+=("$hash")
    PCAP_STATUSES+=("$status"); PCAP_TRIGGERS+=("$trigger"); PCAP_PATHS+=("$path")
  done < <(awk -F '\t' 'NR>1 && $13=="SAVED"' "$PCAP_EVIDENCE_INDEX" | sort -t $'\t' -k1,1nr | head -n 50)
  PCAP_COUNT="${#PCAP_IDS[@]}"
}

show_pcap_detail() { # index
  local index="$1" event_label timestamp hash_short
  event_label="$(pcap_event_label "${PCAP_EVENTS[$index]}")"
  timestamp="$(pcap_event_time "${PCAP_EPOCHS[$index]}" '+%Y-%m-%d %H:%M:%S')"
  hash_short="$(printf '%s' "${PCAP_HASHES[$index]}" | cut -c1-20)"
  PROMPT "EVIDENCE DETAIL

Threat: $event_label (${PCAP_SEVERITIES[$index]})
Network: ${PCAP_SSIDS[$index]}
Time: $timestamp
BSSID: ${PCAP_BSSIDS[$index]}
Band/channel: ${PCAP_BANDS[$index]} / ${PCAP_CHANNELS[$index]}
Signal: ${PCAP_SIGNALS[$index]} dBm
Duration: ${PCAP_DURATIONS[$index]} sec
Size: $(pcap_evidence_human_bytes "${PCAP_SIZES[$index]}")
SHA-256: ${hash_short}...
Status: ${PCAP_STATUSES[$index]}

Download with Virtual Pager > Download Loot."
}

verify_pcap_hash() { # index
  local index="$1" id path sha tmp
  id="${PCAP_IDS[$index]}"; path="${PCAP_PATHS[$index]}"
  case "$path" in
    "$PCAP_DIR"/*) ;;
    *) ERROR_DIALOG "Capture path is outside the managed PCAP folder."; return 1 ;;
  esac
  [ -f "$path" ] || { ERROR_DIALOG "The selected PCAP file is missing."; return 1; }
  LOG cyan "VERIFYING PCAP SHA-256"
  LOG "$(basename "$path")"
  LOG "This can take time for a large capture."
  sha="$(pcap_evidence_sha256 "$path")"
  [ -n "$sha" ] || sha="unavailable"
  tmp="${PCAP_EVIDENCE_INDEX}.tmp.$$"
  awk -F '\t' -v OFS='\t' -v wanted="$id" -v digest="$sha" \
    '$2==wanted {$12=digest} {print}' "$PCAP_EVIDENCE_INDEX" > "$tmp" && \
    mv -f "$tmp" "$PCAP_EVIDENCE_INDEX"
  PCAP_HASHES[$index]="$sha"
  PROMPT "EVIDENCE VERIFIED\n\nSHA-256:\n$sha"
}

delete_pcap_evidence() { # index
  local index="$1" id path tmp
  id="${PCAP_IDS[$index]}"; path="${PCAP_PATHS[$index]}"
  [ "$(CONFIRMATION_DIALOG "Delete this saved PCAP from the Pager?")" = "1" ] || return 0
  case "$path" in
    "$PCAP_DIR"/*) rm -f -- "$path" ;;
    *) ERROR_DIALOG "Capture path is outside the managed PCAP folder."; return 1 ;;
  esac
  tmp="${PCAP_EVIDENCE_INDEX}.tmp.$$"
  awk -F '\t' -v wanted="$id" 'NR==1 || $2!=wanted' "$PCAP_EVIDENCE_INDEX" > "$tmp" && \
    mv -f "$tmp" "$PCAP_EVIDENCE_INDEX"
  PROMPT "PCAP DELETED\n\nThe selected capture was removed from the Pager."
}

show_pcap_evidence() {
  local choice action index i label time_text size_text ssid_text total_text capture_state evidence_title
  local refresh_choice="Refresh evidence library" back_choice="Back to DEFCON Defense"
  local details_choice="View evidence details" download_choice="Download instructions"
  local verify_choice="Verify SHA-256" delete_choice="Delete selected PCAP" list_back="Back to evidence"
  local -a picker_options=()
  while true; do
    load_pcap_evidence
    total_text="$(pcap_evidence_human_bytes "$(pcap_evidence_total_bytes)")"
    capture_state="$(pcap_evidence_state_status)"
    if [ "${capture_state#CAPTURING}" != "$capture_state" ]; then
      evidence_title="$capture_state | $PCAP_COUNT saved"
    else
      evidence_title="Evidence: $PCAP_COUNT PCAP | $total_text"
    fi
    if [ "$PCAP_COUNT" -eq 0 ]; then
      choice="$(LIST_PICKER "$evidence_title" \
        "$refresh_choice" "$back_choice" "$refresh_choice")" || return 0
      drain_button_queue
      [ "$choice" = "$back_choice" ] && return 0
      continue
    fi

    picker_options=()
    for ((i=0; i<PCAP_COUNT; i++)); do
      time_text="$(pcap_event_time "${PCAP_EPOCHS[$i]}")"
      label="$(pcap_event_label "${PCAP_EVENTS[$i]}")"
      ssid_text="$(printf '%s' "${PCAP_SSIDS[$i]}" | cut -c1-16)"
      size_text="$(pcap_evidence_human_bytes "${PCAP_SIZES[$i]}")"
      picker_options+=("$time_text $label | $ssid_text | $size_text | SAVED")
    done
    picker_options+=("$refresh_choice" "$back_choice")
    choice="$(LIST_PICKER "$evidence_title" \
      "${picker_options[@]}" "${picker_options[0]}")" || return 0
    drain_button_queue
    [ "$choice" = "$back_choice" ] && return 0
    [ "$choice" = "$refresh_choice" ] && continue
    index=""
    for ((i=0; i<PCAP_COUNT; i++)); do
      [ "$choice" = "${picker_options[$i]}" ] && { index="$i"; break; }
    done
    [ -n "$index" ] || continue

    action="$(LIST_PICKER "$(pcap_event_label "${PCAP_EVENTS[$index]}") evidence" \
      "$details_choice" "$verify_choice" "$download_choice" "$delete_choice" "$list_back" "$details_choice")" || continue
    drain_button_queue
    case "$action" in
      "$details_choice") show_pcap_detail "$index" ;;
      "$verify_choice") verify_pcap_hash "$index" ;;
      "$download_choice") PROMPT "DOWNLOAD PCAP EVIDENCE

1. Open Virtual Pager at the Pager address.
2. Choose Download Loot.
3. Save and unzip the archive.
4. Open the pcap folder.

The evidence detail screen shows time, threat, network, size, and SHA-256." ;;
      "$delete_choice") delete_pcap_evidence "$index" ;;
    esac
  done
}

WATCH_BSSIDS=()
WATCH_SSIDS=()
WATCH_CHANNELS=()
WATCH_BANDS=()
WATCH_COUNT=0

load_watched_targets() {
  local bssid ssid channel band
  WATCH_BSSIDS=(); WATCH_SSIDS=(); WATCH_CHANNELS=(); WATCH_BANDS=()
  if [ -f "$WATCHED_APS" ]; then
    while IFS=$'\t' read -r bssid ssid channel band; do
      [ -n "$bssid" ] || continue
      WATCH_BSSIDS+=("$bssid"); WATCH_SSIDS+=("$ssid")
      WATCH_CHANNELS+=("$channel"); WATCH_BANDS+=("$band")
    done < "$WATCHED_APS"
  fi
  WATCH_COUNT="${#WATCH_BSSIDS[@]}"
}

show_watched_networks() {
  local choice action index i
  local back_choice="Back to DEFCON Defense"
  local focus_choice="Focus live + save PCAP"
  local remove_choice="Stop watching this network"
  local list_back="Back to monitored networks"
  local -a picker_options=()

  while true; do
    load_watched_targets
    if [ "$WATCH_COUNT" -eq 0 ]; then
      PROMPT "NO WATCHED NETWORKS

Open Live RF Recon, use UP/DOWN to select a network, then press A to watch it.

No baseline is required."
      return 0
    fi

    picker_options=()
    for ((i=0; i<WATCH_COUNT; i++)); do
      picker_options+=("$(printf '%s | %s ch%s | %s' "${WATCH_SSIDS[$i]}" \
        "${WATCH_BANDS[$i]}" "${WATCH_CHANNELS[$i]}" "${WATCH_BSSIDS[$i]}")")
    done
    picker_options+=("$back_choice")
    choice="$(LIST_PICKER "Monitored Networks ($WATCH_COUNT)" \
      "${picker_options[@]}" "${picker_options[0]}")" || return 0
    drain_button_queue
    [ "$choice" = "$back_choice" ] && return 0
    index=""
    for ((i=0; i<WATCH_COUNT; i++)); do
      [ "$choice" = "${picker_options[$i]}" ] && { index="$i"; break; }
    done
    [ -n "$index" ] || continue

    action="$(LIST_PICKER "${WATCH_SSIDS[$index]}" "$focus_choice" "$remove_choice" \
      "$list_back" "$back_choice" "$list_back")" || continue
    drain_button_queue
    case "$action" in
      "$focus_choice")
        drain_button_queue
        focused_live_monitor "${WATCH_BSSIDS[$index]}" "${WATCH_SSIDS[$index]}" \
          "${WATCH_BANDS[$index]}" "${WATCH_CHANNELS[$index]}"
        ;;
      "$remove_choice")
        if [ "$(CONFIRMATION_DIALOG "Stop watching ${WATCH_SSIDS[$index]}?")" = "1" ]; then
          rf_watch_remove "$WATCHED_APS" "${WATCH_BSSIDS[$index]}"
        fi
        ;;
      "$back_choice") return 0 ;;
    esac
  done
}

start_monitor() {
  local button remaining
  set_recon_bands || true
  LOG cyan "PASSIVE RF MONITOR ACTIVE"
  LOG "Bands: 2.4 + 5 GHz"
  if [ -s "$BASELINE" ]; then
    LOG "Optional baseline: ON"
    LOG "New AP: ${NEW_BSSID_THRESHOLD} sightings, >= ${MIN_NEW_BSSID_SIGNAL} dBm"
  else
    LOG yellow "Optional baseline: OFF"
    LOG "Watching selected/trusted networks only."
  fi
  LOG "Trusted-network mismatches alert immediately."
  LOG green "A (GREEN) = stop and return"
  LOG red "B (RED) = Pager stop dialog"
  while true; do
    if capture_snapshot; then
      LOG "$(date '+%Y-%m-%d %H:%M:%S') | $(inventory_summary | tr '\n' ' ')"
      analyze_snapshot
    else
      LOG yellow "Recon read failed; retrying in ${MONITOR_INTERVAL}s."
    fi
    remaining="$MONITOR_INTERVAL"
    while [ "$remaining" -gt 0 ]; do
      button="$(wait_for_input_or_timeout 1)"
      [ "$button" = "A" ] && { LOG "Passive monitor stopped."; return 0; }
      remaining=$((remaining - 1))
    done
  done
}

show_findings() {
  if [ ! -s "$FINDINGS" ] || [ "$(wc -l < "$FINDINGS" | tr -d ' ')" -le 1 ]; then
    PROMPT "No RF findings have been recorded."
    return 0
  fi
  local recent
  recent="$(tail -n 5 "$FINDINGS" | awk -F '\t' 'NR>1 || $1 != "epoch" {
    printf "%s\n%s\n%s ch%s %sdBm\n\n", $2, $4, $8, $5, $7
  }')"
  PROMPT "LATEST RF FINDINGS

$recent
Full evidence:
$FINDINGS"
}

show_emergency_checklist() {
  PROMPT "HOSTILE RF CHECKLIST

1. Do not join the suspicious AP.
2. Turn Wi-Fi off on protected endpoints.
3. Move critical traffic to wired or trusted cellular service.
4. Record BSSID, SSID, band, channel, signal, time, and location.
5. Notify the SOC lead and venue RF/network team.
6. Preserve findings.tsv and latest_recon.json.
7. Do not transmit countermeasures."
}

launch_payload() {
  local target="$1"
  if [ ! -f "$target" ]; then
    ERROR_DIALOG "Payload is missing:\n$target"
    return 1
  fi
  exec bash "$target"
}

tools_and_setup_menu() {
  local choice
  local back_choice="Back to general screen"
  while true; do
    choice="$(LIST_PICKER "Tools & Setup" \
      "Optional RF baseline" "Latest RF findings" "Hostile-RF checklist" \
      "Start PORT Alert" "Start ICMP Alert" "Launch Find Hackers" \
      "Launch Alien AP" "Test alert" "$back_choice" "Optional RF baseline")" || return 0
    drain_button_queue
    case "$choice" in
      "Optional RF baseline") create_baseline ;;
      "Latest RF findings") show_findings ;;
      "Hostile-RF checklist") show_emergency_checklist ;;
      "Start PORT Alert") launch_payload "$PAYLOAD_ROOT/user/general/PORT_ALERT/payload.sh" ;;
      "Start ICMP Alert") launch_payload "$PAYLOAD_ROOT/user/general/ICMP_ALERT/payload.sh" ;;
      "Launch Find Hackers") launch_payload "$PAYLOAD_ROOT/user/reconnaissance/find_hackers/payload.sh" ;;
      "Launch Alien AP") launch_payload "$PAYLOAD_ROOT/user/reconnaissance/alien_ap/payload.sh" ;;
      "Test alert")
        RINGTONE --vibrate urgent >/dev/null 2>&1 &
        ALERT "DEFCON Defense alert test\nSeverity: TEST\nEvidence: no PCAP created"
        ;;
      "$back_choice") return 0 ;;
    esac
  done
}

general_screen() {
  local menu_choice live_item threat_item evidence_item watched_item monitor_item
  local threat_text red_count pcap_count pcap_state watched_count title monitor_state
  local tools_item="Tools & Setup" status_item="System Status" exit_item="Exit DEFCON Defense"
  set_recon_bands || true
  start_background_monitor
  drain_button_queue
  while true; do
    red_count=0
    if load_active_threats 1; then
      local i
      for ((i=0; i<THREAT_COUNT; i++)); do
        [ "${THREAT_COLORS[$i]}" = "red" ] && red_count=$((red_count + 1))
      done
    fi
    if [ "$red_count" -gt 0 ]; then threat_text="HIGH $red_count"; else threat_text="CLEAR"; fi
    pcap_count="$(pcap_evidence_count)"
    pcap_state="$(pcap_evidence_state_status)"
    watched_count="$(rf_watch_count "$WATCHED_APS")"
    monitor_state="$(background_monitor_status)"
    live_item="Live RF | $monitor_state | $AP_COUNT AP"
    threat_item="Threat Details | $threat_text"
    if [ "$pcap_state" = "IDLE" ] || [ "$pcap_state" = "SAVED" ] || [ "$pcap_state" = "EMPTY" ]; then
      evidence_item="PCAP Evidence | $pcap_count saved"
    else
      evidence_item="PCAP Evidence | $pcap_state"
    fi
    monitor_item="Monitoring Controls | $monitor_state"
    watched_item="Watched Networks | $watched_count"
    title="DEFCON Defense"

    menu_choice="$(LIST_PICKER "$title" "$live_item" "$threat_item" "$evidence_item" \
      "Browse Recon Networks" "Threat Activity Live" "$monitor_item" "$watched_item" \
      "$tools_item" "$status_item" "$exit_item" "$live_item")" || exit 0
    drain_button_queue
    case "$menu_choice" in
      "$live_item") live_rf_dashboard ;;
      "$threat_item") investigate_threats ;;
      "$evidence_item") show_pcap_evidence ;;
      "Browse Recon Networks") live_recon_browser ;;
      "Threat Activity Live") threat_activity_dashboard ;;
      "$monitor_item")
        if [ "$monitor_state" = "ACTIVE" ]; then
          cleanup_background_monitor
          PROMPT "MONITORING PAUSED\n\nAutomatic trusted/watched-network correlation is paused. Deauth Sentry remains an independent firmware alert hook."
        else
          start_background_monitor
          PROMPT "MONITORING ACTIVE\n\nPassive 2.4/5 GHz correlation is running while DEFCON Defense is open."
        fi
        ;;
      "$watched_item") show_watched_networks ;;
      "$tools_item") tools_and_setup_menu ;;
      "$status_item") show_status ;;
      "$exit_item") exit 0 ;;
    esac
  done
}

# Host tests source the payload to exercise the same monitor/alert and UI
# functions without entering the interactive Pager menu.
if [ "${DEFCON_DEFENSE_SOURCE_ONLY:-0}" = "1" ]; then
  if [ "$0" = "${BASH_SOURCE[0]}" ]; then exit 0; else return 0; fi
fi

if [ "${DEFCON_DEFENSE_NATIVE_UI:-1}" = "1" ] && [ -x "$UI_BINARY" ] && [ -w /dev/fb0 ]; then
  custom_ui_session
else
  general_screen
fi
