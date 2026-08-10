#!/bin/bash
# Minimal assertion helpers. Sets FAIL=1 on any failure.
FAIL=0
assert_eq() { # actual expected label
  if [ "$1" != "$2" ]; then echo "FAIL: $3 (got '$1' want '$2')"; FAIL=1
  else echo "ok: $3"; fi
}
assert_rc() { # actual_rc expected_rc label
  if [ "$1" != "$2" ]; then echo "FAIL: $3 (rc got '$1' want '$2')"; FAIL=1
  else echo "ok: $3"; fi
}
