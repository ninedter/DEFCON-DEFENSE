#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-test.XXXXXX")"
cleanup() { [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT

LIB="$TMP/library"
mkdir -p "$LIB/user/defcon/RF-BUDDY"
echo rf > "$LIB/user/defcon/RF-BUDDY/payload.sh"
echo ui > "$LIB/user/defcon/RF-BUDDY/rf-buddy-ui"

FAKE_SSH="$TMP/fake-ssh"
cat > "$FAKE_SSH" <<'EOT'
#!/bin/bash
if [ "${FAKE_SSH_EXEC:-0}" = "1" ]; then
  for last_arg; do :; done
  exec sh -c "$last_arg"
fi
printf '%s\n' "$@" > "$FAKE_SSH_ARGS"
cat > "$FAKE_SSH_STDIN"
EOT
chmod +x "$FAKE_SSH"
export FAKE_SSH_ARGS="$TMP/ssh-args" FAKE_SSH_STDIN="$TMP/ssh-stdin"

bash -n "$ROOT/deploy.sh"; assert_rc "$?" "0" "deploy.sh passes bash -n"

out="$(PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build --dry-run)"
assert_rc "$?" "0" "dry run succeeds"
[ ! -f "$FAKE_SSH_ARGS" ]; assert_rc "$?" "0" "dry run does not contact the Pager"
printf '%s' "$out" | grep -qF "uci add_list 'payloads.@directories[0].payloaddir=user/defcon'"
assert_rc "$?" "0" "dry run shows the category registration"
printf '%s' "$out" | grep -qF 'payloads.@directories[0].payloaddir' && ! printf '%s' "$out" | grep -qF 'payloads.directories.payloaddir'
assert_rc "$?" "0" "remote script uses the anonymous directories section"
printf '%s' "$out" | grep -q 'DEFCON'
assert_rc "$?" "1" "dry run output mentions no DEFCON payload"
printf '%s' "$out" | grep -q 'payload-backups'
assert_rc "$?" "0" "dry run shows the backup location"

PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build >/dev/null
assert_rc "$?" "0" "deploy succeeds against the fake Pager"
grep -qx 'root@172.16.52.1' "$FAKE_SSH_ARGS"; assert_rc "$?" "0" "deploys to the USB Pager by default"
grep -qx 'BatchMode=yes' "$FAKE_SSH_ARGS"; assert_rc "$?" "0" "never prompts for a password"
grep -q "uci commit payloads" "$FAKE_SSH_ARGS"; assert_rc "$?" "0" "remote script commits the category"
mkdir -p "$TMP/unpacked"
tar -xf "$FAKE_SSH_STDIN" -C "$TMP/unpacked"
[ -f "$TMP/unpacked/payload.sh" ] && [ -f "$TMP/unpacked/rf-buddy-ui" ]
assert_rc "$?" "0" "only RF-BUDDY contents are streamed to the Pager"
grep -q 'DEFCON' "$FAKE_SSH_ARGS"; assert_rc "$?" "1" "remote script contains no DEFCON"

PAGER_LIBRARY="$TMP/missing" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build >/dev/null 2>&1
assert_rc "$?" "1" "deploy refuses a library without RF-BUDDY"

# --- execute the remote script against a temp "Pager" ---------------------
PR="$TMP/pager-root"; BR="$TMP/backups"; STUBS="$TMP/stubs"
mkdir -p "$PR/user/general/DEFCON_DEFENSE" "$PR/user/defcon/RF-BUDDY" "$PR/user/defcon/OTHER" "$STUBS"
echo "mac" > "$PR/user/general/DEFCON_DEFENSE/trusted_aps.conf"
echo "other" > "$PR/user/defcon/OTHER/payload.sh"
cp -R "$PR/user/general/DEFCON_DEFENSE" "$TMP/dd-before"; cp -R "$PR/user/defcon/OTHER" "$TMP/other-before"
echo "old" > "$PR/user/defcon/RF-BUDDY/payload.sh"
: > "$TMP/uci-list"; : > "$TMP/uci-calls"
cat > "$STUBS/uci" <<'EOT'
#!/bin/bash
printf '%s\n' "$*" >> "$UCI_CALLS"
P='payloads.@directories[0].payloaddir'
case "$1 $2 $3" in
  "-q get $P") cat "$UCI_LIST"; exit 0 ;;
  "add_list $P=user/defcon "*|"add_list $P=user/defcon") printf 'user/defcon\n' >> "$UCI_LIST"; exit 0 ;;
  "commit payloads "*) exit 0 ;;
  "get "*|"-q get "*|"add_list "*) echo "uci: Invalid argument" >&2; exit 1 ;;
