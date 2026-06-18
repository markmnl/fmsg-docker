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
  local api_url="$1"
  local api_key="$2"
  local recipient="$3"
  local message_text="$4"
  local attachment_path="$5"
  local create_output
  local draft_id

  create_output=$(fmsg_as "$api_url" "$api_key" draft create "$recipient" "$message_text")

  draft_id=$(extract_send_id "$create_output")
  if [ -z "$draft_id" ]; then
    fail_test "could not determine draft message ID from CLI output"
  fi

  fmsg_as "$api_url" "$api_key" attach "$draft_id" "$attachment_path"

  fmsg_as "$api_url" "$api_key" draft send "$draft_id" >/dev/null
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

echo "    Sending large message without attachment: $ALICE_ADDR -> $BOB_ADDR"
fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" send "$BOB_ADDR" "$MSG_NO_ATTACH" >/dev/null

echo "    Waiting for delivery of large message without attachment"
MSG_NO_ATTACH_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$MSG_NO_ATTACH")
echo "    Received message ID (no attachment): $MSG_NO_ATTACH_ID"

fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get-data "$MSG_NO_ATTACH_ID" "$TMP_DIR/no-attach-data.txt"
if ! grep -Fxq "$MSG_NO_ATTACH" "$TMP_DIR/no-attach-data.txt"; then
  fail_test "downloaded body for no-attachment message did not match sent content"
fi

echo "    Sending large message with large attachment: $ALICE_ADDR -> $BOB_ADDR"
send_draft_with_attachment "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$BOB_ADDR" "$MSG_WITH_ATTACH" "$ATTACH_FILE"

echo "    Waiting for delivery of large message with attachment"
MSG_WITH_ATTACH_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$MSG_WITH_ATTACH")
echo "    Received message ID (with attachment): $MSG_WITH_ATTACH_ID"

MSG_WITH_ATTACH_OUTPUT=$(fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get "$MSG_WITH_ATTACH_ID")
if ! echo "$MSG_WITH_ATTACH_OUTPUT" | grep -q 'compression-attachment.txt'; then
  fail_test "attachment filename was not present in received message output"
fi

fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get-data "$MSG_WITH_ATTACH_ID" "$TMP_DIR/with-attach-data.txt"
if ! grep -Fxq "$MSG_WITH_ATTACH" "$TMP_DIR/with-attach-data.txt"; then
  fail_test "downloaded body for attachment message did not match sent content"
fi

fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get-attach "$MSG_WITH_ATTACH_ID" compression-attachment.txt "$ATTACH_DOWNLOADED"
cmp -s "$ATTACH_FILE" "$ATTACH_DOWNLOADED" || fail_test "downloaded attachment content did not match sent content"
