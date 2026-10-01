#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/assert.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-test.XXXXXX")"
cleanup() { [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT

LIB="$TMP/library"
mkdir -p "$LIB/user/defcon/RF-BUDDY" "$LIB/user/defcon/DEFCON-DEFENSE"
echo rf > "$LIB/user/defcon/RF-BUDDY/payload.sh"
echo dd > "$LIB/user/defcon/DEFCON-DEFENSE/payload.sh"

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
printf '%s' "$out" | grep -q 'general/DEFCON_DEFENSE'
assert_rc "$?" "0" "dry run shows the old DEFCON_DEFENSE copy being handled"
printf '%s' "$out" | grep -q 'payload-backups'
assert_rc "$?" "0" "dry run shows the backup location"

PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build >/dev/null
assert_rc "$?" "0" "deploy succeeds against the fake Pager"
grep -qx 'root@172.16.52.1' "$FAKE_SSH_ARGS"; assert_rc "$?" "0" "deploys to the USB Pager by default"
grep -qx 'BatchMode=yes' "$FAKE_SSH_ARGS"; assert_rc "$?" "0" "never prompts for a password"
grep -q "uci commit payloads" "$FAKE_SSH_ARGS"; assert_rc "$?" "0" "remote script commits the category"
mkdir -p "$TMP/unpacked"
tar -xf "$FAKE_SSH_STDIN" -C "$TMP/unpacked"
[ -f "$TMP/unpacked/RF-BUDDY/payload.sh" ] && [ -f "$TMP/unpacked/DEFCON-DEFENSE/payload.sh" ]
assert_rc "$?" "0" "both payloads are streamed to the Pager"

PAGER_LIBRARY="$TMP/missing" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build >/dev/null 2>&1
assert_rc "$?" "1" "deploy refuses a library without the defcon payloads"

# --- execute the remote script against a temp "Pager" ---------------------
PR="$TMP/pager-root"; BR="$TMP/backups"; STUBS="$TMP/stubs"
mkdir -p "$PR/user/general/DEFCON_DEFENSE" "$PR/user/defcon/RF-BUDDY" "$STUBS"
echo "mac" > "$PR/user/general/DEFCON_DEFENSE/trusted_aps.conf"
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
[ -f "$PR/user/defcon/RF-BUDDY/payload.sh" ] && [ -f "$PR/user/defcon/DEFCON-DEFENSE/payload.sh" ]
assert_rc "$?" "0" "new payloads are installed under user/defcon"
assert_eq "$(cat "$PR/user/defcon/RF-BUDDY/payload.sh")" "rf" "RF-BUDDY is the new copy"
[ ! -e "$PR/user/general/DEFCON_DEFENSE" ]; assert_rc "$?" "0" "old user/general/DEFCON_DEFENSE is gone"
BKF="$(find "$BR" -name trusted_aps.conf | head -n 1)"
[ -n "$BKF" ] && case "$BKF" in */general-DEFCON_DEFENSE/trusted_aps.conf) true ;; *) false ;; esac
assert_rc "$?" "0" "old DEFCON_DEFENSE is backed up with trusted_aps.conf"
BKP="$(find "$BR" -path '*/defcon/RF-BUDDY/payload.sh' | head -n 1)"
[ -n "$BKP" ] && [ "$(cat "$BKP")" = "old" ]; assert_rc "$?" "0" "previous defcon folder is backed up"
assert_eq "$(grep -c '^add_list' "$UCI_CALLS")" "1" "uci add_list called once"

FAKE_SSH_EXEC=1 PATH="$STUBS:$PATH" PAGER_PAYLOAD_ROOT="$PR" PAGER_BACKUP_ROOT="$BR" \
  PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build >/dev/null
assert_rc "$?" "0" "second deploy succeeds"
assert_eq "$(grep -c '^add_list' "$UCI_CALLS")" "1" "second deploy does not re-register the category"

exit "$FAIL"