esac
exit 0
EOT
chmod +x "$STUBS/uci"
export UCI_LIST="$TMP/uci-list" UCI_CALLS="$TMP/uci-calls"

FAKE_SSH_EXEC=1 PATH="$STUBS:$PATH" PAGER_PAYLOAD_ROOT="$PR" PAGER_BACKUP_ROOT="$BR" \
  PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build >/dev/null
assert_rc "$?" "0" "deploy executes against a temp Pager root"
[ -f "$PR/user/defcon/RF-BUDDY/payload.sh" ] && [ -x "$PR/user/defcon/RF-BUDDY/rf-buddy-ui" ]
assert_rc "$?" "0" "RF-BUDDY is installed with an executable UI binary"
assert_eq "$(cat "$PR/user/defcon/RF-BUDDY/payload.sh")" "rf" "RF-BUDDY is the new copy"
[ ! -e "$PR/user/defcon/RF-BUDDY.new" ]; assert_rc "$?" "0" "staging folder is gone"
diff -r "$TMP/dd-before" "$PR/user/general/DEFCON_DEFENSE" >/dev/null
assert_rc "$?" "0" "user/general/DEFCON_DEFENSE is untouched"
diff -r "$TMP/other-before" "$PR/user/defcon/OTHER" >/dev/null
assert_rc "$?" "0" "user/defcon/OTHER is untouched"
BKP="$(find "$BR" -path '*/RF-BUDDY/payload.sh' | head -n 1)"
[ -n "$BKP" ] && [ "$(cat "$BKP")" = "old" ]; assert_rc "$?" "0" "previous RF-BUDDY is backed up"
[ "$(find "$BR" -type f | wc -l | tr -d ' ')" = "1" ]; assert_rc "$?" "0" "only RF-BUDDY was backed up"
assert_eq "$(grep -c '^add_list' "$UCI_CALLS")" "1" "uci add_list called once"

FAKE_SSH_EXEC=1 PATH="$STUBS:$PATH" PAGER_PAYLOAD_ROOT="$PR" PAGER_BACKUP_ROOT="$BR" \
  PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build >/dev/null
assert_rc "$?" "0" "second deploy succeeds"
assert_eq "$(grep -c '^add_list' "$UCI_CALLS")" "1" "second deploy does not re-register the category"

# --- DEFCON-DEFENSE is deployed on its own --------------------------------
mkdir -p "$LIB/user/defcon/DEFCON-DEFENSE"
echo dd > "$LIB/user/defcon/DEFCON-DEFENSE/payload.sh"
echo ui > "$LIB/user/defcon/DEFCON-DEFENSE/defcon-ui"

out="$(PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --payload DEFCON-DEFENSE --skip-build --dry-run)"
assert_rc "$?" "0" "DEFCON-DEFENSE dry run succeeds"
printf '%s' "$out" | grep -q 'general/DEFCON_DEFENSE'
assert_rc "$?" "0" "DEFCON-DEFENSE deploy retires the old user/general copy"
printf '%s' "$out" | grep -q 'RF-BUDDY'
assert_rc "$?" "1" "DEFCON-DEFENSE deploy never mentions RF-BUDDY"

out="$(PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --payload all --skip-build --dry-run)"
printf '%s' "$out" | grep -q 'deployed: RF-BUDDY' && printf '%s' "$out" | grep -q 'deployed: DEFCON-DEFENSE'
assert_rc "$?" "0" "--payload all deploys both payloads"

PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --payload NOPE --skip-build --dry-run >/dev/null 2>&1
assert_rc "$?" "2" "unknown payload name is rejected"

cp -R "$PR/user/defcon/RF-BUDDY" "$TMP/rf-before"
FAKE_SSH_EXEC=1 PATH="$STUBS:$PATH" PAGER_PAYLOAD_ROOT="$PR" PAGER_BACKUP_ROOT="$BR" \
  PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --payload DEFCON-DEFENSE --skip-build >/dev/null
