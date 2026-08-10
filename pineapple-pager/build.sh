#!/bin/bash
# Assemble the device-layout library/ tree for USB deploy to the Pager.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUB="${PAGER_PAYLOAD_LIBRARY:-$HERE/vendor/pager-payloads}"
# OUT defaults to ./library but can be overridden, e.g. build straight onto a
# mounted USB:  OUT=/Volumes/PAGER/root/payloads/library ./build.sh
OUT="${OUT:-$HERE/library}"
LIB="$HERE/lib/pager_alert_lib.sh"
PCAP_LIB="$HERE/lib/pcap_evidence_lib.sh"

[ -d "$SUB" ] || { echo "ERROR: curated Pager payload library not found at $SUB"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/alerts/deauth_flood_detected" \
         "$OUT/alerts/pineapple_client_connected" \
         "$OUT/user/general" "$OUT/user/reconnaissance"

# Custom handlers + shared lib injected beside each payload.sh
cp -R "$HERE/src/deauth_flood_detected/defcon_sentry"           "$OUT/alerts/deauth_flood_detected/"
cp -R "$HERE/src/pineapple_client_connected/defcon_honeypot"    "$OUT/alerts/pineapple_client_connected/"
cp "$LIB" "$OUT/alerts/deauth_flood_detected/defcon_sentry/pager_alert_lib.sh"
cp "$LIB" "$OUT/alerts/pineapple_client_connected/defcon_honeypot/pager_alert_lib.sh"
cp "$PCAP_LIB" "$OUT/alerts/deauth_flood_detected/defcon_sentry/pcap_evidence_lib.sh"

# Visible on-device entry point for status and launching the curated tools.
cp -R "$HERE/src/user/general/DEFCON_DEFENSE" "$OUT/user/general/"
cp "$PCAP_LIB" "$OUT/user/general/DEFCON_DEFENSE/pcap_evidence_lib.sh"

# Curated stock detectors (whole directories, verbatim).
# Required core must exist; optional ones are best-effort — the community
# library evolves, so a payload may be renamed or removed in newer versions.
for d in user/general/PORT_ALERT user/general/ICMP_ALERT \
         user/reconnaissance/find_hackers user/reconnaissance/alien_ap ; do
  [ -d "$SUB/$d" ] || { echo "ERROR: required curated payload missing from submodule: $d"; exit 1; }
  cp -R "$SUB/$d" "$OUT/$(dirname "$d")/"
done
for d in user/reconnaissance/SignalFence ; do
  if [ -d "$SUB/$d" ]; then
    cp -R "$SUB/$d" "$OUT/$(dirname "$d")/"
  else
    echo "NOTE: optional payload not in this library version, skipping: $d"
  fi
done

# Deterministic 644 regardless of the builder's umask (device payload convention).
find "$OUT" -type f -exec chmod 644 {} +

# Syntax-check the whole output
err=0
while IFS= read -r f; do
  bash -n "$f" || { echo "SYNTAX FAIL: $f"; err=1; }
done < <(find "$OUT" -name '*.sh')
[ "$err" -eq 0 ] && echo "BUILD OK -> $OUT"
exit "$err"
