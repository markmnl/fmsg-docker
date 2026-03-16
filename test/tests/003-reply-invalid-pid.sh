#!/usr/bin/env bash
# Test: Sending a reply with an invalid pid (99) should fail.
set -euo pipefail

echo "    Sending reply with invalid pid 99: @bob@example.com → @alice@hairpin.local"
export FMSG_API_URL="$EXAMPLE_API_URL"
printf '@bob@example.com\n' | fmsg login
sleep 5

if fmsg send --pid 99 '@alice@hairpin.local' "This should fail" 2>/dev/null; then
  echo "    FAIL: send with invalid pid 99 succeeded but should have failed"
  exit 1
fi

echo "    send with invalid pid 99 correctly rejected"
