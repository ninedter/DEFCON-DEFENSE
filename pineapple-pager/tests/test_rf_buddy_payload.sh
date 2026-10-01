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
# Fake stock UI: pidof reports a fake pid when FAKE_PINEAPPLE_PID is set; kill
# records every call and never signals the fake pid (real pids pass through).
pidof() { [ -n "${FAKE_PINEAPPLE_PID:-}" ] && [ "${1:-}" = "pineapple" ] && { echo "$FAKE_PINEAPPLE_PID"; return 0; }; return 1; }
kill() {
  printf 'KILL\t%s\n' "$*" >> "$REC"
  local a
  for a in "$@"; do
    [ -n "${FAKE_PINEAPPLE_PID:-}" ] && [ "$a" = "$FAKE_PINEAPPLE_PID" ] && return 0
  done
  builtin kill "$@"
}
export -f LOG ERROR_DIALOG RINGTONE VIBRATE killall hcitool _pineap pidof kill
export REC

export RF_BUDDY_INSTALL_DIR="$ROOT/src/user/defcon/RF-BUDDY"
export RF_BUDDY_LOOT_DIR="$TMP/loot"
export RF_BUDDY_RUN_DIR="$TMP/run"
export RF_BUDDY_LOCK_DIR="$TMP/rf_buddy.lock"

rg -q '/mmc/root/payloads/user/defcon/RF-BUDDY' "$PAYLOAD"; assert_rc "$?" "0" "payload falls back to the /mmc install path"
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
rf_lock_acquire
FROZEN_PIDS=""
rf_buddy_cleanup
rf_buddy_cleanup
[ ! -d "$RF_BUDDY_LOCK_DIR" ]; assert_rc "$?" "0" "cleanup releases the lock"
assert_eq "$(grep -c 'EXAMINE CANCEL' "$REC")" "1" "cleanup releases the channel exactly once"
if grep -Eq '^(KILLALL|HCITOOL|RINGTONE|VIBRATE)' "$REC"; then x=1; else x=0; fi
assert_rc "$x" "0" "cleanup runs no killall/hcitool/ringtone (the binary stops its own scan)"

# stock UI freeze/resume
export FAKE_PINEAPPLE_PID=4242
: > "$REC"
stock_ui_freeze; assert_rc "$?" "0" "freeze succeeds"
assert_eq "$FROZEN_PIDS" "4242" "freeze remembers the frozen pids"
assert_eq "$(grep -c $'^KILL\t-STOP 4242$' "$REC")" "1" "freeze sends SIGSTOP"
stock_ui_resume
stock_ui_resume
assert_eq "$FROZEN_PIDS" "" "resume clears the frozen pids"
assert_eq "$(grep -c $'^KILL\t-CONT 4242$' "$REC")" "1" "resume sends SIGCONT exactly once (idempotent)"
unset FAKE_PINEAPPLE_PID
: > "$REC"
stock_ui_freeze; assert_rc "$?" "0" "freeze is a no-op when no stock UI runs"
assert_eq "$(grep -c STOP "$REC")" "0" "no SIGSTOP without a stock UI"
FAKE_INITD="$TMP/fake-initd"
printf '#!/bin/sh\necho "$1" >> "%s/initd.log"\n' "$TMP" > "$FAKE_INITD"; chmod +x "$FAKE_INITD"
RF_BUDDY_PINEAPPLE_INITD="$FAKE_INITD" stock_ui_resume
assert_eq "$(cat "$TMP/initd.log" 2>/dev/null)" "start" "resume starts the stock UI via init.d when it is gone"
export FAKE_PINEAPPLE_PID=4242
rm -f "$TMP/initd.log"
RF_BUDDY_PINEAPPLE_INITD="$FAKE_INITD" stock_ui_resume
[ ! -f "$TMP/initd.log" ]; assert_rc "$?" "0" "resume does not start a second stock UI"
unset FAKE_PINEAPPLE_PID

# cleanup resumes a frozen UI before handing the channel back
export FAKE_PINEAPPLE_PID=4242
: > "$REC"; CLEANED=0
rf_lock_acquire
FROZEN_PIDS=4242
rf_buddy_cleanup
cont_line="$(grep -n $'^KILL\t-CONT 4242$' "$REC" | head -1 | cut -d: -f1)"
cancel_line="$(grep -n 'EXAMINE CANCEL' "$REC" | head -1 | cut -d: -f1)"
[ -n "$cont_line" ] && [ -n "$cancel_line" ] && [ "$cont_line" -lt "$cancel_line" ]; assert_rc "$?" "0" "cleanup resumes the stock UI before releasing the channel"
unset FAKE_PINEAPPLE_PID

