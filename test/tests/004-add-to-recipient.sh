#!/usr/bin/env bash
# Test: Send a message from @alice@hairpin.local to @bob@example.com,
# then add @carol@example.com as a recipient using --add-to on a follow-up send,
# and verify carol receives the message.
set -euo pipefail

echo "    Sending initial message: @alice@hairpin.local → @bob@example.com"
export FMSG_API_URL="$HAIRPIN_API_URL"
printf '@alice@hairpin.local\n' | fmsg login
sleep 5
fmsg send '@bob@example.com' "Hello Bob, this is the add-to integration test."

echo "    Waiting for delivery..."
sleep 10

echo "    Getting message ID from alice's sent messages"
MSG_ID=$(fmsg list | grep -oE '\b[0-9]+\b' | head -1)
if [ -z "$MSG_ID" ]; then
  echo "    FAIL: could not determine message ID from fmsg list"
  exit 1
fi
echo "    Using message ID: $MSG_ID"

echo "    Adding @carol@example.com as recipient via --pid $MSG_ID --add-to"
fmsg send --pid "$MSG_ID" --add-to '@carol@example.com' '@bob@example.com' "Adding Carol to this conversation."

echo "    Waiting for cross-instance delivery..."
sleep 10

echo "    Reading messages as @carol@example.com"
export FMSG_API_URL="$EXAMPLE_API_URL"
printf '@carol@example.com\n' | fmsg login
sleep 5
MSG_OUTPUT=$(fmsg list)
echo "$MSG_OUTPUT"

if echo "$MSG_OUTPUT" | grep -q "No messages"; then
  echo "    FAIL: @carol@example.com has no messages — add-to delivery did not succeed"
  exit 1
fi
