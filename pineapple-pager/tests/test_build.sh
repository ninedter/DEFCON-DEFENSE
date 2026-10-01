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
  alerts/deauth_flood_detected/defcon_sentry/pcap_evidence_lib.sh \
  alerts/pineapple_client_connected/defcon_honeypot/payload.sh \
  alerts/pineapple_client_connected/defcon_honeypot/pager_alert_lib.sh \
  user/defcon/DEFCON-DEFENSE/payload.sh \
  user/defcon/DEFCON-DEFENSE/defcon-ui \
  user/defcon/DEFCON-DEFENSE/pcap_evidence_lib.sh \
  user/defcon/DEFCON-DEFENSE/rf_guard_lib.sh \
  user/defcon/DEFCON-DEFENSE/trusted_aps.conf \
  user/defcon/DEFCON-DEFENSE/virtual-pager-bridge.js \
  user/defcon/RF-BUDDY/payload.sh \
  user/defcon/RF-BUDDY/README.md \
  user/defcon/RF-BUDDY/rf-buddy-ui \
  user/general/PORT_ALERT/payload.sh \
  user/general/ICMP_ALERT/payload.sh \
  user/reconnaissance/find_hackers/payload.sh \
  user/reconnaissance/alien_ap/payload.sh \
  user/reconnaissance/alien_ap/filter.awk ; do
  [ -f "$OUT/$p" ]; assert_rc "$?" "0" "built: $p"
done

file "$OUT/user/defcon/DEFCON-DEFENSE/defcon-ui" | grep -q 'ELF 32-bit.*MIPS'
assert_rc "$?" "0" "full-screen UI is compiled for the Pager MIPS architecture"
assert_eq "$(ls -l "$OUT/user/defcon/DEFCON-DEFENSE/defcon-ui" | cut -c1-10)" "-rwxr-xr-x" \
  "full-screen UI binary is executable"
ui_bytes="$(wc -c < "$OUT/user/defcon/DEFCON-DEFENSE/defcon-ui" | tr -d ' ')"
# v4.20 (EVIOCGRAB input grab, frozen-UI handoff) builds to 7,209,151 bytes;
# keep ~90 KB of headroom so real size regressions still fail.
[ "$ui_bytes" -lt 7300000 ]; assert_rc "$?" "0" "full-screen UI stays inside the embedded binary-size budget"

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
  "$OUT/user/defcon/DEFCON-DEFENSE" >/dev/null 2>&1; then
  passive_rc=1
else
  passive_rc=0
fi
assert_rc "$passive_rc" "0" "unified monitor contains no disruptive transmit primitive"

