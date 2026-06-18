#!/usr/bin/env bash
# Test: Reply from Bob back to Alice
# using the parent message ID (pid 1 on a clean database).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"
MESSAGE_TEXT="Hey there Alice, got your message! [$TEST_TOKEN]"

echo "    Sending reply: $BOB_ADDR -> $ALICE_ADDR (pid 1)"
SEND_OUTPUT=$(fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" send --pid 1 "$ALICE_ADDR" "$MESSAGE_TEXT")
echo "$SEND_OUTPUT"

echo "    Waiting for cross-instance delivery..."
MSG_ID=$(wait_for_message_id_by_data "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$MESSAGE_TEXT")
echo "    Using received message ID: $MSG_ID"

echo "    Reading received message as $ALICE_ADDR"
MSG_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" get "$MSG_ID")
echo "$MSG_OUTPUT"

if ! echo "$MSG_OUTPUT" | grep -q "^From: $BOB_ADDR$"; then
  fail_test "received message $MSG_ID was not from $BOB_ADDR"
fi

if ! echo "$MSG_OUTPUT" | grep -q '^PID:[[:space:]]*1$'; then
  fail_test "received message $MSG_ID did not have pid 1"
fi
