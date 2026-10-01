#!/bin/bash
# Install the RF-BUDDY payload (only) on a USB-connected Pager over SSH and make
# sure the user/defcon category is listed in the Payloads menu.
#
#   ./deploy.sh              build, then deploy
#   ./deploy.sh --dry-run    show what would run on the Pager
#   ./deploy.sh --skip-build deploy the existing library/
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PAGER_HOST="${PAGER_HOST:-root@172.16.52.1}"
REMOTE_ROOT="${PAGER_PAYLOAD_ROOT:-/mmc/root/payloads}"
LIBRARY="${PAGER_LIBRARY:-$HERE/library}"
BACKUP_ROOT="${PAGER_BACKUP_ROOT:-/mmc/root/payload-backups}"
SSH="${PAGER_SSH:-ssh}"
DRY_RUN=0
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown option $arg" >&2; exit 2 ;;
  esac
done

if [ "$SKIP_BUILD" != "1" ]; then
  OUT="$LIBRARY" bash "$HERE/build.sh"
fi
SRC="$LIBRARY/user/defcon/RF-BUDDY"
if [ ! -d "$SRC" ] || [ ! -e "$SRC/rf-buddy-ui" ]; then
  echo "ERROR: $SRC is missing or has no rf-buddy-ui; run ./build.sh" >&2
  exit 1
fi

# Runs on the Pager. Extracts RF-BUDDY to a staging folder, moves any previous
# RF-BUDDY into a timestamped backup (never deleting it), swaps the new one in,
# and registers the menu category. Touches no other payload.
REMOTE_SCRIPT="set -e
mkdir -p '$REMOTE_ROOT/user/defcon'
cd '$REMOTE_ROOT/user/defcon'
TS=\$(date +%Y%m%d-%H%M%S)
BK='$BACKUP_ROOT'/\$TS
rm -rf RF-BUDDY.new && mkdir RF-BUDDY.new
tar -C RF-BUDDY.new -xf -
if [ -d RF-BUDDY ]; then
  mkdir -p \"\$BK\"; mv RF-BUDDY \"\$BK/RF-BUDDY\"
  echo \"backup: \$BK/RF-BUDDY\"
fi
mv RF-BUDDY.new RF-BUDDY
chmod 755 RF-BUDDY/rf-buddy-ui
if ! uci -q get 'payloads.@directories[0].payloaddir' | tr ' ' '\n' | grep -qx 'user/defcon'; then
  uci add_list 'payloads.@directories[0].payloaddir=user/defcon'
  uci commit payloads
  echo 'registered user/defcon in the Payloads menu'
fi
echo 'deployed: RF-BUDDY'
echo 'If the defcon folder does not appear in Payloads, reboot the Pager.'"

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: would stream $SRC to $PAGER_HOST:$REMOTE_ROOT/user/defcon/RF-BUDDY and run:"
  printf '%s\n' "$REMOTE_SCRIPT"
  exit 0
fi

COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$SRC" -cf - . \
  | "$SSH" -o BatchMode=yes -o ConnectTimeout=5 "$PAGER_HOST" "$REMOTE_SCRIPT"
