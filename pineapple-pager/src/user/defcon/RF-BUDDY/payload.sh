#!/bin/bash
# Title: RF-BUDDY
# Description: Passive 2.4/5 GHz interference finder: live channel meter, lock-on tracking, and survey log.
# Author: Henry Hu
# Version: 1.0
# Category: DEFCON
#
# Walk the office with this running. The overview ranks every channel; lock on
# to the worst one and follow the score toward the source. Recon keeps running;
# RF-BUDDY only locks it to one channel at a time and hands the channel back on
# every exit path. Nothing is ever transmitted.

# ---- CONFIG ----------------------------------------------------------------
OFFICE_SSID=""            # your office SSID; enables WEAK COVERAGE (blank = off)
DWELL_MS=250              # overview dwell per channel, milliseconds
RETRY_HIGH_PCT=25         # retry % at/above this on a quiet channel -> INTERFERENCE
AIRTIME_HIGH_PCT=50       # Wi-Fi airtime % at/above this -> CONGESTION
OVERLAP_MIN_DBM=-70       # neighbour AP louder than this -> CHANNEL OVERLAP
BT_DENSE_COUNT=30         # nearby BLE devices for BT DENSE
WEAK_SIGNAL_DBM=-70       # office AP quieter than this -> WEAK COVERAGE
LOG_MAX_MB=20             # per-session log cap
MIN_FREE_MB=64            # pause logging below this much free storage
TICK_RINGTONE="tick"      # short ringtone for the lock-on tick (falls back to a 40 ms vibration)
# ----------------------------------------------------------------------------

PAYLOAD_ROOT="/root/payloads"
# The Pager payload runner may execute payload.sh from a temporary directory,
# so prefer the stable installed payload path for the UI binary.
INSTALLED_DIR="${RF_BUDDY_INSTALL_DIR:-$PAYLOAD_ROOT/user/defcon/RF-BUDDY}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -f "$INSTALLED_DIR/payload.sh" ]; then
  DIR="$INSTALLED_DIR"
else
  DIR="$SOURCE_DIR"
fi
UI_BINARY="${RF_BUDDY_UI_BINARY:-$DIR/rf-buddy-ui}"
UI_BRIDGE_SOURCE="$DIR/virtual-pager-bridge.js"
LOOT_ROOT="${RF_BUDDY_LOOT_DIR:-/root/loot/rf_buddy}"
RUN_DIR="${RF_BUDDY_RUN_DIR:-/tmp/rf_buddy}"
LOCK_DIR="${RF_BUDDY_LOCK_DIR:-/tmp/rf_buddy.lock}"
MON_IFACE="wlan1mon"
BT_IFACE="hci0"
TICK_FILE="$RUN_DIR/tick_ms"
READY_FILE="$RUN_DIR/ready"

UI_PID=""
TICK_PID=""
LOCKED=0
CLEANED=0

rf_lock_acquire() {
  local owner=""
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCKED=1
    return 0
  fi
  [ -f "$LOCK_DIR/pid" ] && owner="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  [ -n "$owner" ] || return 1
  if printf '%s' "$owner" | grep -Eq '^[0-9]+$' && kill -0 "$owner" 2>/dev/null; then
    return 1
  fi
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  LOCKED=1
}

rf_lock_release() {
  [ "$LOCKED" = "1" ] || return 0
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  LOCKED=0
}

# Hand the channel back to normal Recon hopping. The UI binary also does this
# on exit; repeating it here covers crashes and kills.
release_channel() {
  _pineap EXAMINE CANCEL >/dev/null 2>&1 || true
}

tick_once() {
  RINGTONE "$TICK_RINGTONE" >/dev/null 2>&1 || VIBRATE 40 >/dev/null 2>&1 || true
}

# The UI writes the lock-on tick interval in ms (0 = off) to $TICK_FILE.
tick_loop() {
  local ms secs
  while :; do
    ms="$(cat "$TICK_FILE" 2>/dev/null)"
    case "$ms" in ''|*[!0-9]*) ms=0 ;; esac
    if [ "$ms" -gt 0 ]; then
      tick_once
      secs="$((ms / 1000)).$(printf '%03d' $((ms % 1000)))"
      sleep "$secs"
    else
      sleep 0.25
    fi
  done
}

