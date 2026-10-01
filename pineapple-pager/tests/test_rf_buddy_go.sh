#!/bin/bash
# Host-side Go tests, Pager-target vet, preview rendering, and a passive-only
# source check for the RF-BUDDY UI.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

UI="$ROOT/src/user/defcon/RF-BUDDY/ui"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rf-buddy-go.XXXXXX")"
cleanup() { [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT

command -v go >/dev/null 2>&1; assert_rc "$?" "0" "Go toolchain is available"

(cd "$UI" && go test -mod=vendor -race ./...)
assert_rc "$?" "0" "RF-BUDDY Go unit tests pass"

(cd "$UI" && CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat go vet -mod=vendor ./...)
assert_rc "$?" "0" "RF-BUDDY vets for the Pager MIPS target"

(cd "$UI" && go run -mod=vendor . -preview-dir "$TMP/previews")
assert_rc "$?" "0" "RF-BUDDY renders preview screens"
assert_eq "$(find "$TMP/previews" -name '*.png' | wc -l | tr -d ' ')" "9" "all nine preview states rendered"

command -v rg >/dev/null 2>&1; assert_rc "$?" "0" "rg is available for the passive-only check"
rg -n -g '!*_test.go' -g '!vendor/**' -e 'Sendto|Sendmsg|syscall\.Write|txpower|PINEAPPLE_DEAUTH|aireplay|mdk[34]|"set", "channel"' "$UI" >/dev/null 2>&1
rg_rc=$?
case "$rg_rc" in
  1) passive_rc=0 ;;
  0) passive_rc=1 ;;
  *) passive_rc=2 ;;
esac
assert_rc "$passive_rc" "0" "RF-BUDDY source never transmits or retunes outside PineAP"

rg -q -- '"--passive"' "$UI/bluetooth.go"; assert_rc "$?" "0" "BLE scan is passive"

exit "$FAIL"
