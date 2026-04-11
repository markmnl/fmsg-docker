#!/usr/bin/env bash
# Test: Reply from @bob@example.com back to @alice@hairpin.local
# using the parent message ID (pid 1 on a clean database).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"
MESSAGE_TEXT="Hey there Alice, got your message! [$TEST_TOKEN]"

echo "    Sending reply: @bob@example.com → @alice@hairpin.local (pid 1)"
export FMSG_API_URL="$EXAMPLE_API_URL"
fmsg login '@bob@example.com'
SEND_OUTPUT=$(fmsg send --pid 1 '@alice@hairpin.local' "$MESSAGE_TEXT")
echo "$SEND_OUTPUT"

echo "    Waiting for cross-instance delivery..."
export FMSG_API_URL="$HAIRPIN_API_URL"
fmsg login '@alice@hairpin.local'
MSG_ID=$(wait_for_message_id_by_data "$MESSAGE_TEXT")
echo "    Using received message ID: $MSG_ID"

echo "    Reading received message as @alice@hairpin.local"
MSG_OUTPUT=$(fmsg get "$MSG_ID")
echo "$MSG_OUTPUT"

if ! echo "$MSG_OUTPUT" | grep -q '^From: @bob@example.com$'; then
  fail_test "received message $MSG_ID was not from @bob@example.com"
fi
