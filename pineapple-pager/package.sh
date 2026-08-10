#!/bin/bash
# Build a deployable archive without macOS extended metadata.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="${DIST:-$HERE/dist}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pager-defcon-package.XXXXXX")"

cleanup() {
  [ -d "$TMP" ] && rm -rf -- "$TMP"
}
trap cleanup EXIT

OUT="$TMP/payloads" bash "$HERE/build.sh"

# The device verifies this manifest both before and after activation.
(cd "$TMP/payloads" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) \
  > "$TMP/payload-manifest.sha256"

mkdir -p "$DIST"
# macOS stores provenance and other extended attributes in tar archives unless
# explicitly disabled. BusyBox may materialize those records as ._payload.sh
# files, which confuses Pager payload discovery.
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --no-acls --no-fflags \
  -C "$TMP/payloads" -czf "$DIST/pager-defcon-defense-unified.tar.gz" .
cp "$TMP/payload-manifest.sha256" "$DIST/payload-manifest.sha256"

if tar -tzf "$DIST/pager-defcon-defense-unified.tar.gz" | awk '/(^|\/)\._|(^|\/)\.DS_Store$/{bad=1} END{exit !bad}'; then
  echo "ERROR: macOS metadata found in deployable archive" >&2
  exit 1
fi

shasum -a 256 "$DIST/pager-defcon-defense-unified.tar.gz"
echo "PACKAGE OK -> $DIST"
