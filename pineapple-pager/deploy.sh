#!/bin/bash
# Install one payload from user/defcon on a USB-connected Pager over SSH and
# make sure the user/defcon category is listed in the Payloads menu. Each
# payload is deployed on its own; a deploy never touches the other payload.
#
#   ./deploy.sh                           build, then deploy RF-BUDDY
#   ./deploy.sh --payload DEFCON-DEFENSE  build, then deploy DEFCON Defense
#   ./deploy.sh --payload all             deploy both, one after the other
#   ./deploy.sh --dry-run                 show what would run on the Pager
#   ./deploy.sh --skip-build              deploy the existing library/
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PAGER_HOST="${PAGER_HOST:-root@172.16.52.1}"
REMOTE_ROOT="${PAGER_PAYLOAD_ROOT:-/mmc/root/payloads}"
LIBRARY="${PAGER_LIBRARY:-$HERE/library}"
BACKUP_ROOT="${PAGER_BACKUP_ROOT:-/mmc/root/payload-backups}"
SSH="${PAGER_SSH:-ssh}"
DRY_RUN=0
SKIP_BUILD=0
PAYLOAD="RF-BUDDY"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --payload)
      [ $# -ge 2 ] || { echo "ERROR: --payload needs a name" >&2; exit 2; }
      PAYLOAD="$2"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

case "$PAYLOAD" in
  RF-BUDDY|DEFCON-DEFENSE) NAMES="$PAYLOAD" ;;
  all) NAMES="RF-BUDDY DEFCON-DEFENSE" ;;
  *) echo "ERROR: unknown payload $PAYLOAD (use RF-BUDDY, DEFCON-DEFENSE or all)" >&2; exit 2 ;;
esac

binary_for() {
  case "$1" in
    RF-BUDDY) echo rf-buddy-ui ;;
    DEFCON-DEFENSE) echo defcon-ui ;;
  esac
}

if [ "$SKIP_BUILD" != "1" ]; then
  OUT="$LIBRARY" bash "$HERE/build.sh"
fi

for NAME in $NAMES; do
  BIN="$(binary_for "$NAME")"
  SRC="$LIBRARY/user/defcon/$NAME"
  if [ ! -d "$SRC" ] || [ ! -e "$SRC/$BIN" ]; then
    echo "ERROR: $SRC is missing or has no $BIN; run ./build.sh" >&2
    exit 1
  fi

  # DEFCON Defense used to live at user/general/DEFCON_DEFENSE; move that old
  # copy into the same backup so the menu never shows two DEFCON Defenses.
  LEGACY=""
  if [ "$NAME" = "DEFCON-DEFENSE" ]; then
    LEGACY="if [ -d '$REMOTE_ROOT/user/general/DEFCON_DEFENSE' ]; then
  mkdir -p \"\$BK\"; mv '$REMOTE_ROOT/user/general/DEFCON_DEFENSE' \"\$BK/general-DEFCON_DEFENSE\"
  echo \"moved old user/general/DEFCON_DEFENSE to \$BK\"
fi"
  fi

  # Runs on the Pager. Extracts the payload to a staging folder, moves any
  # previous copy into a timestamped backup (never deleting it), swaps the new
  # one in, and registers the menu category. Touches no other payload.
  REMOTE_SCRIPT="set -e
mkdir -p '$REMOTE_ROOT/user/defcon'
cd '$REMOTE_ROOT/user/defcon'
TS=\$(date +%Y%m%d-%H%M%S)
BK='$BACKUP_ROOT'/\$TS
rm -rf $NAME.new && mkdir $NAME.new
tar -C $NAME.new -xf -
if [ -d $NAME ]; then
  mkdir -p \"\$BK\"; mv $NAME \"\$BK/$NAME\"
  echo \"backup: \$BK/$NAME\"
fi
mv $NAME.new $NAME
chmod 755 $NAME/$BIN
$LEGACY
if ! uci -q get 'payloads.@directories[0].payloaddir' | tr ' ' '\n' | grep -qx 'user/defcon'; then
  uci add_list 'payloads.@directories[0].payloaddir=user/defcon'
  uci commit payloads
  echo 'registered user/defcon in the Payloads menu'
fi
echo 'deployed: $NAME'
echo 'If the defcon folder does not appear in Payloads, reboot the Pager.'"

  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY RUN: would stream $SRC to $PAGER_HOST:$REMOTE_ROOT/user/defcon/$NAME and run:"
    printf '%s\n' "$REMOTE_SCRIPT"
    continue
  fi

  COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$SRC" -cf - . \
    | "$SSH" -o BatchMode=yes -o ConnectTimeout=5 "$PAGER_HOST" "$REMOTE_SCRIPT"
done