assert_rc "$?" "0" "DEFCON-DEFENSE deploy executes against a temp Pager root"
assert_eq "$(cat "$PR/user/defcon/DEFCON-DEFENSE/payload.sh")" "dd" "DEFCON-DEFENSE is installed in user/defcon"
[ -x "$PR/user/defcon/DEFCON-DEFENSE/defcon-ui" ]; assert_rc "$?" "0" "DEFCON-DEFENSE UI binary is executable"
[ ! -e "$PR/user/general/DEFCON_DEFENSE" ]; assert_rc "$?" "0" "old user/general/DEFCON_DEFENSE is gone from the menu"
LEG="$(find "$BR" -path '*/general-DEFCON_DEFENSE/trusted_aps.conf' | head -n 1)"
[ -n "$LEG" ] && [ "$(cat "$LEG")" = "mac" ]; assert_rc "$?" "0" "old DEFCON copy (with its config) is kept in the backup"
diff -r "$TMP/rf-before" "$PR/user/defcon/RF-BUDDY" >/dev/null
assert_rc "$?" "0" "RF-BUDDY is untouched by a DEFCON-DEFENSE deploy"
diff -r "$TMP/other-before" "$PR/user/defcon/OTHER" >/dev/null
assert_rc "$?" "0" "user/defcon/OTHER is untouched by a DEFCON-DEFENSE deploy"

# --- old backups are pruned, per payload, deploy-made folders only ---------
BR2="$TMP/backups2"
for ts in 20250101-000001 20250101-000002 20250101-000003 20250101-000004 20250101-000005; do
  mkdir -p "$BR2/$ts/RF-BUDDY"; echo "$ts" > "$BR2/$ts/RF-BUDDY/payload.sh"
done
mkdir -p "$BR2/20250101-000001/DEFCON-DEFENSE" "$BR2/defcon-defense-manual/RF-BUDDY"
echo keep > "$BR2/20250101-000001/DEFCON-DEFENSE/payload.sh"
echo keep > "$BR2/defcon-defense-manual/RF-BUDDY/payload.sh"
out="$(FAKE_SSH_EXEC=1 PATH="$STUBS:$PATH" PAGER_PAYLOAD_ROOT="$PR" PAGER_BACKUP_ROOT="$BR2" \
  PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build)"
assert_rc "$?" "0" "deploy with old backups succeeds"
assert_eq "$(find "$BR2" -mindepth 2 -maxdepth 2 -name RF-BUDDY -path "$BR2/2*" | wc -l | tr -d ' ')" "1" \
  "only the newest RF-BUDDY deploy backup is kept"
[ ! -e "$BR2/20250101-000005/RF-BUDDY" ] && [ -n "$(find "$BR2" -maxdepth 2 -path "$BR2/2*/RF-BUDDY" ! -path "$BR2/20250101-*")" ]
assert_rc "$?" "0" "the backup from this deploy is the one kept"
[ ! -e "$BR2/20250101-000002" ]; assert_rc "$?" "0" "emptied backup folders are removed"
[ -f "$BR2/20250101-000001/DEFCON-DEFENSE/payload.sh" ]
assert_rc "$?" "0" "pruning RF-BUDDY never touches DEFCON-DEFENSE backups"
[ -f "$BR2/defcon-defense-manual/RF-BUDDY/payload.sh" ]
assert_rc "$?" "0" "manual (non-timestamp) backups are never pruned"
printf '%s' "$out" | grep -q 'pruned old backup'; assert_rc "$?" "0" "pruning is reported"

PAGER_BACKUP_KEEP=x PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build --dry-run >/dev/null 2>&1
assert_rc "$?" "2" "non-numeric PAGER_BACKUP_KEEP is rejected"

PAGER_BACKUP_KEEP=0 PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build --dry-run >/dev/null 2>&1
assert_rc "$?" "2" "PAGER_BACKUP_KEEP=0 is rejected"

# --- a clock behind an existing backup must not prune the backup just made --
BR3="$TMP/backups3"
mkdir -p "$BR3/29991231-235959/RF-BUDDY"; echo future > "$BR3/29991231-235959/RF-BUDDY/payload.sh"
FAKE_SSH_EXEC=1 PATH="$STUBS:$PATH" PAGER_PAYLOAD_ROOT="$PR" PAGER_BACKUP_ROOT="$BR3" \
  PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build >/dev/null
assert_rc "$?" "0" "deploy with a newer-named backup succeeds"
[ -n "$(find "$BR3" -mindepth 2 -maxdepth 2 -name RF-BUDDY ! -path "$BR3/2999*")" ]
assert_rc "$?" "0" "the backup just made is kept even when older-named"
[ ! -e "$BR3/29991231-235959/RF-BUDDY" ]; assert_rc "$?" "0" "the other timestamp backup is pruned to make room"

exit "$FAIL"
