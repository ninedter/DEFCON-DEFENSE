#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

PAYLOAD="$ROOT/src/user/defcon/RF-BUDDY/payload.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rf-buddy-test.XXXXXX")"
cleanup() { [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT
REC="$TMP/recorder.log"
: > "$REC"

LOG()          { printf 'LOG\t%s\n' "$*" >> "$REC"; }
ERROR_DIALOG() { printf 'ERROR\t%s\n' "$*" >> "$REC"; }
RINGTONE()     { printf 'RINGTONE\t%s\n' "$*" >> "$REC"; return "${RINGTONE_RC:-0}"; }
VIBRATE()      { printf 'VIBRATE\t%s\n' "$*" >> "$REC"; }
killall()      { printf 'KILLALL\t%s\n' "$*" >> "$REC"; }
hcitool()      { printf 'HCITOOL\t%s\n' "$*" >> "$REC"; }
_pineap()      { printf 'PINEAP\t%s\n' "$*" >> "$REC"; }
export -f LOG ERROR_DIALOG RINGTONE VIBRATE killall hcitool _pineap
export REC

export RF_BUDDY_INSTALL_DIR="$ROOT/src/user/defcon/RF-BUDDY"
export RF_BUDDY_LOOT_DIR="$TMP/loot"
export RF_BUDDY_RUN_DIR="$TMP/run"
export RF_BUDDY_LOCK_DIR="$TMP/rf_buddy.lock"

bash -n "$PAYLOAD"; assert_rc "$?" "0" "payload.sh passes bash -n"
rg -q '^# Title: RF-BUDDY$' "$PAYLOAD"; assert_rc "$?" "0" "payload title is RF-BUDDY"
rg -q '^OFFICE_SSID=""' "$PAYLOAD"; assert_rc "$?" "0" "OFFICE_SSID is configurable and blank by default"

# --- functions, sourced without running -----------------------------------
RF_BUDDY_SOURCE_ONLY=1 . "$PAYLOAD"
mkdir -p "$RF_BUDDY_RUN_DIR"

rf_lock_acquire; assert_rc "$?" "0" "first instance takes the lock"
( LOCKED=0; rf_lock_acquire ); assert_rc "$?" "1" "second instance is refused while the owner is alive"
rf_lock_release
[ ! -d "$RF_BUDDY_LOCK_DIR" ]; assert_rc "$?" "0" "lock is released"
mkdir -p "$RF_BUDDY_LOCK_DIR"; echo 999999 > "$RF_BUDDY_LOCK_DIR/pid"
rf_lock_acquire; assert_rc "$?" "0" "stale lock from a dead owner is replaced"
rf_lock_release

: > "$REC"
release_channel
assert_eq "$(tr '\t' ' ' < "$REC")" "PINEAP EXAMINE CANCEL" "channel lock is handed back to Recon"

: > "$REC"
RINGTONE_RC=1 tick_once
assert_eq "$(cut -f1 "$REC" | paste -sd'|' -)" "RINGTONE|VIBRATE" "tick falls back to a vibration when the ringtone fails"

: > "$REC"
rf_lock_acquire
echo 1150 > "$TICK_FILE"
rf_buddy_cleanup
rf_buddy_cleanup
[ ! -d "$RF_BUDDY_LOCK_DIR" ]; assert_rc "$?" "0" "cleanup releases the lock"
[ ! -f "$TICK_FILE" ]; assert_rc "$?" "0" "cleanup removes the tick file"
assert_eq "$(grep -c 'EXAMINE CANCEL' "$REC")" "1" "cleanup releases the channel exactly once"
assert_eq "$(grep -c $'^KILLALL\t-INT hcitool$' "$REC")" "1" "cleanup interrupts the BLE scan"
assert_eq "$(grep -c $'^HCITOOL\t-i hci0 cmd 0x08 0x000c 00 00$' "$REC")" "1" "cleanup disables LE scanning"

# --- full run with a fake UI binary ----------------------------------------
FAKE_UI="$TMP/fake-ui"
cat > "$FAKE_UI" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_UI_ARGS"
[ -d "$RF_BUDDY_LOCK_DIR" ] && echo LOCK_HELD >> "$FAKE_UI_ARGS"
exit 0
EOF
chmod +x "$FAKE_UI"
export RF_BUDDY_UI_BINARY="$FAKE_UI" FAKE_UI_ARGS="$TMP/ui-args"

: > "$REC"
bash "$PAYLOAD"; assert_rc "$?" "0" "payload runs the UI and exits cleanly"
for arg in --framebuffer /dev/fb0 --iface wlan1mon --office-ssid --tick-file --loot-dir --retry-high-pct --airtime-high-pct LOCK_HELD; do
  grep -qx -- "$arg" "$FAKE_UI_ARGS"; assert_rc "$?" "0" "UI launched with $arg"
done
[ ! -d "$RF_BUDDY_LOCK_DIR" ]; assert_rc "$?" "0" "lock is released after a normal exit"
grep -q 'EXAMINE CANCEL' "$REC"; assert_rc "$?" "0" "channel lock is released after the run"
if grep -q 'RECON STOP' "$REC"; then recon_rc=1; else recon_rc=0; fi
assert_rc "$recon_rc" "0" "Recon itself is never stopped"

: > "$REC"; rm -f "$FAKE_UI_ARGS"
mkdir -p "$RF_BUDDY_LOCK_DIR"; echo "$$" > "$RF_BUDDY_LOCK_DIR/pid"
bash "$PAYLOAD"; assert_rc "$?" "0" "refused second instance exits 0"
grep -q 'already running' "$REC"; assert_rc "$?" "0" "second instance tells the operator"
[ ! -f "$FAKE_UI_ARGS" ]; assert_rc "$?" "0" "second instance does not start a UI"
[ -d "$RF_BUDDY_LOCK_DIR" ]; assert_rc "$?" "0" "second instance leaves the owner's lock alone"
if grep -q 'EXAMINE' "$REC"; then touch_rc=1; else touch_rc=0; fi
assert_rc "$touch_rc" "0" "second instance does not touch the radio"
rm -rf "$RF_BUDDY_LOCK_DIR"

if rg -n 'PINEAPPLE_DEAUTH|aireplay|mdk[34]|txpower|RECON STOP|HOPPING_STOP' "$PAYLOAD" >/dev/null 2>&1; then passive_rc=1; else passive_rc=0; fi
assert_rc "$passive_rc" "0" "payload never transmits or stops Recon"

exit "$FAIL"
