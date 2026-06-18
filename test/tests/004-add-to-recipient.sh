#!/usr/bin/env bash
# Test: Send a reply-chain message from Alice to Bob,
# then add Carol as a recipient using fmsg add-to,
# and verify carol receives the message.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"
ROOT_MESSAGE_TEXT="Hello Bob, this message starts the add-to integration test. [$TEST_TOKEN]"
MESSAGE_TEXT="Hello Bob and Carol, this is the add-to integration test follow-up. [$TEST_TOKEN]"

echo "    Sending initial message: $ALICE_ADDR -> $BOB_ADDR"
SEND_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" send "$BOB_ADDR" "$ROOT_MESSAGE_TEXT")
echo "$SEND_OUTPUT"

echo "    Getting message ID from send output"
ROOT_MSG_ID=$(extract_send_id "$SEND_OUTPUT")
if [ -z "$ROOT_MSG_ID" ]; then
  fail_test "could not determine message ID from fmsg send output"
fi
echo "    Using root message ID: $ROOT_MSG_ID"

echo "    Waiting for bob to receive the original message"
ORIGINAL_MSG_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$ROOT_MESSAGE_TEXT")
echo "    Bob received original message ID: $ORIGINAL_MSG_ID"

echo "    Sending follow-up with pid $ROOT_MSG_ID: $ALICE_ADDR -> $BOB_ADDR"
FOLLOWUP_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" send --pid "$ROOT_MSG_ID" "$BOB_ADDR" "$MESSAGE_TEXT")
echo "$FOLLOWUP_OUTPUT"

echo "    Getting follow-up message ID from send output"
FOLLOWUP_MSG_ID=$(extract_send_id "$FOLLOWUP_OUTPUT")
if [ -z "$FOLLOWUP_MSG_ID" ]; then
  fail_test "could not determine follow-up message ID from fmsg send output"
fi
echo "    Using follow-up message ID: $FOLLOWUP_MSG_ID"

echo "    Waiting for bob to receive the follow-up message"
BOB_FOLLOWUP_MSG_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$MESSAGE_TEXT")
echo "    Bob received follow-up message ID: $BOB_FOLLOWUP_MSG_ID"

echo "    Adding $CAROL_ADDR as recipient via add-to $FOLLOWUP_MSG_ID"
fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" add-to "$FOLLOWUP_MSG_ID" "$CAROL_ADDR"

echo "    Waiting for cross-instance delivery..."
RECEIVED_MSG_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$CAROL_API_KEY" "$MESSAGE_TEXT")
echo "    Using received message ID: $RECEIVED_MSG_ID"

echo "    Reading received message as $CAROL_ADDR"
MSG_OUTPUT=$(fmsg_as "$EXAMPLE_API_URL" "$CAROL_API_KEY" get "$RECEIVED_MSG_ID")
echo "$MSG_OUTPUT"

if ! echo "$MSG_OUTPUT" | grep -q "^From: $ALICE_ADDR$"; then
  fail_test "received message $RECEIVED_MSG_ID was not from $ALICE_ADDR"
fi
