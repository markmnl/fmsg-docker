#!/usr/bin/env bash
# Test: Send a message with 3 attachments from @alice@hairpin.local to @bob@example.com
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

echo "    Creating draft message with 3 attachments: @alice@hairpin.local → @bob@example.com"
export FMSG_API_URL="$HAIRPIN_API_URL"
fmsg login '@alice@hairpin.local'
DRAFT_PAYLOAD=$(printf '{"from":"@alice@hairpin.local","to":["@bob@example.com"],"version":1,"type":"text/plain","size":%d,"data":"%s"}' "${#MESSAGE_TEXT}" "$MESSAGE_TEXT")
AUTH_TOKEN=$(get_auth_token)
CREATE_OUTPUT=$(curl -fsS \
  -X POST \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "$DRAFT_PAYLOAD" \
  "$FMSG_API_URL/fmsg")
echo "    Draft created: $CREATE_OUTPUT"

echo "    Getting draft message ID from API output"
DRAFT_ID=$(echo "$CREATE_OUTPUT" | sed -n 's/.*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
if [ -z "$DRAFT_ID" ]; then
  fail_test "could not determine draft message ID from API output"
fi
echo "    Using draft message ID: $DRAFT_ID"

echo "    Attaching files to draft message $DRAFT_ID"
fmsg attach "$DRAFT_ID" "$TMP_DIR/attachment1.txt"
fmsg attach "$DRAFT_ID" "$TMP_DIR/attachment2.txt"
fmsg attach "$DRAFT_ID" "$TMP_DIR/attachment3.txt"

echo "    Sending draft message $DRAFT_ID"
SEND_OUTPUT=$(curl -fsS \
  -X POST \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  "$FMSG_API_URL/fmsg/$DRAFT_ID/send")
echo "    Draft sent: $SEND_OUTPUT"

echo "    Waiting for cross-instance delivery..."
export FMSG_API_URL="$EXAMPLE_API_URL"
fmsg login '@bob@example.com'
RECEIVED_MSG_ID=$(wait_for_message_id_by_data "$MESSAGE_TEXT")
echo "    Using received message ID: $RECEIVED_MSG_ID"

echo "    Downloading attachments as @bob@example.com"
fmsg get-attach "$RECEIVED_MSG_ID" attachment1.txt "$TMP_DIR/downloaded-attachment1.txt"
fmsg get-attach "$RECEIVED_MSG_ID" attachment2.txt "$TMP_DIR/downloaded-attachment2.txt"
fmsg get-attach "$RECEIVED_MSG_ID" attachment3.txt "$TMP_DIR/downloaded-attachment3.txt"

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