# --- full run with a fake UI binary ----------------------------------------
FAKE_UI="$TMP/fake-ui"
cat > "$FAKE_UI" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_UI_ARGS"
[ -d "$RF_BUDDY_LOCK_DIR" ] && echo LOCK_HELD >> "$FAKE_UI_ARGS"
# PATH_EXPORTED=1 only when the parent really exported PATH to us.
case "$(declare -p PATH 2>/dev/null)" in "declare -x"*) echo PATH_EXPORTED=1 >> "$FAKE_UI_ARGS" ;; esac
echo "PATH=$PATH" >> "$FAKE_UI_ARGS"
ready=""
while [ $# -gt 0 ]; do [ "$1" = "--ready-file" ] && ready="$2"; shift; done
[ -n "$ready" ] && echo ready > "$ready"
printf 'UIREADY\t-\n' >> "$REC"
if [ -n "${FAKE_UI_LONG:-}" ]; then
  echo $$ > "$TMP/ui.pid"
  exec sleep 30
fi
sleep 0.4
exit 0
EOF
chmod +x "$FAKE_UI"
export TMP
export RF_BUDDY_UI_BINARY="$FAKE_UI" FAKE_UI_ARGS="$TMP/ui-args"
export FAKE_PINEAPPLE_PID=4242
BUZ="$TMP/buzzer"; mkdir -p "$BUZ"; echo 255 > "$BUZ/brightness"
export RF_BUDDY_BUZZER_DIR="$BUZ"

: > "$REC"
bash "$PAYLOAD"; assert_rc "$?" "0" "payload runs the UI and exits cleanly"
for arg in --framebuffer /dev/fb0 --iface wlan1mon --office-ssid --loot-dir --retry-high-pct --airtime-high-pct --tick-freq-hz 2000 --tick-volume 128 LOCK_HELD; do
  grep -qx -- "$arg" "$FAKE_UI_ARGS"; assert_rc "$?" "0" "UI launched with $arg"
done
if grep -qx -- '--tick-file' "$FAKE_UI_ARGS"; then x=1; else x=0; fi
assert_rc "$x" "0" "UI is not passed the removed --tick-file"
[ ! -d "$RF_BUDDY_LOCK_DIR" ]; assert_rc "$?" "0" "lock is released after a normal exit"
grep -q 'EXAMINE CANCEL' "$REC"; assert_rc "$?" "0" "channel lock is released after the run"
if grep -q 'RECON STOP' "$REC"; then recon_rc=1; else recon_rc=0; fi
assert_rc "$recon_rc" "0" "Recon itself is never stopped"
assert_eq "$(cat "$BUZ/brightness")" "0" "cleanup forces the buzzer off"

ready_l="$(grep -n '^UIREADY' "$REC" | head -1 | cut -d: -f1)"
stop_l="$(grep -n $'^KILL\t-STOP 4242$' "$REC" | head -1 | cut -d: -f1)"
cont_l="$(grep -n $'^KILL\t-CONT 4242$' "$REC" | head -1 | cut -d: -f1)"
cancel_l="$(grep -n 'EXAMINE CANCEL' "$REC" | head -1 | cut -d: -f1)"
[ -n "$ready_l" ] && [ -n "$stop_l" ] && [ "$ready_l" -lt "$stop_l" ]; assert_rc "$?" "0" "stock UI is frozen only after the UI is ready"
[ -n "$stop_l" ] && [ -n "$cont_l" ] && [ "$stop_l" -lt "$cont_l" ]; assert_rc "$?" "0" "stock UI is resumed after it was frozen"
[ -n "$cont_l" ] && [ -n "$cancel_l" ] && [ "$cont_l" -lt "$cancel_l" ]; assert_rc "$?" "0" "stock UI is resumed before the channel is released"
between="$(sed -n "${stop_l:-1},${cont_l:-1}p" "$REC" | grep -Ec '^(LOG|ERROR|RINGTONE|VIBRATE)')"
assert_eq "$between" "0" "no hak5 API call between SIGSTOP and SIGCONT"
assert_eq "$(grep -c $'^KILL\t-CONT ' "$REC")" "1" "watchdog does not fire a second SIGCONT after a normal run"
sleep 1.5
assert_eq "$(grep -c $'^KILL\t-CONT ' "$REC")" "1" "watchdog is gone: still exactly one SIGCONT"
assert_eq "$(grep -c 'EXAMINE CANCEL' "$REC")" "1" "watchdog does not release the channel a second time"
log_l="$(grep -n '^LOG' "$REC" | head -1 | cut -d: -f1)"
[ -n "$log_l" ] && [ -n "$stop_l" ] && [ "$log_l" -lt "$stop_l" ]; assert_rc "$?" "0" "the startup LOG happens before the freeze"

# clean-exit marker is kept after normal cleanup
[ -e "$RF_BUDDY_RUN_DIR/clean-exit" ]; assert_rc "$?" "0" "clean-exit marker is kept after normal cleanup"

# second normal run: clean-exit marker is handled correctly
: > "$REC"; rm -f "$FAKE_UI_ARGS"
bash "$PAYLOAD"; assert_rc "$?" "0" "second normal run completes cleanly"
[ -e "$RF_BUDDY_RUN_DIR/clean-exit" ]; assert_rc "$?" "0" "clean-exit marker is kept after second normal cleanup"
[ ! -d "$RF_BUDDY_LOCK_DIR" ]; assert_rc "$?" "0" "lock is released after second normal exit"
unset FAKE_PINEAPPLE_PID

# Parent shell without an exported PATH (as the Pager runner starts payloads).
: > "$REC"; rm -f "$FAKE_UI_ARGS"
BASH_BIN="$(command -v bash)"
env -u PATH "$BASH_BIN" "$PAYLOAD"; assert_rc "$?" "0" "payload runs with PATH removed from the environment"
grep -qx 'PATH_EXPORTED=1' "$FAKE_UI_ARGS"; assert_rc "$?" "0" "UI inherits an exported PATH even when the runner had none"
grep -Eq '^PATH=.+' "$FAKE_UI_ARGS"; assert_rc "$?" "0" "UI sees a non-empty PATH"

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

if grep -Eq 'pineapple/ui|bridge|killall|1472|RINGTONE|TICK_FILE|tick_loop' "$PAYLOAD"; then shared_rc=1; else shared_rc=0; fi
assert_rc "$shared_rc" "0" "payload touches no shared UI, bridge, port 1472, ringtone or killall"

# --- freeze-safety hardening -----------------------------------------------
# cleanup must not be interruptible by a signal.
[ "$(declare -f rf_buddy_cleanup | sed -n 3p | tr -d ' ;')" = "trap''INTTERMHUP" ]
assert_rc "$?" "0" "rf_buddy_cleanup begins with trap '' INT TERM HUP"
: > "$REC"; export FAKE_PINEAPPLE_PID=4242; rm -f "$TMP/survived"
(
  trap 'exit 143' TERM
  stop_ui() { bash -c 'kill -TERM $PPID'; sleep 0.3; }
  CLEANED=0; FROZEN_PIDS=4242; rf_lock_acquire
  rf_buddy_cleanup
  [ ! -d "$RF_BUDDY_LOCK_DIR" ] && echo ok > "$TMP/survived"
)
assert_eq "$(cat "$TMP/survived" 2>/dev/null)" "ok" "a TERM during cleanup does not cut cleanup short"
assert_eq "$(grep -c $'^KILL\t-CONT 4242$' "$REC")" "1" "TERM during cleanup: stock UI still resumed"
assert_eq "$(grep -c 'EXAMINE CANCEL' "$REC")" "1" "TERM during cleanup: channel still released"
unset FAKE_PINEAPPLE_PID

# freeze records the pids before STOP and keeps them when STOP fails.
(
  pidof() { echo "111 222"; }
  kill() { return 1; }
  FROZEN_PIDS=""; stock_ui_freeze; rc=$?
  echo "$rc:$FROZEN_PIDS" > "$TMP/freeze-fail"
)
assert_eq "$(cat "$TMP/freeze-fail")" "1:111 222" "failed SIGSTOP returns 1 but keeps the pids for resume"

# SIGKILL of payload.sh: the watchdog must undo the freeze on its own.
# The watchdog runs as a separate (setsid when present) bash process; the
# record/forward stubs reach it as exported functions, which bash children
# import from the environment.
: > "$REC"; rm -f "$TMP/ui.pid"
export FAKE_PINEAPPLE_PID=4242 FAKE_UI_LONG=1
echo 255 > "$BUZ/brightness"
bash "$PAYLOAD" >/dev/null 2>&1 &
ppid_=$!
i=0
while ! grep -q $'^KILL\t-STOP 4242$' "$REC" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -q $'^KILL\t-STOP 4242$' "$REC"; assert_rc "$?" "0" "SIGKILL test: stock UI was frozen"
sleep 0.5
uipid_="$(cat "$TMP/ui.pid" 2>/dev/null)"
builtin kill -9 "$ppid_" 2>/dev/null
wait "$ppid_" 2>/dev/null
i=0
while [ -d "$RF_BUDDY_LOCK_DIR" ] && [ "$i" -lt 80 ]; do sleep 0.1; i=$((i + 1)); done
[ ! -d "$RF_BUDDY_LOCK_DIR" ]; assert_rc "$?" "0" "SIGKILL test: watchdog removes the lock"
assert_eq "$(grep -c $'^KILL\t-CONT 4242$' "$REC")" "1" "SIGKILL test: watchdog resumes the stock UI"
grep -q 'EXAMINE CANCEL' "$REC"; assert_rc "$?" "0" "SIGKILL test: watchdog releases the channel"
sleep 0.3
if [ -n "$uipid_" ] && builtin kill -0 "$uipid_" 2>/dev/null; then x=1; else x=0; fi
assert_rc "$x" "0" "SIGKILL test: watchdog terminated the orphaned UI"
[ -n "$uipid_" ] && builtin kill -9 "$uipid_" 2>/dev/null
assert_eq "$(cat "$BUZ/brightness")" "0" "SIGKILL test: watchdog forces the buzzer off"
unset FAKE_PINEAPPLE_PID FAKE_UI_LONG

# --- forking setsid (BusyBox/util-linux fork when the caller leads its group) -
# $! then names a short-lived setsid parent, not the watchdog. The watchdog
# must be tracked by its own pid file and honour the clean-exit marker.
FSBIN="$TMP/fakesetsid"; mkdir -p "$FSBIN"
printf '#!/bin/bash\n"$@" &\nexit 0\n' > "$FSBIN/setsid"; chmod +x "$FSBIN/setsid"
: > "$REC"; export FAKE_PINEAPPLE_PID=4242; unset FAKE_UI_LONG
echo 255 > "$BUZ/brightness"
PATH="$FSBIN:$PATH" bash "$PAYLOAD"; assert_rc "$?" "0" "forking setsid: payload exits cleanly"
sleep 2
assert_eq "$(grep -c $'^KILL\t-CONT ' "$REC")" "1" "forking setsid: watchdog did not fire a second SIGCONT"
assert_eq "$(grep -c 'EXAMINE CANCEL' "$REC")" "1" "forking setsid: watchdog did not release the channel again"
[ ! -e "$RF_BUDDY_RUN_DIR/watchdog.pid" ] && [ -e "$RF_BUDDY_RUN_DIR/clean-exit" ]; assert_rc "$?" "0" "forking setsid: watchdog.pid removed, clean-exit marker kept"

: > "$REC"; rm -f "$TMP/ui.pid"
export FAKE_UI_LONG=1
echo 255 > "$BUZ/brightness"
PATH="$FSBIN:$PATH" bash "$PAYLOAD" >/dev/null 2>&1 &
ppid_=$!
i=0
while ! grep -q $'^KILL\t-STOP 4242$' "$REC" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.5
uipid_="$(cat "$TMP/ui.pid" 2>/dev/null)"
builtin kill -9 "$ppid_" 2>/dev/null
wait "$ppid_" 2>/dev/null
i=0
while [ -d "$RF_BUDDY_LOCK_DIR" ] && [ "$i" -lt 80 ]; do sleep 0.1; i=$((i + 1)); done
[ ! -d "$RF_BUDDY_LOCK_DIR" ]; assert_rc "$?" "0" "forking setsid SIGKILL: watchdog removes the lock"
assert_eq "$(grep -c $'^KILL\t-CONT 4242$' "$REC")" "1" "forking setsid SIGKILL: watchdog resumes the stock UI"
grep -q 'EXAMINE CANCEL' "$REC"; assert_rc "$?" "0" "forking setsid SIGKILL: watchdog releases the channel"
[ -n "$uipid_" ] && builtin kill -9 "$uipid_" 2>/dev/null
unset FAKE_PINEAPPLE_PID FAKE_UI_LONG

exit "$FAIL"
