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
# Regression coverage for fmsgd#35 (batch identity is the batch message
# hash, stored on msg_add_to_batch) and fmsgd#39 (replies resolving batch
# hashes; ensureBatchHash on the originator). fmsg-webapi cannot yet compose
# a reply referencing a batch, so this test injects the pending outbound
# reply directly into the sender host's database in the same shape
# fmsg-webapi writes — psha256 carries the parent hash; the relational pid
# stays null so the populate-psha256 trigger passes it through — and lets
# fmsgd deliver it cross-instance.
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

echo "    Injecting carol's pending reply to the batch (pid = batch hash) at example.com"
PAYLOAD_PATH="/opt/fmsg/data/example.com/carol/out/test-009-$TEST_TOKEN"
printf %s "$REPLY_TEXT" | docker exec -i example-fmsgd-1 sh -c "mkdir -p /opt/fmsg/data/example.com/carol/out && cat > $PAYLOAD_PATH"
REPLY_SIZE=$(printf %s "$REPLY_TEXT" | wc -c)

# Wrapped in a CTE because psql prints the "INSERT 0 1" command tag even
# with -tA; selecting from the CTE yields just the id.
REPLY_ROW_ID=$(psql_example "with ins as (
  insert into msg (version, no_reply, is_important, is_deflate, from_addr, topic, type, size, filepath, time_sent, psha256)
  values (1, false, false, false, '$CAROL_ADDR', '', 'text/plain;charset=UTF-8', $REPLY_SIZE, '$PAYLOAD_PATH', extract(epoch from now()), decode('$BATCH_HASH', 'hex'))
  returning id
) select id from ins")
[ -n "$REPLY_ROW_ID" ] || fail_test "could not insert carol's reply row at example.com"
psql_example "insert into msg_to (msg_id, addr) values ($REPLY_ROW_ID, '$ALICE_ADDR')" > /dev/null
echo "    Injected pending reply row ID: $REPLY_ROW_ID"

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
