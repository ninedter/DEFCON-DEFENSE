#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$root/application.fam"
source_file="$root/defcon_defense.c"

grep -q 'appid="defcon_defense"' "$manifest"
grep -q 'sources=\["defcon_defense.c", "defcon_uart.c"\]' "$manifest"

for forbidden in \
    'attack -t' \
    'evilportal' \
    'blespam' \
    'karma -p' \
    'ssid -a' \
    'select -a' \
    'sniffpmkid' \
    'beacon -'; do
    if grep -Fq "$forbidden" "$source_file"; then
        echo "forbidden transmit capability found: $forbidden" >&2
        exit 1
    fi
done

for allowed in 'scanap\n' 'scansta\n' 'sniffdeauth\n' 'stopscan\n' 'stopscan -f\n'; do
    grep -Fq "$allowed" "$source_file"
done

echo "defensive command contract: PASS"
