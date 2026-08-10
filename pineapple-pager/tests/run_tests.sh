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
echo "=== bash -n over src/ + lib/ ==="
while IFS= read -r f; do bash -n "$f" || rc=1; done < <(find "$ROOT/src" "$ROOT/lib" -name '*.sh')
[ "$rc" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$rc"
