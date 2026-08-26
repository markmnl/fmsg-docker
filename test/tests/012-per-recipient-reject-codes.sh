#!/usr/bin/env bash
# Test: per-recipient reject codes 100 (user unknown), 102 (user not
# accepting) and 101 (user full) — SPEC §10.4 step 6, §8.
#
# Every other test asserts a DELIVERY; nothing asserts a per-recipient
# REJECTION, so fmsgd's validateMsgRecvForAddr ladder is untested end to end
# and the sender-visible outcome of a bounce is unverified. The ladder checks
# in order duplicate -> unknown -> accepting -> limits, so each case below
# isolates one rung by leaving the earlier ones satisfied.
#
# All three sends are alice@hairpin.local -> an @example.com address, so each
# crosses the wire. example.com accepts the HEADER in every case: whether a
# recipient exists is not a header-level check (SPEC §10.3 step 3 asks only
# whether the recipient's DOMAIN is ours), so the message data is downloaded
# and the rejection is delivered as the per-recipient response byte. `fmsg
# send` only queues a message, so it succeeds in every case too — the
# assertion is on the recorded outcome, never on the CLI exit code.
#
# Each case is asserted twice: on the sender's msg_to.response_code (what
# fmsgd recorded off the wire) and on GET /fmsg/:id to_delivery (what a client
# actually sees) — the latter being the only way a user learns why a message
# bounced.
#
# Three implementation details shape this test:
#  * Code 101 is RETRYABLE (fmsgd sender.go retryableResponseCodes); 100 and
#    102 are terminal. Once carol's quota is restored the 101 message will
#    eventually be delivered by a retry, so non-delivery is asserted only for
#    the terminal 102 case.
#  * Carol cannot authenticate while accepting_new is false — the webapi token
#    exchange itself consults fmsgid — so her inbox is inspected only after
#    the flag is restored.
#  * fmsgd does not cache fmsgid lookups (id.go issues a bare HTTP GET), so
#    these fmsgid edits take effect on the next delivery attempt with no
#    restart or cache-bust needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

command -v jq >/dev/null || fail_test "jq is required for this test"
command -v curl >/dev/null || fail_test "curl is required for this test"

TEST_TOKEN="$(date +%s)-$$"
DAVE_ADDR="@dave@example.com"
CAROL_LOWER="@carol@example.com"

UNKNOWN_TEXT="Hello Dave, nobody by that name here. [$TEST_TOKEN]"
NOT_ACCEPTING_TEXT="Hello Carol, you are not accepting right now. [$TEST_TOKEN]"
FULL_TEXT="Hello Carol, your inbox is over quota. [$TEST_TOKEN]"

psql_hairpin() {
  docker exec hairpin-postgres-1 psql -U postgres -d fmsgd -tAc "$1"
}

psql_example_id() {
  docker exec example-postgres-1 psql -U postgres -d fmsgid -tAc "$1"
}

# Capture carol's real fmsgid settings so the restore puts back what was
# there rather than the schema defaults, and restore on ANY exit — leaving
# carol not-accepting would break every later test that involves her.
# psql -tA renders booleans as t/f, which is not valid input to an UPDATE,
# so read the flag back in a form that can be written straight back out.
CAROL_ACCEPTING_ORIG=$(psql_example_id "select case when accepting_new then 'true' else 'false' end from address where address_lower = '$CAROL_LOWER'")
CAROL_LIMIT_ORIG=$(psql_example_id "select limit_recv_count_per_1d from address where address_lower = '$CAROL_LOWER'")
[ -n "$CAROL_ACCEPTING_ORIG" ] || fail_test "could not read carol's accepting_new from fmsgid"
[ -n "$CAROL_LIMIT_ORIG" ] || fail_test "could not read carol's limit_recv_count_per_1d from fmsgid"

restore_carol() {
  psql_example_id "update address set accepting_new = $CAROL_ACCEPTING_ORIG, limit_recv_count_per_1d = $CAROL_LIMIT_ORIG where address_lower = '$CAROL_LOWER'" > /dev/null
}
trap restore_carol EXIT

# Poll the sender's recipient row until fmsgd records a response code for it.
# Code and delivery time are read in ONE query so a retry landing between two
# separate reads cannot produce a self-contradictory result. Prints
# "<code>|<time_delivered or null>".
wait_for_recipient_outcome() {
  local msg_id="$1"
  local addr="$2"
  local timeout="${3:-30}"
  local attempt
  local row

  for attempt in $(seq 1 "$timeout"); do
    row=$(psql_hairpin "select coalesce(response_code::text, '') || '|' || coalesce(time_delivered::text, 'null') from msg_to where msg_id = $msg_id and lower(addr) = lower('$addr')" 2>/dev/null || true)
    if [ -n "${row%%|*}" ]; then
      echo "$row"
      return
    fi
    sleep 1
  done

  fail_test "timed out waiting for a response code for $addr on message $msg_id"
}

