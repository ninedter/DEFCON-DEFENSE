#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"
. "$ROOT/lib/pager_alert_lib.sh"

# now_epoch honors override
assert_eq "$(NOW_OVERRIDE=12345 now_epoch)" "12345" "now_epoch uses NOW_OVERRIDE"

# sanitize_mac: lowercase->upper, strip spaces, keep colons
assert_eq "$(sanitize_mac '  aa:bb:cc:dd:ee:ff ')" "AA:BB:CC:DD:EE:FF" "sanitize_mac normalizes"
assert_eq "$(sanitize_mac '')" "" "sanitize_mac empty"

# is_randomized_mac: DA (nibble A) => randomized; AA (nibble A) => randomized; A8 (nibble 8) => not
is_randomized_mac "DA:11:22:33:44:55"; assert_rc "$?" "0" "randomized nibble A"
is_randomized_mac "A2:11:22:33:44:55"; assert_rc "$?" "0" "randomized nibble 2"
is_randomized_mac "A8:11:22:33:44:55"; assert_rc "$?" "1" "not randomized nibble 8"
is_randomized_mac "";                  assert_rc "$?" "1" "empty not randomized"

exit $FAIL