UNIFIED="$OUT/user/defcon/DEFCON-DEFENSE/payload.sh"
UI_MAIN="$ROOT/src/user/defcon/DEFCON-DEFENSE/ui/main.go"
if rg -n 'NUMBER_PICKER' "$UNIFIED" >/dev/null 2>&1; then picker_rc=1; else picker_rc=0; fi
assert_rc "$picker_rc" "0" "unified navigation does not open a number picker"
rg -q '^general_screen()' "$UNIFIED"; assert_rc "$?" "0" "general screen is the Pager entry point"
rg -q '^custom_ui_session()' "$UNIFIED"; assert_rc "$?" "0" "custom full-screen application is the primary Pager interface"
early_ui_line="$(rg -n '^start_custom_ui_early$' "$UNIFIED" | cut -d: -f1)"
rf_source_line="$(rg -n '^\. "\$RF_LIB"$' "$UNIFIED" | cut -d: -f1)"
if [ -n "$early_ui_line" ] && [ -n "$rf_source_line" ] && [ "$early_ui_line" -lt "$rf_source_line" ]; then early_ui_rc=0; else early_ui_rc=1; fi
assert_rc "$early_ui_rc" "0" "native UI starts before monitoring libraries are loaded"
rg -q '^launch_custom_ui_process()' "$UNIFIED"; assert_rc "$?" "0" "native UI launch is centralized"
rg -Fq 'command -v setsid' "$UNIFIED"; assert_rc "$?" "0" "native UI survives firmware launcher process-group handoff"
rg -Fq 'kill -STOP $pids' "$UNIFIED"; assert_rc "$?" "0" "native UI freezes only the competing firmware framebuffer renderer"
if rg -Fq 'ubus call service delete' "$UNIFIED"; then service_delete_rc=1; else service_delete_rc=0; fi
assert_rc "$service_delete_rc" "0" "native UI never deletes the firmware service, so exit avoids a cold UI restart"
if rg -Fq '/etc/init.d/pineapd stop' "$UNIFIED"; then pineapd_stop_rc=1; else pineapd_stop_rc=0; fi
assert_rc "$pineapd_stop_rc" "0" "native UI never stops the RF monitoring service"
ownership_checks="$(rg -c 'if ! stop_pager_service_for_custom_ui' "$UNIFIED")"
assert_eq "$ownership_checks" "2" "early and fallback native UI launch paths both require framebuffer ownership"
rg -Fq '/etc/init.d/pineapplepager start' "$UNIFIED"; assert_rc "$?" "0" "native UI restores the firmware service during cleanup"
rg -Fq 'pidof pineapple' "$UNIFIED"; assert_rc "$?" "0" "firmware UI detection uses the Pager-compatible exact process lookup"
if rg -Fq 'pgrep -x pineapple' "$UNIFIED"; then exact_pgrep_rc=1; else exact_pgrep_rc=0; fi
assert_rc "$exact_pgrep_rc" "0" "firmware UI detection avoids the Pager pgrep exact-match incompatibility"
rg -Fq 'kill -CONT $PAGER_FROZEN_PIDS' "$UNIFIED"; assert_rc "$?" "0" "exit resumes the frozen firmware menu in place"
rg -Fq 'pager_firmware_ui_running || /etc/init.d/pineapplepager start' "$UNIFIED"; assert_rc "$?" "0" "firmware menu recovery still starts the service if it vanished"
rg -U -q 'wait "\$CUSTOM_UI_PID"\n  ui_rc=\$\?\n(  #.*\n)*  restore_pager_service' "$UNIFIED"; assert_rc "$?" "0" "B hands the menu back before worker shutdown"
rg -Fq 'pager_api_commands_disable' "$UNIFIED"; assert_rc "$?" "0" "session workers cannot block on or queue dialogs for the frozen firmware"
rg -Fq 'grabInput(int(f.Fd()))' "$UI_MAIN"; assert_rc "$?" "0" "native UI takes exclusive button delivery so the frozen menu replays nothing"
rg -Fq '0x80044590' "$(dirname "$UI_MAIN")/grab_linux.go"; assert_rc "$?" "0" "EVIOCGRAB uses the MIPS ioctl encoding on the Pager"
rg -q '^custom_ui_lock_acquire()' "$UNIFIED"; assert_rc "$?" "0" "custom interface prevents duplicate runtime instances"
rg -q 'CUSTOM_UI_BRIDGE_PID' "$UNIFIED"; assert_rc "$?" "0" "Virtual Pager bridge installation cannot outlive UI cleanup"
rg -q 'CUSTOM_UI_PID' "$UNIFIED"; assert_rc "$?" "0" "custom UI child is owned and cleaned up by the payload session"
rg -q 'UI_SESSION_LOCK/ui_pid' "$UNIFIED"; assert_rc "$?" "0" "stale UI children are recorded for safe recovery"
rg -q "exit 129' HUP" "$UNIFIED"; assert_rc "$?" "0" "custom UI is cleaned up when its launcher disconnects"
rg -q '^early_custom_ui_cleanup()' "$UNIFIED"; assert_rc "$?" "0" "early native UI is cleaned up if payload initialization fails"
tail -8 "$UNIFIED" | rg -q '^cleanup_defcon_defense$'; assert_rc "$?" "0" "normal B exit cleans up UI workers before payload EOF"
rg -q -- '--framebuffer /dev/fb0' "$UNIFIED"; assert_rc "$?" "0" "custom interface renders on the physical Pager framebuffer"
rg -q '^install_virtual_pager_bridge()' "$UNIFIED"; assert_rc "$?" "0" "Virtual Pager receives the custom application canvas"
rg -Fq 'data-defcon-defense-bridge=' "$UNIFIED"; assert_rc "$?" "0" "Virtual Pager bridge uses the lightweight external-script marker"
BRIDGE="$OUT/user/defcon/DEFCON-DEFENSE/virtual-pager-bridge.js"
rg -Fq '&wait=1${revision}' "$BRIDGE"; assert_rc "$?" "0" "Virtual Pager uses change-driven long polling"
rg -Fq '&name=${encodeURIComponent(button)}' "$BRIDGE"; assert_rc "$?" "0" "Virtual Pager buttons route directly to the custom application"
rg -Fq 'data-defcon-defense-token' "$UNIFIED"; assert_rc "$?" "0" "Virtual Pager receives a persistent random access token"
rg -Fq "hexdump -n 16 -e '16/1 \"%02x\"'" "$UNIFIED"; assert_rc "$?" "0" "access token generation uses a utility present on Pager 24.10.1"
token_setup_checks="$(rg -c 'ensure_ui_http_token' "$UNIFIED")"
[ "$token_setup_checks" -ge 4 ]; assert_rc "$?" "0" "early, fallback, and bridge paths all require token setup"
rg -Fq 'virtualRequestAuthorized' "$UI_MAIN"; assert_rc "$?" "0" "custom screen and button endpoints require the access token"
rg -Fq -- '--virtual-listen 172.16.52.1:1472' "$UNIFIED"; assert_rc "$?" "0" "custom UI endpoint is bound only to the USB management address"
rg -Fq -- '--portal-listen "172.16.52.1:$CUSTOM_UI_PORTAL_PORT"' "$UNIFIED"; assert_rc "$?" "0" "native launcher binds the embedded portal only to USB management"
rg -Fq 'ip daddr 172.16.52.1 tcp dport 1471 redirect to :$CUSTOM_UI_PORTAL_PORT' "$UNIFIED"; assert_rc "$?" "0" "Virtual Pager reaches the embedded portal while the firmware is frozen"
rg -Fq 'flag.StringVar(&a.portalListen, "portal-listen", "172.16.52.1:1471"' "$UI_MAIN"; assert_rc "$?" "0" "custom UI restores the Virtual Pager portal without the stock framebuffer process"
rg -Fq 'portalHandler(a.portalRoot)' "$UI_MAIN"; assert_rc "$?" "0" "embedded Virtual Pager portal reuses the existing UI process"
rg -Fq 'buttonBusy' "$BRIDGE"; assert_rc "$?" "0" "Virtual Pager blocks queued presses until the rendered screen advances"
rg -Fq 'pendingButton' "$BRIDGE"; assert_rc "$?" "0" "Virtual Pager preserves one distinct follow-up press"
rg -Fq 'const buttonTimeoutMs = 650' "$BRIDGE"; assert_rc "$?" "0" "Virtual Pager bounds delayed button release"
rg -Fq 'const pollTimeoutMs = 6500' "$BRIDGE"; assert_rc "$?" "0" "Virtual Pager uses a low-churn bounded screen request"
rg -Fq 'newWebSession()' "$UI_MAIN"; assert_rc "$?" "0" "Virtual Pager revisions are unique across payload runs"
rg -Fq 'window.addEventListener("pageshow"' "$BRIDGE"; assert_rc "$?" "0" "Virtual Pager reconnects after a browser refresh or history restore"
rg -Fq 'new `defcon-1` can look unchanged' "$BRIDGE"; assert_rc "$?" "0" "Virtual Pager clears stale revisions between payload runs"
rg -Fq 'defcon-defense-active' "$BRIDGE"; assert_rc "$?" "0" "active application bypasses the stock login and loading panels"
rg -Fq -- '--input-device /dev/input/event0' "$UNIFIED"; assert_rc "$?" "0" "native UI reads physical buttons without Pager service input calls"
rg -Fq 'inputStartupDelay     = 250 * time.Millisecond' "$UI_MAIN"; assert_rc "$?" "0" "native UI discards the payload-launch gesture without a visible input stall"
rg -Fq 'inputDeviceLease      = 10 * time.Minute' "$UI_MAIN"; assert_rc "$?" "0" "native UI periodically refreshes the physical input descriptor"
rg -Fq 'screenLongPollTimeout = 5 * time.Second' "$UI_MAIN"; assert_rc "$?" "0" "Virtual Pager idle polling remains bounded and low churn"
rg -Fq 'ownershipGuardWindow  = 8 * time.Second' "$UI_MAIN"; assert_rc "$?" "0" "framebuffer ownership polling is limited to the launch transition"
rg -Fq 'b := a.webPNG' "$UI_MAIN"; assert_rc "$?" "0" "Virtual Pager serves immutable frames without a per-request image copy"
if rg -Fq 'append([]byte(nil), a.webPNG' "$UI_MAIN"; then frame_copy_rc=1; else frame_copy_rc=0; fi
assert_rc "$frame_copy_rc" "0" "Virtual Pager avoids repeated 320 KB screen allocations"
rg -Fq 'canvasToFramebufferInto(canvas, a.frameScratch)' "$UI_MAIN"; assert_rc "$?" "0" "native UI reuses framebuffer conversion storage"
if rg -Fq 'golang.org/x/image/font/opentype' "$UI_MAIN"; then opentype_rc=1; else opentype_rc=0; fi
assert_rc "$opentype_rc" "0" "native UI does not load a TrueType parser for ten status icons"
rg -Fq 'case 304: // BTN_SOUTH - physical red/B on the Pager' "$UI_MAIN"; assert_rc "$?" "0" "physical red button maps to back/exit"
rg -Fq 'case 305: // BTN_EAST - physical green/A on the Pager' "$UI_MAIN"; assert_rc "$?" "0" "physical green button maps to confirm/open"
rg -Fq 'case screenAPWatch:' "$UI_MAIN"; assert_rc "$?" "0" "native UI exposes observed Recon AP selection"
rg -Fq 'case screenWatchList:' "$UI_MAIN"; assert_rc "$?" "0" "native UI exposes the user-maintained watch list"
rg -Fq 'a.queueAction("WATCH", operation' "$UI_MAIN"; assert_rc "$?" "0" "native observed AP selection queues monitoring changes"
rg -q '^process_custom_ui_action()' "$UNIFIED"; assert_rc "$?" "0" "native monitoring selections are applied by the payload backend"
rg -Fq -- '--ready-file "$CUSTOM_UI_READY"' "$UNIFIED"; assert_rc "$?" "0" "monitor workers wait behind the first complete UI frame"
if rg -Fq 'exec.CommandContext(ctx, "WAIT_FOR_INPUT")' "$UI_MAIN"; then ui_wait_rc=1; else ui_wait_rc=0; fi
assert_rc "$ui_wait_rc" "0" "native UI does not create repeated WAIT_FOR_INPUT service requests"
if rg -Fq 'setInterval(refresh' "$BRIDGE"; then bridge_poll_rc=1; else bridge_poll_rc=0; fi
assert_rc "$bridge_poll_rc" "0" "Virtual Pager does not continuously poll unchanged frames"
rg -q 'DEFCON_DEFENSE_NATIVE_UI' "$UNIFIED"; assert_rc "$?" "0" "native list UI remains a safe fallback"
rg -q 'Live RF |.*AP | 2.4 + 5 GHz' "$UNIFIED"; assert_rc "$?" "0" "general screen leads with monitoring state"
rg -q 'Threat Details |.*threat_text' "$UNIFIED"; assert_rc "$?" "0" "general screen exposes threat state in the first viewport"
rg -q 'PCAP Evidence |.*saved' "$UNIFIED"; assert_rc "$?" "0" "general screen exposes saved evidence in the first viewport"
rg -q 'wait_for_input_or_timeout' "$UNIFIED"; assert_rc "$?" "0" "live views use a real refresh timeout wrapper"
rg -q 'BASHPID.*RANDOM' "$UNIFIED"; assert_rc "$?" "0" "concurrent foreground/background Recon refreshes use unique staging paths"
rg -q '^capture_recon_json()' "$UNIFIED"; assert_rc "$?" "0" "PineAP Recon refresh has a bounded watchdog"
rg -q '^refresh_custom_ui_threats()' "$UNIFIED"; assert_rc "$?" "0" "Recon classification is consolidated into one snapshot pass"
rg -Fq 'rf_ui_metrics "$SNAPSHOT" "$threat_snapshot" "$WATCHED_APS"' "$UNIFIED"; assert_rc "$?" "0" "UI counters are consolidated into one metrics pass"
rg -Fq 'UI_STATE.tmp.$state_token' "$UNIFIED"; assert_rc "$?" "0" "background UI state writers use unique atomic staging paths"
if rg -n 'WAIT_FOR_INPUT[[:space:]]+[0-9]' "$UNIFIED" >/dev/null 2>&1; then timed_wait_rc=1; else timed_wait_rc=0; fi
assert_rc "$timed_wait_rc" "0" "firmware input command is never passed an ignored timeout argument"
rg -q 'LIST_PICKER "Live RF Traffic' "$UNIFIED"; assert_rc "$?" "0" "green A selects live traffic through the native picker"
rg -q '^threat_activity_dashboard()' "$UNIFIED"; assert_rc "$?" "0" "Threat Activity has a dedicated live dashboard"
rg -q 'LIST_PICKER "Investigate Threats' "$UNIFIED"; assert_rc "$?" "0" "Investigate Threats uses the native arrow and A/B picker"
rg -q 'LOG red "MALICIOUS TRAFFIC LIVE' "$UNIFIED"; assert_rc "$?" "0" "live malicious indicators render in red"
rg -Fq '"Threat Activity Live") threat_activity_dashboard' "$UNIFIED"; assert_rc "$?" "0" "main menu launches the continuous threat dashboard"
rg -Fq '"$threat_item") investigate_threats' "$UNIFIED"; assert_rc "$?" "0" "general screen opens the separate threat-detail flow"
rg -q '"Browse Recon Networks"' "$UNIFIED"; assert_rc "$?" "0" "normal AP selection is separate from the live dashboard"
rg -q 'Auto-return after 3 refreshes' "$UNIFIED"; assert_rc "$?" "0" "live dashboard cannot trap the operator or drain the battery indefinitely"
rg -q '^threat_detail_view()' "$UNIFIED"; assert_rc "$?" "0" "selected malicious traffic has a dedicated detail interface"
rg -q 'EVIDENCE:.*evidence_state' "$UNIFIED"; assert_rc "$?" "0" "threat detail exposes PCAP capture state"
rg -q 'Auto-save after.*focus_max_seconds' "$UNIFIED"; assert_rc "$?" "0" "focused capture has a battery-safe auto-save limit"
rg -q '_pineap RECON APS' "$UNIFIED"; assert_rc "$?" "0" "live view reads the Pager Recon feed"
rg -q 'PINEAPPLE_EXAMINE_BSSID' "$UNIFIED"; assert_rc "$?" "0" "focused view uses the Pager Recon selector"
rg -q 'pcap_evidence_manual_start' "$UNIFIED"; assert_rc "$?" "0" "focused view saves passive RF evidence"
rg -q '^show_pcap_evidence()' "$UNIFIED"; assert_rc "$?" "0" "saved captures have a dedicated evidence browser"
rg -q '^clear_custom_ui_session()' "$UNIFIED"; assert_rc "$?" "0" "main UI can clear alert and PCAP session data"
rg -q 'CLEAR_SESSION' "$UI_MAIN"; assert_rc "$?" "0" "custom UI exposes the confirmed clear-session action"
rg -q 'Download Loot' "$UNIFIED"; assert_rc "$?" "0" "evidence browser explains later download through Virtual Pager"
rg -q 'Verify SHA-256' "$UNIFIED"; assert_rc "$?" "0" "evidence browser exposes on-demand integrity verification"
rg -q 'pcap_evidence_auto_start' "$OUT/alerts/deauth_flood_detected/defcon_sentry/pcap_evidence_lib.sh"; assert_rc "$?" "0" "confirmed red alerts can start bounded automatic evidence capture"
rg -q '^# Title: DEFCON Defense$' "$UNIFIED"; assert_rc "$?" "0" "package title is DEFCON Defense"
rg -q 'LOG red "THREAT:' "$UNIFIED"; assert_rc "$?" "0" "focused deauth status is prominent red text"
rg -q 'LIVE RF TRAFFIC' "$UNIFIED"; assert_rc "$?" "0" "normal live traffic has its own page"
rg -q 'THREAT ACTIVITY' "$UNIFIED"; assert_rc "$?" "0" "actionable threat traffic has a separate page"
if rg -n 'WIFI_PCAP_START[[:space:]]+"' "$OUT/user/defcon/DEFCON-DEFENSE" >/dev/null 2>&1; then pcap_args_rc=1; else pcap_args_rc=0; fi
assert_rc "$pcap_args_rc" "0" "firmware-native PCAP command is called without unsupported arguments"

