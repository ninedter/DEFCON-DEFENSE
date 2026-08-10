#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"
. "$ROOT/lib/pager_alert_lib.sh"

TMP="$(mktemp -d)"; SF="$TMP/state.csv"

# insert
state_upsert_row "$SF" "AA|BB" 1 1000 0 1000
assert_eq "$(state_read_row "$SF" 'AA|BB')" "AA|BB,1,1000,0,1000" "insert row"

# update same key (no duplicate)
state_upsert_row "$SF" "AA|BB" 2 1000 1005 1005
assert_eq "$(state_read_row "$SF" 'AA|BB')" "AA|BB,2,1000,1005,1005" "update row"
assert_eq "$(wc -l < "$SF" | tr -d ' ')" "1" "no duplicate rows"

# second key coexists
state_upsert_row "$SF" "CC|DD" 1 2000 0 2000
assert_eq "$(state_read_row "$SF" 'CC|DD')" "CC|DD,1,2000,0,2000" "second key"

# prune drops old last_seen (field 5), keeps recent
state_prune "$SF" 100 2050   # cutoff 1950: AA|BB last_seen 1005 dropped, CC|DD 2000 kept
assert_eq "$(state_read_row "$SF" 'AA|BB')" "" "prune drops stale"
assert_eq "$(state_read_row "$SF" 'CC|DD')" "CC|DD,1,2000,0,2000" "prune keeps fresh"

# with_lock runs the command and its writes persist
with_lock "$TMP/lock" state_upsert_row "$SF" "EE|FF" 3 3000 3000 3000
assert_eq "$(state_read_row "$SF" 'EE|FF')" "EE|FF,3,3000,3000,3000" "with_lock persists writes"

# with_lock must not permanently clobber the caller's stderr (regression)
ERRLOG="$TMP/err"
( with_lock "$TMP/lock2" true
  echo "stderr-after-lock" >&2
) 2>"$ERRLOG"
assert_eq "$(cat "$ERRLOG")" "stderr-after-lock" "with_lock preserves caller stderr"

exit $FAIL
