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
printf '%s\n' "$@" > "$FAKE_SSH_ARGS"
cat > "$FAKE_SSH_STDIN"
EOT
chmod +x "$FAKE_SSH"
export FAKE_SSH_ARGS="$TMP/ssh-args" FAKE_SSH_STDIN="$TMP/ssh-stdin"

bash -n "$ROOT/deploy.sh"; assert_rc "$?" "0" "deploy.sh passes bash -n"

out="$(PAGER_LIBRARY="$LIB" PAGER_SSH="$FAKE_SSH" bash "$ROOT/deploy.sh" --skip-build --dry-run)"
assert_rc "$?" "0" "dry run succeeds"
[ ! -f "$FAKE_SSH_ARGS" ]; assert_rc "$?" "0" "dry run does not contact the Pager"
printf '%s' "$out" | grep -q "uci add_list payloads.directories.payloaddir='user/defcon'"
assert_rc "$?" "0" "dry run shows the category registration"
printf '%s' "$out" | grep -q 'general/DEFCON_DEFENSE'
assert_rc "$?" "0" "dry run shows removal of the old DEFCON_DEFENSE copy"

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

exit "$FAIL"