# Same idempotent Virtual Pager bridge DEFCON-DEFENSE installs; it mirrors
# whichever full-screen app is serving on port 1472.
install_virtual_pager_bridge() {
  local ui_root="/pineapple/ui"
  local index="$ui_root/index.html"
  local target="$ui_root/defcon-ui-bridge.js"
  local inline="$ui_root/defcon-ui-bridge.inline"
  local tmp="$ui_root/index.html.defcon-defense.tmp"
  [ -f "$UI_BRIDGE_SOURCE" ] && [ -f "$index" ] || return 1
  cp "$UI_BRIDGE_SOURCE" "$target" || return 1
  if grep -Fq '__defconDefenseBridgeVersion = "4.3.1"' "$index"; then
    return 0
  fi
  [ -f "$ui_root/index.html.defcon-defense-backup" ] || \
    cp "$index" "$ui_root/index.html.defcon-defense-backup" || return 1
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

rf_buddy_cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  if [ -n "$TICK_PID" ] && kill -0 "$TICK_PID" 2>/dev/null; then
    kill "$TICK_PID" 2>/dev/null || true
    wait "$TICK_PID" 2>/dev/null || true
  fi
  TICK_PID=""
  if [ -n "$UI_PID" ] && kill -0 "$UI_PID" 2>/dev/null; then
    kill "$UI_PID" 2>/dev/null || true
    wait "$UI_PID" 2>/dev/null || true
  fi
  UI_PID=""
  killall hcitool >/dev/null 2>&1 || true
  rm -f "$TICK_FILE" "$TICK_FILE.tmp" "$READY_FILE"
  release_channel
  rf_lock_release
}

rf_buddy_main() {
  local rc=0
  mkdir -p "$RUN_DIR" "$LOOT_ROOT"
  if [ ! -x "$UI_BINARY" ]; then
    ERROR_DIALOG "RF-BUDDY is incomplete:\nmissing rf-buddy-ui"
    return 1
  fi
  if ! rf_lock_acquire; then
    ERROR_DIALOG "RF-BUDDY is already running."
    return 0
  fi
  trap rf_buddy_cleanup EXIT
  trap 'rf_buddy_cleanup; exit 130' INT
  trap 'rf_buddy_cleanup; exit 143' TERM
  trap 'rf_buddy_cleanup; exit 129' HUP

  LOG "RF-BUDDY: Recon stays on; locked to one channel at a time."
  install_virtual_pager_bridge >/dev/null 2>&1 || true
  echo 0 > "$TICK_FILE"
  tick_loop &
  TICK_PID=$!

  "$UI_BINARY" \
    --framebuffer /dev/fb0 \
    --input-device /dev/input/event0 \
    --ready-file "$READY_FILE" \
    --iface "$MON_IFACE" \
    --bt-iface "$BT_IFACE" \
    --loot-dir "$LOOT_ROOT" \
    --tick-file "$TICK_FILE" \
    --office-ssid "$OFFICE_SSID" \
    --dwell-ms "$DWELL_MS" \
    --log-max-mb "$LOG_MAX_MB" \
    --min-free-mb "$MIN_FREE_MB" \
    --retry-high-pct "$RETRY_HIGH_PCT" \
    --airtime-high-pct "$AIRTIME_HIGH_PCT" \
    --overlap-min-dbm "$OVERLAP_MIN_DBM" \
    --bt-dense-count "$BT_DENSE_COUNT" \
    --weak-signal-dbm "$WEAK_SIGNAL_DBM" &
  UI_PID=$!
  wait "$UI_PID"
  rc=$?
  UI_PID=""
  rf_buddy_cleanup
  return "$rc"
}

if [ "${RF_BUDDY_SOURCE_ONLY:-0}" != "1" ]; then
  rf_buddy_main
  exit $?
fi
