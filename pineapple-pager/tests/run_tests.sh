#!/bin/bash
# Run all host-side tests + full-tree syntax check.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
rc=0
for t in "$HERE"/test_*.sh; do
  echo "=== $(basename "$t") ==="
  bash "$t" || rc=1
done
echo "=== tools/test_gen_btdb.py ==="
if command -v python3 >/dev/null 2>&1; then
  (cd "$ROOT/tools" && python3 -m unittest test_gen_btdb) || rc=1
else
  echo "SKIP: python3 not found; BT database generator tests not run"
fi
echo "=== bash -n over src/ + lib/ ==="
while IFS= read -r f; do bash -n "$f" || rc=1; done < <(find "$ROOT/src" "$ROOT/lib" -name '*.sh')
[ "$rc" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$rc"
