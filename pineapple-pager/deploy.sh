#!/bin/bash
# Install the built payload tree on a USB-connected Pager over SSH and make
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
if [ ! -d "$LIBRARY/user/defcon/RF-BUDDY" ] || [ ! -d "$LIBRARY/user/defcon/DEFCON-DEFENSE" ]; then
  echo "ERROR: $LIBRARY/user/defcon is missing RF-BUDDY or DEFCON-DEFENSE; run ./build.sh" >&2
  exit 1
fi

# Runs on the Pager. Extracts to a staging folder, moves any previous defcon
# folder and the pre-move DEFCON_DEFENSE copy into a timestamped backup (never
# deleting them), swaps the new tree in, and registers the menu category.
REMOTE_SCRIPT="set -e
cd '$REMOTE_ROOT/user'
TS=\$(date +%Y%m%d-%H%M%S)
BK='$BACKUP_ROOT'/\$TS
BACKED_UP=0
rm -rf defcon.new && mkdir defcon.new
tar -C defcon.new -xf -
if [ -d defcon ]; then mkdir -p \"\$BK\"; mv defcon \"\$BK/defcon\"; BACKED_UP=1; fi
mv defcon.new defcon
chmod 755 defcon/DEFCON-DEFENSE/defcon-ui defcon/RF-BUDDY/rf-buddy-ui 2>/dev/null || true
if [ -d general/DEFCON_DEFENSE ]; then
  mkdir -p \"\$BK\"; mv general/DEFCON_DEFENSE \"\$BK/general-DEFCON_DEFENSE\"; BACKED_UP=1
  echo \"moved old user/general/DEFCON_DEFENSE to \$BK\"
fi
if [ \"\$BACKED_UP\" = 1 ]; then echo \"backup: \$BK\"; fi
if ! uci -q get 'payloads.@directories[0].payloaddir' | tr ' ' '\n' | grep -qx 'user/defcon'; then
  uci add_list 'payloads.@directories[0].payloaddir=user/defcon'
  uci commit payloads
  echo 'registered user/defcon in the Payloads menu'
fi
echo \"deployed: \$(ls defcon | tr '\n' ' ')\"
echo 'If the defcon folder does not appear in Payloads, reboot the Pager.'"

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: would stream $LIBRARY/user/defcon to $PAGER_HOST:$REMOTE_ROOT/user/defcon and run:"
  printf '%s\n' "$REMOTE_SCRIPT"
  exit 0
fi

COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$LIBRARY/user/defcon" -cf - . \
  | "$SSH" -o BatchMode=yes -o ConnectTimeout=5 "$PAGER_HOST" "$REMOTE_SCRIPT"
