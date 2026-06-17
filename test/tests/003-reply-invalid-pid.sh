#!/usr/bin/env bash
# Test: Sending a reply with an invalid pid (99) should fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

echo "    Sending reply with invalid pid 99: $BOB_ADDR -> $ALICE_ADDR"

if fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" send --pid 99 "$ALICE_ADDR" "This should fail" 2>/dev/null; then
  echo "    FAIL: send with invalid pid 99 succeeded but should have failed"
  exit 1
fi

echo "    send with invalid pid 99 correctly rejected"
