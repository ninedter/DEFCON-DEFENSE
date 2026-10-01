#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/defcon-package-test.XXXXXX")"
cleanup() { [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT

DIST="$TMP/dist" bash "$ROOT/package.sh" >/dev/null
assert_rc "$?" "0" "package.sh succeeds"

ARCHIVE="$TMP/dist/pager-defcon-defense-unified.tar.gz"
MANIFEST="$TMP/dist/payload-manifest.sha256"
[ -f "$ARCHIVE" ]; assert_rc "$?" "0" "deployable archive exists"
[ -f "$MANIFEST" ]; assert_rc "$?" "0" "checksum manifest exists"

bad_metadata="$(tar -tzf "$ARCHIVE" | awk '/(^|\/)\._|(^|\/)\.DS_Store$/{count++} END{print count+0}')"
assert_eq "$bad_metadata" "0" "archive excludes macOS metadata"

mkdir -p "$TMP/extracted"
tar -xzf "$ARCHIVE" -C "$TMP/extracted"
(cd "$TMP/extracted" && shasum -a 256 -c "$MANIFEST" >/dev/null)
assert_rc "$?" "0" "archive contents match manifest"

tar -tzf "$ARCHIVE" | grep -q '^\./user/defcon/RF-BUDDY/rf-buddy-ui$'
assert_rc "$?" "0" "archive ships RF-BUDDY under user/defcon"
tar -tzf "$ARCHIVE" | grep -q '^\./user/defcon/DEFCON-DEFENSE/defcon-ui$'
assert_rc "$?" "0" "archive ships DEFCON_DEFENSE under user/general"

exit "$FAIL"
