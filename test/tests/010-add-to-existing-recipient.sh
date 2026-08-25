#!/usr/bin/env bash
# Test: add-to a recipient who is ALREADY in the message's _to_ list.
#
# Per SPEC v0.5.0 an address MAY appear in both _to_ and _add to_ — it
# re-serves an original recipient who no longer has the message. Recipients
# are not a set: addresses need only be distinct within each list, and an
# address in both is a recipient of each, receiving one response code for its
# _to_ entry and one for its _add to_ entry.
#
# The batch here carries to=[bob] and add_to=[bob, carol], so example.com owes
# hairpin.local THREE per-recipient codes: bob's _to_ entry, bob's _add to_
# entry, then carol's. Carol receiving the message is the end-to-end proof
# that the header was accepted and the code stream stayed in step — a
# miscounted stream would misattribute her code.
#
# Regression coverage for fmsgd#41. Before it, fmsgd rejected any add-to
# carrying an address already in _to_ with header code 1 (invalid), so the
# batch never reached the per-recipient stage and carol never received the
# message — while fmsg-webapi accepted the same request (it has always
# allowed re-adding an original _to_ recipient, citing SPEC NOTE II). This
# test pins that mismatch closed.
#
# NOT covered: bob still holds the message, so his _add to_ entry is answered
# 103 (user duplicate) rather than 200. Exercising the accept path for an
# overlapping address would require bob to have lost his copy, which this
# harness cannot arrange.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"
ROOT_TEXT="Hello Bob, this message starts the add-to-existing-recipient test. [$TEST_TOKEN]"

psql_hairpin() {
  docker exec hairpin-postgres-1 psql -U postgres -d fmsgd -tAc "$1"
}

# wait_for_code <table> <addr> <expected> — polls until the sender has recorded
# the per-recipient response code, which it writes when the exchange commits.
wait_for_code() {
  local table="$1" addr="$2" expected="$3" attempt code=""
  for attempt in $(seq 1 20); do
    code=$(psql_hairpin "select coalesce(response_code::text, '') from $table where msg_id = $ROOT_MSG_ID and lower(addr) = lower('$addr')" 2>/dev/null || true)
    [ "$code" = "$expected" ] && { echo "$code"; return; }
    sleep 1
  done
  fail_test "$table.response_code for $addr was '${code:-<none>}', want $expected"
}

echo "    Sending root message: $ALICE_ADDR -> $BOB_ADDR"
SEND_OUTPUT=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" send "$BOB_ADDR" "$ROOT_TEXT")
echo "$SEND_OUTPUT"
ROOT_MSG_ID=$(extract_send_id "$SEND_OUTPUT")
[ -n "$ROOT_MSG_ID" ] || fail_test "could not determine root message ID from fmsg send output"
echo "    Using root message ID: $ROOT_MSG_ID"

echo "    Waiting for bob to receive the root message"
BOB_MSG_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$ROOT_TEXT")
echo "    Bob received root message ID: $BOB_MSG_ID"

echo "    Confirming bob's original delivery was accepted"
BOB_TO_CODE=$(wait_for_code msg_to "$BOB_ADDR" 200)
echo "    msg_to code for $BOB_ADDR: $BOB_TO_CODE"

# Bob is already in _to_; carol is new. fmsg-webapi rejects only addresses
# already in a previous batch, so this call must succeed.
echo "    Adding $BOB_ADDR (already a recipient) and $CAROL_ADDR via add-to $ROOT_MSG_ID"
fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" add-to "$ROOT_MSG_ID" "$BOB_ADDR" "$CAROL_ADDR"

echo "    Waiting for carol to receive the message via the add-to batch..."
CAROL_MSG_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$CAROL_API_KEY" "$ROOT_TEXT" 30)
echo "    Carol received message ID: $CAROL_MSG_ID"

MSG_OUTPUT=$(fmsg_as "$EXAMPLE_API_URL" "$CAROL_API_KEY" get "$CAROL_MSG_ID")
echo "$MSG_OUTPUT"
if ! echo "$MSG_OUTPUT" | grep -q "^From: $ALICE_ADDR$"; then
  fail_test "received message $CAROL_MSG_ID was not from $ALICE_ADDR"
fi

echo "    Verifying the batch recorded a per-recipient code for each entry"
BATCH_ROWS=$(psql_hairpin "select count(*) from msg_add_to where msg_id = $ROOT_MSG_ID")
if [ "$BATCH_ROWS" != "2" ]; then
  fail_test "expected 2 msg_add_to rows for msg $ROOT_MSG_ID (bob and carol), got $BATCH_ROWS"
fi

# Bob still holds the message, so his _add to_ entry is a duplicate. Getting
# 103 here — rather than 1 (invalid) — is what proves the receiving host
# processed the overlap per-recipient instead of rejecting the whole header.
BOB_ADD_TO_CODE=$(wait_for_code msg_add_to "$BOB_ADDR" 103)
echo "    msg_add_to code for $BOB_ADDR: $BOB_ADD_TO_CODE (user duplicate, as expected)"

CAROL_ADD_TO_CODE=$(wait_for_code msg_add_to "$CAROL_ADDR" 200)
echo "    msg_add_to code for $CAROL_ADDR: $CAROL_ADD_TO_CODE"

# The re-add must not disturb the original delivery record.
BOB_TO_CODE_AFTER=$(psql_hairpin "select coalesce(response_code::text, '') from msg_to where msg_id = $ROOT_MSG_ID and lower(addr) = lower('$BOB_ADDR')")
if [ "$BOB_TO_CODE_AFTER" != "200" ]; then
  fail_test "bob's original msg_to response code became '${BOB_TO_CODE_AFTER:-<none>}' after the re-add, want 200"
fi

echo "    OK: add-to of an existing _to_ recipient accepted; one code per recipient entry"
