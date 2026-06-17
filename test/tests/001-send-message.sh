#!/usr/bin/env bash
# Test: Send a message from @alice@hairpin.local to @bob@example.com
# and verify the recipient can download the message data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TMP_DIR=$(mktemp -d)
TEST_TOKEN="$(date +%s)-$$"
MESSAGE_TEXT="Hello Bob, this is an integration test. [$TEST_TOKEN]"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "    Sending message: $ALICE_ADDR -> $BOB_ADDR"
SEND_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" send "$BOB_ADDR" "$MESSAGE_TEXT")
echo "$SEND_OUTPUT"

echo "    Waiting for cross-instance delivery..."
MSG_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$MESSAGE_TEXT")
echo "    Using received message ID: $MSG_ID"

echo "    Downloading message data as $BOB_ADDR"
fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get-data "$MSG_ID" "$TMP_DIR/message.txt"

echo "    Verifying downloaded message data"
if ! grep -Fxq "$MESSAGE_TEXT" "$TMP_DIR/message.txt"; then
  fail_test "downloaded message data did not match expected content"
  echo "    Downloaded data:"
  cat "$TMP_DIR/message.txt"
  exit 1
fi
