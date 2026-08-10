#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"
. "$ROOT/lib/pcap_evidence_lib.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/defcon-pcap-test.XXXXXX")"
cleanup() { [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT

PCAP_EVIDENCE_DIR="$TMP/evidence"
PCAP_EVIDENCE_PCAP_DIR="$TMP/pcap"
PCAP_EVIDENCE_INDEX="$PCAP_EVIDENCE_DIR/pcap_index.tsv"
PCAP_EVIDENCE_STATE="$PCAP_EVIDENCE_DIR/pcap_capture.psv"
PCAP_EVIDENCE_DEDUPE="$PCAP_EVIDENCE_DIR/pcap_dedupe.psv"
PCAP_EVIDENCE_LOCK="$PCAP_EVIDENCE_DIR/.pcap_capture.lock"
PCAP_EVIDENCE_DURATION=1
PCAP_EVIDENCE_COOLDOWN=300
PCAP_EVIDENCE_MAX_BYTES=1048576
PCAP_EVIDENCE_MIN_FREE_BYTES=0
CAPTURE_SEQUENCE="$TMP/capture-sequence"
printf '0\n' > "$CAPTURE_SEQUENCE"

WIFI_PCAP_START() {
  local n path
  n="$(cat "$CAPTURE_SEQUENCE")"; n=$((n + 1)); printf '%s\n' "$n" > "$CAPTURE_SEQUENCE"
  path="$PCAP_EVIDENCE_PCAP_DIR/capture-$n.pcap"
  printf 'pcap-evidence-%s\n' "$n" > "$path"
  printf '%s\n' "$path"
}
WIFI_PCAP_STOP() { :; }

result="$(pcap_evidence_auto_start "DEAUTH_ACTIVITY" "HIGH" "DEFCON-GUEST" \
  "AA:BB:CC:DD:EE:FF" "2.4GHz" "6" "-41")"
assert_eq "${result%%|*}" "CAPTURING" "confirmed threat starts passive PCAP immediately"
[ -d "$PCAP_EVIDENCE_LOCK" ]; assert_rc "$?" "0" "automatic capture owns the single-capture lock"
assert_eq "$(wc -l < "$PCAP_EVIDENCE_STATE" | tr -d ' ')" "1" \
  "capture state remains one portable pipe-delimited record"
assert_eq "$(awk -F '|' '{print NF}' "$PCAP_EVIDENCE_STATE")" "13" \
  "capture state preserves every metadata field on BusyBox-compatible format"

busy="$(pcap_evidence_auto_start "TRUSTED_SSID_NEW_BSSID" "HIGH" "HOTEL-WIFI" \
  "11:22:33:44:55:66" "5GHz" "36" "-50" || true)"
assert_eq "${busy%%|*}" "BUSY" "overlapping evidence capture is prevented"

sleep 2
assert_eq "$(pcap_evidence_count)" "1" "completed automatic capture is indexed for browsing"
assert_eq "$(awk -F '\t' 'NR==2 {print $3}' "$PCAP_EVIDENCE_INDEX")" "DEAUTH_ACTIVITY" \
  "evidence index preserves the triggering threat"
assert_eq "$(awk -F '\t' 'NR==2 {print $13}' "$PCAP_EVIDENCE_INDEX")" "SAVED" \
  "non-empty capture is marked saved"
assert_eq "$(awk -F '\t' 'NR==2 {print $12}' "$PCAP_EVIDENCE_INDEX")" "pending" \
  "saved evidence defers expensive SHA-256 work until operator verification"

cooldown="$(pcap_evidence_auto_start "DEAUTH_ACTIVITY" "HIGH" "DEFCON-GUEST" \
  "AA:BB:CC:DD:EE:FF" "2.4GHz" "6" "-41" || true)"
assert_eq "${cooldown%%|*}" "COOLDOWN" "matching threat capture is deduplicated during cooldown"

manual="$(pcap_evidence_manual_start "MANUAL_FOCUS" "INFO" "SOC" \
  "00:11:22:33:44:55" "5GHz" "44" "-55")"
manual_id="$(printf '%s' "$manual" | cut -d '|' -f2)"
assert_eq "${manual%%|*}" "CAPTURING" "manual focused capture uses the same evidence pipeline"
pcap_evidence_finish "$manual_id" >/dev/null
assert_eq "$(pcap_evidence_count)" "2" "manual focused capture appears in evidence library"

bounded="$(pcap_evidence_bounded_start "MANUAL_INVESTIGATE" "INFO" "SOC" \
  "00:11:22:33:44:66" "5GHz" "44" "-57" "manual-investigate" 0 1)"
assert_eq "${bounded%%|*}" "CAPTURING" "custom UI starts a bounded passive investigation capture"
sleep 2
assert_eq "$(awk -F '\t' '$3=="MANUAL_INVESTIGATE" {print $13; exit}' "$PCAP_EVIDENCE_INDEX")" \
  "SAVED" "custom UI investigation capture is saved for evidence browsing"

printf 'older-pcap\n' > "$PCAP_EVIDENCE_PCAP_DIR/preexisting.pcap"
assert_eq "$(pcap_evidence_count)" "4" "preexisting Pager PCAP is imported for later browsing"
assert_eq "$(awk -F '\t' '$3=="LEGACY_CAPTURE" {print $13; exit}' "$PCAP_EVIDENCE_INDEX")" "SAVED" \
  "imported legacy PCAP is indexed without changing the capture file"
assert_eq "$(awk -F '\t' '$3=="LEGACY_CAPTURE" {print $12; exit}' "$PCAP_EVIDENCE_INDEX")" "pending" \
  "legacy import stays responsive by deferring digest verification"

PCAP_EVIDENCE_MAX_BYTES=1
limited="$(pcap_evidence_auto_start "DEAUTH_ACTIVITY" "HIGH" "DEFCON-GUEST" \
  "AA:BB:CC:DD:EE:00" "2.4GHz" "6" "-41" || true)"
assert_eq "${limited%%|*}" "STORAGE_LIMIT" "capture stops before the configured storage quota"

exit "$FAIL"
