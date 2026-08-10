#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

PDIR="$ROOT/src/deauth_flood_detected/defcon_sentry"
# syntax
bash -n "$PDIR/payload.sh"; assert_rc "$?" "0" "payload.sh passes bash -n"

# integration: run payload.sh with lib beside it, stubs on PATH via a wrapper
TMP="$(mktemp -d)"; export REC="$TMP/rec"; : > "$REC"; export STATE_DIR="$TMP/state"
cp "$ROOT/lib/pager_alert_lib.sh" "$PDIR/pager_alert_lib.sh"   # build.sh does this on real deploy
BIN="$TMP/bin"; mkdir -p "$BIN"
for c in ALERT RINGTONE VIBRATE LED LOG; do
  printf '#!/bin/bash\nprintf "%s\\t%%s\\n" "$*" >> "%s"\n' "$c" "$REC" > "$BIN/$c"
  chmod +x "$BIN/$c"
done
run() { NOW_OVERRIDE="$1" PATH="$BIN:$PATH" bash "$PDIR/payload.sh"; }

# default config is threshold 3 / window 120 / cooldown 300
export _ALERT_DENIAL_SOURCE_MAC_ADDRESS="AA:BB:CC:00:00:09"
export _ALERT_DENIAL_AP_MAC_ADDRESS="DE:AD:BE:EF:00:09"
run 5000; run 5001; run 5002
assert_eq "$(grep -c '^ALERT' "$REC")" "1" "payload fires once at threshold end-to-end"

rm -f "$PDIR/pager_alert_lib.sh"   # keep source dir clean (lib is build-injected)
exit $FAIL
