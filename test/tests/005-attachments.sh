#!/usr/bin/env bash
# Test: Send a message with 3 attachments from Alice to Bob
# and verify attachments can be downloaded by the recipient.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TMP_DIR=$(mktemp -d)
TEST_TOKEN="$(date +%s)-$$"
MESSAGE_TEXT="Hello Bob, this message has 3 attachments! [$TEST_TOKEN]"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "    Creating test attachment files"
echo "Attachment 1 content" > "$TMP_DIR/attachment1.txt"
echo "Attachment 2 content" > "$TMP_DIR/attachment2.txt"
echo "Attachment 3 content" > "$TMP_DIR/attachment3.txt"

echo "    Creating draft message with 3 attachments: $ALICE_ADDR -> $BOB_ADDR"
CREATE_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" draft create "$BOB_ADDR" "$MESSAGE_TEXT")
echo "$CREATE_OUTPUT"

echo "    Getting draft message ID from CLI output"
DRAFT_ID=$(extract_send_id "$CREATE_OUTPUT")
if [ -z "$DRAFT_ID" ]; then
  fail_test "could not determine draft message ID from CLI output"
fi
echo "    Using draft message ID: $DRAFT_ID"

echo "    Attaching files to draft message $DRAFT_ID"
fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" attach "$DRAFT_ID" "$TMP_DIR/attachment1.txt"
fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" attach "$DRAFT_ID" "$TMP_DIR/attachment2.txt"
fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" attach "$DRAFT_ID" "$TMP_DIR/attachment3.txt"

echo "    Sending draft message $DRAFT_ID"
SEND_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" draft send "$DRAFT_ID")
echo "$SEND_OUTPUT"

echo "    Waiting for cross-instance delivery..."
RECEIVED_MSG_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$MESSAGE_TEXT")
echo "    Using received message ID: $RECEIVED_MSG_ID"

echo "    Downloading attachments as $BOB_ADDR"
fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get-attach "$RECEIVED_MSG_ID" attachment1.txt "$TMP_DIR/downloaded-attachment1.txt"
fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get-attach "$RECEIVED_MSG_ID" attachment2.txt "$TMP_DIR/downloaded-attachment2.txt"
fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get-attach "$RECEIVED_MSG_ID" attachment3.txt "$TMP_DIR/downloaded-attachment3.txt"

echo "    Verifying downloaded attachment contents"
cmp -s "$TMP_DIR/attachment1.txt" "$TMP_DIR/downloaded-attachment1.txt" || {
  echo "    FAIL: downloaded attachment1.txt content did not match"
  exit 1
}
cmp -s "$TMP_DIR/attachment2.txt" "$TMP_DIR/downloaded-attachment2.txt" || {
  echo "    FAIL: downloaded attachment2.txt content did not match"
  exit 1
}
cmp -s "$TMP_DIR/attachment3.txt" "$TMP_DIR/downloaded-attachment3.txt" || {
  echo "    FAIL: downloaded attachment3.txt content did not match"
  exit 1
}
