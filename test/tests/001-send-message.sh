#!/usr/bin/env bash
# Test: Send a message from @alice@hairpin.local to @bob@example.com
# and verify it is received.
set -euo pipefail

echo "    Sending message: @alice@hairpin.local → @bob@example.com"
export FMSG_API_URL="$HAIRPIN_API_URL"
printf '@alice@hairpin.local\n' | fmsg login
sleep 5
fmsg send '@bob@example.com' "Hello Bob, this is an integration test."

echo "    Waiting for cross-instance delivery..."
sleep 10

echo "    Reading messages as @bob@example.com"
export FMSG_API_URL="$EXAMPLE_API_URL"
printf '@bob@example.com\n' | fmsg login
sleep 5
MSG_OUTPUT=$(fmsg list)
echo "$MSG_OUTPUT"

if echo "$MSG_OUTPUT" | grep -q "No messages"; then
  echo "    FAIL: @bob@example.com has no messages — delivery did not succeed"
  exit 1
fi