# The response code fmsg-webapi reports for one recipient of one message.
api_response_code() {
  local msg_id="$1"
  local addr="$2"
  local addr_lower

  addr_lower=$(printf '%s' "$addr" | tr '[:upper:]' '[:lower:]')
  api_json_get "$HAIRPIN_API_URL" "$ALICE_API_KEY" "/fmsg/$msg_id" \
    | jq -r --arg a "$addr_lower" \
        '[.to_delivery[]? | select((.addr | ascii_downcase) == $a) | .response_code] | first // empty'
}

# Send one message and assert it bounced with exactly the expected
# per-recipient code, both in fmsgd's record and over the web API.
assert_rejected_with() {
  local label="$1"
  local recipient="$2"
  local expected="$3"
  local text="$4"
  local send_output
  local msg_id
  local outcome
  local code
  local delivered
  local api_code

  echo "    [$label] sending $ALICE_ADDR -> $recipient"
  send_output=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" send "$recipient" "$text")
  msg_id=$(extract_send_id "$send_output")
  [ -n "$msg_id" ] || fail_test "[$label] could not determine message ID from fmsg send output"

  outcome=$(wait_for_recipient_outcome "$msg_id" "$recipient")
  code="${outcome%%|*}"
  delivered="${outcome##*|}"

  if [ "$code" != "$expected" ]; then
    fail_test "[$label] expected per-recipient code $expected for $recipient, fmsgd recorded $code"
  fi
  if [ "$delivered" != "null" ]; then
    fail_test "[$label] $recipient was marked delivered (time_delivered=$delivered) despite response code $code"
  fi

  api_code=$(api_response_code "$msg_id" "$recipient")
  if [ "$api_code" != "$expected" ]; then
    fail_test "[$label] GET /fmsg/$msg_id to_delivery reported '${api_code:-<absent>}' for $recipient, expected $expected"
  fi

  echo "    [$label] OK: code $expected recorded by fmsgd and surfaced by the web API (message $msg_id)"
}

# Fail if the given text ever turns up in a mailbox.
assert_not_received() {
  local label="$1"
  local api_url="$2"
  local api_key="$3"
  local expected_data="$4"
  local tmp_file
  local ids
  local id

  tmp_file=$(mktemp)
  ids=$(fmsg_as "$api_url" "$api_key" list --limit 20 2>/dev/null | sed -n 's/^ID: \([0-9][0-9]*\).*/\1/p')
  for id in $ids; do
    if fmsg_as "$api_url" "$api_key" get-data "$id" "$tmp_file" >/dev/null 2>&1 && grep -Fxq "$expected_data" "$tmp_file"; then
      rm -f "$tmp_file"
      fail_test "[$label] message was delivered (as ID $id) but should have been rejected"
    fi
  done
  rm -f "$tmp_file"
}

# ── 100 user unknown ─────────────────────────────────────────
# dave is never seeded into example.com's fmsgid, so the address is unknown
# on a domain we do host.
assert_rejected_with "100 user unknown" "$DAVE_ADDR" 100 "$UNKNOWN_TEXT"

# ── 102 user not accepting ───────────────────────────────────
echo "    Setting $CAROL_ADDR to not accepting new messages"
psql_example_id "update address set accepting_new = false where address_lower = '$CAROL_LOWER'" > /dev/null
assert_rejected_with "102 user not accepting" "$CAROL_ADDR" 102 "$NOT_ACCEPTING_TEXT"

echo "    Restoring $CAROL_ADDR to accepting new messages"
psql_example_id "update address set accepting_new = $CAROL_ACCEPTING_ORIG where address_lower = '$CAROL_LOWER'" > /dev/null

# Code 102 is terminal, so the rejection is final: no retry will ever deliver
# this message. Carol's mailbox is only reachable now that she is accepting
# again — the token exchange consults fmsgid.
assert_not_received "102 user not accepting" "$EXAMPLE_API_URL" "$CAROL_API_KEY" "$NOT_ACCEPTING_TEXT"
echo "    Confirmed the not-accepting message was never delivered"

# ── 101 user full ────────────────────────────────────────────
# A daily receive count limit of 0 rejects the very next message regardless of
# what carol has already received in this run.
echo "    Setting $CAROL_ADDR daily receive count limit to 0"
psql_example_id "update address set limit_recv_count_per_1d = 0 where address_lower = '$CAROL_LOWER'" > /dev/null
assert_rejected_with "101 user full" "$CAROL_ADDR" 101 "$FULL_TEXT"

echo "    Restoring $CAROL_ADDR daily receive count limit to $CAROL_LIMIT_ORIG"
psql_example_id "update address set limit_recv_count_per_1d = $CAROL_LIMIT_ORIG where address_lower = '$CAROL_LOWER'" > /dev/null

echo "    OK: per-recipient codes 100, 102 and 101 all recorded and reported"
