#!/usr/bin/env bash
# Test: Reply from @bob@example.com back to @alice@hairpin.local
# using the parent message ID (pid 1 on a clean database).
set -euo pipefail

echo "    Sending reply: @bob@example.com → @alice@hairpin.local (pid 1)"
export FMSG_API_URL="$EXAMPLE_API_URL"
printf '@bob@example.com\n' | fmsg login
sleep 5
fmsg send --pid 1 '@alice@hairpin.local' "Hey there Alice, got your message!"

echo "    Waiting for cross-instance delivery..."
sleep 10

echo "    Reading messages as @alice@hairpin.local"
export FMSG_API_URL="$HAIRPIN_API_URL"
printf '@alice@hairpin.local\n' | fmsg login
sleep 5
MSG_OUTPUT=$(fmsg list)
echo "$MSG_OUTPUT"

if echo "$MSG_OUTPUT" | grep -q "No messages"; then
  echo "    FAIL: @alice@hairpin.local has no messages — reply delivery did not succeed"
  exit 1
fi
