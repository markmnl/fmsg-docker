#!/usr/bin/env bash
# Test: Send a message from @alice@hairpin.local to @bob@example.com,
# then add @carol@example.com as a recipient using fmsg add-to,
# and verify carol receives the message.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"
MESSAGE_TEXT="Hello Bob, this is the add-to integration test. [$TEST_TOKEN]"

echo "    Sending initial message: @alice@hairpin.local → @bob@example.com"
export FMSG_API_URL="$HAIRPIN_API_URL"
fmsg login '@alice@hairpin.local'
SEND_OUTPUT=$(fmsg send '@bob@example.com' "$MESSAGE_TEXT")
echo "$SEND_OUTPUT"

echo "    Getting message ID from send output"
MSG_ID=$(extract_send_id "$SEND_OUTPUT")
if [ -z "$MSG_ID" ]; then
  fail_test "could not determine message ID from fmsg send output"
fi
echo "    Using message ID: $MSG_ID"

echo "    Waiting for bob to receive the original message"
export FMSG_API_URL="$EXAMPLE_API_URL"
fmsg login '@bob@example.com'
ORIGINAL_MSG_ID=$(wait_for_message_id_by_data "$MESSAGE_TEXT")
echo "    Bob received original message ID: $ORIGINAL_MSG_ID"

echo "    Adding @carol@example.com as recipient via add-to $MSG_ID"
export FMSG_API_URL="$HAIRPIN_API_URL"
fmsg login '@alice@hairpin.local'
fmsg add-to "$MSG_ID" '@carol@example.com'

echo "    Waiting for cross-instance delivery..."
export FMSG_API_URL="$EXAMPLE_API_URL"
fmsg login '@carol@example.com'
RECEIVED_MSG_ID=$(wait_for_message_id_by_data "$MESSAGE_TEXT")
echo "    Using received message ID: $RECEIVED_MSG_ID"

echo "    Reading received message as @carol@example.com"
MSG_OUTPUT=$(fmsg get "$RECEIVED_MSG_ID")
echo "$MSG_OUTPUT"

if ! echo "$MSG_OUTPUT" | grep -q '^From: @alice@hairpin.local$'; then
  fail_test "received message $RECEIVED_MSG_ID was not from @alice@hairpin.local"
fi
