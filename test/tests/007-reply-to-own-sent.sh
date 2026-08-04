#!/usr/bin/env bash
# Test: Reply to a message the SENDER's own host originated (a pid chain),
# delivered cross-instance.
#
# Regression coverage for the shared-hash/deflate form bug: the sender
# recorded the parent's sha256 over the undeflated header form while the
# receiving host stored the transmitted (deflated) form, so a reply to your
# own sent message carried a psha256 the remote host could not match and
# bounced with code 6 (parent not found). Test 002 does not cover this: it
# replies to a RECEIVED message, whose stored hash is always the transmitted
# form. The body is made large and compressible so deflate engages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"

build_compressible_text() {
  local suffix="$1"
  local chunk="chain-compressible-$suffix-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
  local out=""
  local i
  for i in $(seq 1 16); do
    out+="$chunk"
  done
  echo "$out"
}

ROOT_TEXT="$(build_compressible_text "root-$TEST_TOKEN")"
REPLY_TEXT="$(build_compressible_text "reply-$TEST_TOKEN")"

echo "    Sending chain root: $BOB_ADDR -> $ALICE_ADDR"
ROOT_OUTPUT=$(fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" send "$ALICE_ADDR" "$ROOT_TEXT")
echo "$ROOT_OUTPUT"
ROOT_ID=$(extract_send_id "$ROOT_OUTPUT")
[ -n "$ROOT_ID" ] || fail_test "could not extract root message ID"

echo "    Waiting for root delivery to $ALICE_ADDR..."
wait_for_message_id_by_data "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$ROOT_TEXT" > /dev/null

echo "    Replying to own sent message $ROOT_ID (pid chain): $BOB_ADDR -> $ALICE_ADDR"
REPLY_OUTPUT=$(fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" send --pid "$ROOT_ID" "$ALICE_ADDR" "$REPLY_TEXT")
echo "$REPLY_OUTPUT"

echo "    Waiting for chained reply delivery to $ALICE_ADDR..."
REPLY_MSG_ID=$(wait_for_message_id_by_data "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$REPLY_TEXT")
echo "    Using received reply message ID: $REPLY_MSG_ID"

MSG_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" get "$REPLY_MSG_ID")
echo "$MSG_OUTPUT"

if ! echo "$MSG_OUTPUT" | grep -q "^From: $BOB_ADDR$"; then
  fail_test "received reply $REPLY_MSG_ID was not from $BOB_ADDR"
fi

if ! echo "$MSG_OUTPUT" | grep -q '^PID:'; then
  fail_test "received reply $REPLY_MSG_ID did not carry a pid — chain link lost"
fi

echo "    OK: chained reply to own sent message delivered cross-instance"
