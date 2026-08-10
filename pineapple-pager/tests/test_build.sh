#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/defcon-build-test.XXXXXX")"
cleanup() { [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT
OUT="$TMP/library"
OUT="$OUT" bash "$ROOT/build.sh"; assert_rc "$?" "0" "build.sh succeeds"

for p in \
  alerts/deauth_flood_detected/defcon_sentry/payload.sh \
  alerts/deauth_flood_detected/defcon_sentry/pager_alert_lib.sh \
  alerts/pineapple_client_connected/defcon_honeypot/payload.sh \
  alerts/pineapple_client_connected/defcon_honeypot/pager_alert_lib.sh \
  user/general/DEFCON_DEFENSE/payload.sh \
  user/general/DEFCON_DEFENSE/rf_guard_lib.sh \
  user/general/DEFCON_DEFENSE/trusted_aps.conf \
  user/general/PORT_ALERT/payload.sh \
  user/general/ICMP_ALERT/payload.sh \
  user/reconnaissance/find_hackers/payload.sh \
  user/reconnaissance/alien_ap/payload.sh \
  user/reconnaissance/alien_ap/filter.awk ; do
  [ -f "$OUT/$p" ]; assert_rc "$?" "0" "built: $p"
done

# SignalFence is optional (may be absent in newer library versions):
# built iff present in the submodule.
if [ -d "$ROOT/vendor/pager-payloads/user/reconnaissance/SignalFence" ]; then
  [ -f "$OUT/user/reconnaissance/SignalFence/payload.sh" ]; assert_rc "$?" "0" "built optional SignalFence (present in submodule)"
else
  echo "note: SignalFence absent in this submodule version (optional, skipped)"
fi

# no offensive payloads leaked in
[ ! -e "$OUT/user/interception/fenris" ]; assert_rc "$?" "0" "no fenris in output"

# Unified monitor remains passive: no denial or transmit primitives.
if rg -n 'PINEAPPLE_DEAUTH|aireplay-ng|mdk3|mdk4|iw[[:space:]].*[[:space:]]txpower' \
  "$OUT/user/general/DEFCON_DEFENSE" >/dev/null 2>&1; then
  passive_rc=1
else
  passive_rc=0
fi
assert_rc "$passive_rc" "0" "unified monitor contains no disruptive transmit primitive"

UNIFIED="$OUT/user/general/DEFCON_DEFENSE/payload.sh"
if rg -n 'NUMBER_PICKER' "$UNIFIED" >/dev/null 2>&1; then picker_rc=1; else picker_rc=0; fi
assert_rc "$picker_rc" "0" "unified navigation does not open a number picker"
rg -q 'LIST_PICKER "DEFCON Defense"' "$UNIFIED"; assert_rc "$?" "0" "main navigation uses the native Pager list picker"
rg -q 'wait_for_input_or_timeout' "$UNIFIED"; assert_rc "$?" "0" "live views use a real refresh timeout wrapper"
if rg -n 'WAIT_FOR_INPUT[[:space:]]+[0-9]' "$UNIFIED" >/dev/null 2>&1; then timed_wait_rc=1; else timed_wait_rc=0; fi
assert_rc "$timed_wait_rc" "0" "firmware input command is never passed an ignored timeout argument"
rg -q 'LIST_PICKER "Live RF Traffic' "$UNIFIED"; assert_rc "$?" "0" "green A selects live traffic through the native picker"
rg -q '^threat_activity_dashboard()' "$UNIFIED"; assert_rc "$?" "0" "Threat Activity has a dedicated live dashboard"
rg -q 'LIST_PICKER "Investigate Threats' "$UNIFIED"; assert_rc "$?" "0" "Investigate Threats uses the native arrow and A/B picker"
rg -q 'LOG red "MALICIOUS TRAFFIC LIVE' "$UNIFIED"; assert_rc "$?" "0" "live malicious indicators render in red"
rg -Fq '"Threat Activity Live") threat_activity_dashboard' "$UNIFIED"; assert_rc "$?" "0" "main menu launches the continuous threat dashboard"
rg -Fq '"Investigate Threats") investigate_threats' "$UNIFIED"; assert_rc "$?" "0" "main menu keeps threat selection on a separate page"
rg -q '"Browse Recon Networks"' "$UNIFIED"; assert_rc "$?" "0" "normal AP selection is separate from the live dashboard"
rg -q 'Auto-return after 3 refreshes' "$UNIFIED"; assert_rc "$?" "0" "live dashboard cannot trap the operator or drain the battery indefinitely"
rg -q 'ERROR_DIALOG "MALICIOUS TRAFFIC' "$UNIFIED"; assert_rc "$?" "0" "selected malicious traffic is shown in a red error dialog"
rg -q 'Auto-save after.*focus_max_seconds' "$UNIFIED"; assert_rc "$?" "0" "focused capture has a battery-safe auto-save limit"
rg -q '_pineap RECON APS' "$UNIFIED"; assert_rc "$?" "0" "live view reads the Pager Recon feed"
rg -q 'PINEAPPLE_EXAMINE_BSSID' "$UNIFIED"; assert_rc "$?" "0" "focused view uses the Pager Recon selector"
rg -q 'WIFI_PCAP_START' "$UNIFIED"; assert_rc "$?" "0" "focused view saves passive RF evidence"
rg -q '^# Title: DEFCON Defense$' "$UNIFIED"; assert_rc "$?" "0" "package title is DEFCON Defense"
rg -q 'LOG red "THREAT:' "$UNIFIED"; assert_rc "$?" "0" "focused deauth status is prominent red text"
rg -q 'LIVE RF TRAFFIC' "$UNIFIED"; assert_rc "$?" "0" "normal live traffic has its own page"
rg -q 'THREAT ACTIVITY' "$UNIFIED"; assert_rc "$?" "0" "actionable threat traffic has a separate page"
if rg -n 'WIFI_PCAP_START[[:space:]]+"' "$UNIFIED" >/dev/null 2>&1; then pcap_args_rc=1; else pcap_args_rc=0; fi
assert_rc "$pcap_args_rc" "0" "firmware-native PCAP command is called without unsupported arguments"

# every built payload.sh is syntactically valid
err=0; while IFS= read -r f; do bash -n "$f" || err=1; done < <(find "$OUT" -name '*.sh')
assert_rc "$err" "0" "all built shell scripts pass bash -n"

# built payloads are deterministically non-executable 644 regardless of umask
assert_eq "$(ls -l "$OUT/user/general/PORT_ALERT/payload.sh" | cut -c1-10)" "-rw-r--r--" "built payloads are mode 644"

exit $FAIL
