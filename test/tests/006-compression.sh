#!/usr/bin/env bash
# Test: Verify large, highly-compressible messages are handled correctly
# with and without attachments across instances.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TMP_DIR=$(mktemp -d)
TEST_TOKEN="$(date +%s)-$$"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

build_large_text() {
  local suffix="$1"
  local chunk="compressible-payload-$suffix-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
  local out=""
  local i

  for i in $(seq 1 16); do
    out+="$chunk"
  done

  echo "$out"
}

send_draft_with_attachment() {
  local message_text="$1"
  local attachment_path="$2"
  local draft_payload
  local auth_token
  local create_output
  local draft_id

  draft_payload=$(printf '{"from":"@alice@hairpin.local","to":["@bob@example.com"],"version":1,"type":"text/plain","size":%d,"data":"%s"}' "${#message_text}" "$message_text")
  auth_token=$(get_auth_token)

  create_output=$(curl -fsS \
    -X POST \
    -H "Authorization: Bearer $auth_token" \
    -H 'Content-Type: application/json' \
    --data "$draft_payload" \
    "$FMSG_API_URL/fmsg")

  draft_id=$(echo "$create_output" | sed -n 's/.*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
  if [ -z "$draft_id" ]; then
    fail_test "could not determine draft message ID from API output"
  fi

  fmsg attach "$draft_id" "$attachment_path"

  curl -fsS \
    -X POST \
    -H "Authorization: Bearer $auth_token" \
    "$FMSG_API_URL/fmsg/$draft_id/send" >/dev/null
}

MSG_NO_ATTACH=$(build_large_text "body-only-$TEST_TOKEN")
MSG_WITH_ATTACH=$(build_large_text "body-with-attachment-$TEST_TOKEN")
ATTACH_FILE="$TMP_DIR/compression-attachment.txt"
ATTACH_DOWNLOADED="$TMP_DIR/downloaded-compression-attachment.txt"

printf '%s' "$(build_large_text "attachment-$TEST_TOKEN")" > "$ATTACH_FILE"

if [ "${#MSG_NO_ATTACH}" -le 512 ]; then
  fail_test "test setup error: expected MSG_NO_ATTACH to exceed 512 bytes"
fi

if [ "${#MSG_WITH_ATTACH}" -le 512 ]; then
  fail_test "test setup error: expected MSG_WITH_ATTACH to exceed 512 bytes"
fi

if [ "$(wc -c < "$ATTACH_FILE")" -le 512 ]; then
  fail_test "test setup error: expected attachment payload to exceed 512 bytes"
fi

echo "    Sending large message without attachment: @alice@hairpin.local -> @bob@example.com"
export FMSG_API_URL="$HAIRPIN_API_URL"
fmsg login '@alice@hairpin.local'
fmsg send '@bob@example.com' "$MSG_NO_ATTACH" >/dev/null

echo "    Waiting for delivery of large message without attachment"
export FMSG_API_URL="$EXAMPLE_API_URL"
fmsg login '@bob@example.com'
MSG_NO_ATTACH_ID=$(wait_for_message_id_by_data "$MSG_NO_ATTACH")
echo "    Received message ID (no attachment): $MSG_NO_ATTACH_ID"

fmsg get-data "$MSG_NO_ATTACH_ID" "$TMP_DIR/no-attach-data.txt"
if ! grep -Fxq "$MSG_NO_ATTACH" "$TMP_DIR/no-attach-data.txt"; then
  fail_test "downloaded body for no-attachment message did not match sent content"
fi

echo "    Sending large message with large attachment: @alice@hairpin.local -> @bob@example.com"
export FMSG_API_URL="$HAIRPIN_API_URL"
fmsg login '@alice@hairpin.local'
send_draft_with_attachment "$MSG_WITH_ATTACH" "$ATTACH_FILE"

echo "    Waiting for delivery of large message with attachment"
export FMSG_API_URL="$EXAMPLE_API_URL"
fmsg login '@bob@example.com'
MSG_WITH_ATTACH_ID=$(wait_for_message_id_by_data "$MSG_WITH_ATTACH")
echo "    Received message ID (with attachment): $MSG_WITH_ATTACH_ID"

MSG_WITH_ATTACH_OUTPUT=$(fmsg get "$MSG_WITH_ATTACH_ID")
if ! echo "$MSG_WITH_ATTACH_OUTPUT" | grep -q 'compression-attachment.txt'; then
  fail_test "attachment filename was not present in received message output"
fi

fmsg get-data "$MSG_WITH_ATTACH_ID" "$TMP_DIR/with-attach-data.txt"
if ! grep -Fxq "$MSG_WITH_ATTACH" "$TMP_DIR/with-attach-data.txt"; then
  fail_test "downloaded body for attachment message did not match sent content"
fi

fmsg get-attach "$MSG_WITH_ATTACH_ID" compression-attachment.txt "$ATTACH_DOWNLOADED"
cmp -s "$ATTACH_FILE" "$ATTACH_DOWNLOADED" || fail_test "downloaded attachment content did not match sent content"