# RF-BUDDY ships as its own payload with its own native binary.
file "$OUT/user/defcon/RF-BUDDY/rf-buddy-ui" | grep -q 'ELF 32-bit.*MIPS'
assert_rc "$?" "0" "RF-BUDDY UI is compiled for the Pager MIPS architecture"
assert_eq "$(ls -l "$OUT/user/defcon/RF-BUDDY/rf-buddy-ui" | cut -c1-10)" "-rwxr-xr-x" \
  "RF-BUDDY UI binary is executable"
[ ! -e "$OUT/user/defcon/RF-BUDDY/ui" ]; assert_rc "$?" "0" "RF-BUDDY Go source is not shipped"
[ ! -e "$OUT/user/defcon/RF-BUDDY/virtual-pager-bridge.js" ]; assert_rc "$?" "0" "RF-BUDDY ships no shared bridge"
[ ! -e "$OUT/user/general/DEFCON_DEFENSE" ]; assert_rc "$?" "0" "DEFCON Defense ships only under user/defcon"

# every built payload.sh is syntactically valid
err=0; while IFS= read -r f; do bash -n "$f" || err=1; done < <(find "$OUT" -name '*.sh')
assert_rc "$err" "0" "all built shell scripts pass bash -n"

# built payloads are deterministically non-executable 644 regardless of umask
assert_eq "$(ls -l "$OUT/user/general/PORT_ALERT/payload.sh" | cut -c1-10)" "-rw-r--r--" "built payloads are mode 644"

exit $FAIL
