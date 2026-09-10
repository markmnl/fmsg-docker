#!/usr/bin/env bash
# Test: Reply to an add-to BATCH message — the reply's pid is the batch
# message's hash, not the original message's.
#
# Per SPEC v0.5.0, recipients added in an add-to batch are participants of
# the batch message only, so their replies MUST reference the batch via pid.
# Verifying Message Stored (SPEC §11) requires every participant host to
# resolve that batch hash even though the batch's message data never crossed
# the wire again: a host receiving the batch with code 65/11 computes the
# hash from the add-to header plus its stored copy of the original data, and
# the originating host persists the hash of batches it sends.
#
# Compose the reply through the API using the batch hash. No direct database
# injection is needed: the API preserves the exact protocol parent reference.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"
ROOT_TEXT="Hello Bob, this message starts the reply-to-batch test. [$TEST_TOKEN]"
REPLY_TEXT="Hello all, this reply references the add-to batch message. [$TEST_TOKEN]"

psql_example() {
  docker exec example-postgres-1 psql -U postgres -d fmsgd -tAc "$1"
}

psql_hairpin() {
  docker exec hairpin-postgres-1 psql -U postgres -d fmsgd -tAc "$1"
}

echo "    Sending root message: $ALICE_ADDR -> $BOB_ADDR"
SEND_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" send "$BOB_ADDR" "$ROOT_TEXT")
echo "$SEND_OUTPUT"
ROOT_MSG_ID=$(extract_send_id "$SEND_OUTPUT")
[ -n "$ROOT_MSG_ID" ] || fail_test "could not determine root message ID from fmsg send output"

echo "    Waiting for bob to receive the root message"
BOB_MSG_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$ROOT_TEXT")
echo "    Bob received root message ID: $BOB_MSG_ID"

echo "    Adding $CAROL_ADDR as recipient via add-to $ROOT_MSG_ID"
fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" add-to "$ROOT_MSG_ID" "$CAROL_ADDR"

echo "    Waiting for carol to receive the message via add-to"
wait_for_message_id_by_data "$EXAMPLE_API_URL" "$CAROL_API_KEY" "$ROOT_TEXT" > /dev/null

echo "    Reading the recorded batch hash from example.com (receiver side)"
BATCH_HASH=""
for attempt in $(seq 1 15); do
  BATCH_HASH=$(psql_example "select encode(b.sha256, 'hex') from msg_add_to_batch b where b.msg_id = $BOB_MSG_ID and b.sha256 is not null order by b.id desc limit 1" 2>/dev/null || true)
  [ -n "$BATCH_HASH" ] && break
  sleep 1
done
if [ -z "$BATCH_HASH" ]; then
  fail_test "example.com did not record the add-to batch hash — the batch message cannot be referenced by replies (fmsgd#35/#39)"
fi
echo "    Batch hash (example.com): $BATCH_HASH"

echo "    Reading the persisted batch hash from hairpin.local (originator side)"
HAIRPIN_BATCH_HASH=$(psql_hairpin "select encode(b.sha256, 'hex') from msg_add_to_batch b where b.msg_id = $ROOT_MSG_ID and b.sha256 is not null order by b.id desc limit 1" 2>/dev/null || true)
if [ -z "$HAIRPIN_BATCH_HASH" ]; then
  fail_test "hairpin.local (batch originator) did not persist the batch hash — it could not resolve replies to its own batch (fmsgd#39)"
fi
if [ "$HAIRPIN_BATCH_HASH" != "$BATCH_HASH" ]; then
  fail_test "batch hash mismatch: originator computed $HAIRPIN_BATCH_HASH, receiver reconstructed $BATCH_HASH — the batch message is not faithfully reconstructible"
fi
echo "    Originator and receiver agree on the batch hash"

echo "    Creating carol's reply through the API using the batch hash"
REPLY_INPUT=$(jq -n --arg from "$CAROL_ADDR" --arg to "$ALICE_ADDR" \
  --arg parent "$BATCH_HASH" --arg body "$REPLY_TEXT" \
  '{version:1, from:$from, to:[$to], pid:$parent, topic:"", type:"text/plain;charset=UTF-8", data:$body}')
REPLY_ROW_ID=$(api_json_write "$EXAMPLE_API_URL" "$CAROL_API_KEY" POST /fmsg "$REPLY_INPUT" | jq -er '.id')
REPLY_HASH=$(api_json_write "$EXAMPLE_API_URL" "$CAROL_API_KEY" POST "/fmsg/$REPLY_ROW_ID/send" '{}' | jq -er '.sha256')
[[ "$REPLY_HASH" =~ ^[0-9a-f]{64}$ ]] || fail_test "reply was sent without a hash"

echo "    Waiting for cross-instance delivery of the batch reply to $ALICE_ADDR..."
ALICE_REPLY_ID=$(wait_for_message_id_by_data "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$REPLY_TEXT" 30)
echo "    Alice received reply message ID: $ALICE_REPLY_ID"

MSG_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" get "$ALICE_REPLY_ID")
echo "$MSG_OUTPUT"
if ! echo "$MSG_OUTPUT" | grep -q "^From: $CAROL_ADDR$"; then
  fail_test "received reply $ALICE_REPLY_ID was not from $CAROL_ADDR"
fi

echo "    Verifying the stored reply references the batch and links into the thread"
STORED_PSHA=$(psql_hairpin "select encode(psha256, 'hex') from msg where id = $ALICE_REPLY_ID")
if [ "$STORED_PSHA" != "$BATCH_HASH" ]; then
  fail_test "stored reply psha256 ($STORED_PSHA) does not match the batch hash ($BATCH_HASH)"
fi
RELATIONAL_PID=$(psql_hairpin "select coalesce(pid, 0) from msg where id = $ALICE_REPLY_ID")
if [ "$RELATIONAL_PID" != "$ROOT_MSG_ID" ]; then
  fail_test "stored reply relational pid ($RELATIONAL_PID) does not link to the shared message row ($ROOT_MSG_ID)"
fi

echo "    OK: reply referencing the add-to batch hash delivered and linked cross-instance"
