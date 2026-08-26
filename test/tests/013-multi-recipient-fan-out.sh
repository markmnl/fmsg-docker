#!/usr/bin/env bash
# Test: multi-recipient messages — the per-recipient code stream for two
# recipients sharing a domain, and fan-out across two domains (SPEC §10.2,
# §10.2 step 6, §10.4 step 6, §11).
#
# Every other test sends to exactly ONE recipient, so two things have never
# been exercised:
#
#  1. The per-recipient response byte STREAM. When two recipients share a
#     domain, the sending host opens one connection and reads one byte per
#     recipient, matched POSITIONALLY to _to_ order. With a single recipient
#     a misaligned stream is indistinguishable from a correct one.
#  2. Fan-out across unique recipient domains, where responsibility is split:
#     fmsgd records the outcome for remote recipients off the wire, while
#     fmsg-webapi's resolveLocalDelivery records it for same-domain ones —
#     fmsgd's sender deliberately skips the local domain, so nothing else
#     would ever set them.
#
# Cases A1/A2 pair the unseeded @dave@example.com (rejected 100, see test 012)
# with @bob@example.com (accepted 200) and send them in BOTH orders. Identical
# codes would prove nothing; differing codes in both orders is what makes a
# one-byte misalignment — or an implementation that matches codes to addresses
# rather than to positions — impossible to miss.
#
# Case B fans one message out to two domains at once, and additionally asserts
# what SPEC §11 makes a MUST and no test covers: a receiving host retains the
# COMPLETE _to_ list, including recipients on other domains, so participant
# checks and hash recomputation stay faithful. The same is asserted of bob's
# copy in A1, which must retain the rejected dave.
#
# NOTE fmsg-cli has no multi-recipient `send`, so these go out as drafts:
# create, replace the recipient list with `update --to`, then `draft send`.
# The body is deliberately passed again on the update call: despite the CLI's
# "only provided fields are updated", PUT /fmsg/:id rewrites the whole message
# from the payload, so an update without a body would leave an empty one.
# Recipient order survives as given — Update re-inserts msg_to in list order
# and fmsgd loads it ORDER BY id — which is what lets these cases pin ordering.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

command -v jq >/dev/null || fail_test "jq is required for this test"
command -v curl >/dev/null || fail_test "curl is required for this test"

TEST_TOKEN="$(date +%s)-$$"
DAVE_ADDR="@dave@example.com"

A1_TEXT="Fan-out A1: dave first, bob second. [$TEST_TOKEN]"
A2_TEXT="Fan-out A2: bob first, dave second. [$TEST_TOKEN]"
B_TEXT="Fan-out B: one message, two domains. [$TEST_TOKEN]"

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Send one message to several recipients, in the given order, and print its ID.
send_to_many() {
  local api_url="$1"
  local api_key="$2"
  local recipients="$3"   # comma-separated, in wire order
  local text="$4"
  local first
  local create_output
  local draft_id

  first="${recipients%%,*}"
  create_output=$(fmsg_as "$api_url" "$api_key" draft create "$first" "$text")
  draft_id=$(extract_send_id "$create_output")
  [ -n "$draft_id" ] || fail_test "could not determine draft ID from fmsg draft create output"

  fmsg_as "$api_url" "$api_key" update "$draft_id" --to "$recipients" "$text" > /dev/null
  fmsg_as "$api_url" "$api_key" draft send "$draft_id" > /dev/null

  echo "$draft_id"
}

# One field of one recipient's delivery record, from a message JSON document.
recipient_field() {
  local json="$1"
  local addr="$2"
  local field="$3"

  printf '%s' "$json" | jq -r --arg a "$(lower "$addr")" --arg f "$field" \
    '[.to_delivery[]? | select((.addr | ascii_downcase) == $a) | .[$f]] | first // empty'
}

# Poll GET /fmsg/:id until every recipient has an outcome recorded, then print
# the message JSON. One document is used for all assertions about a message so
# they describe a single consistent observation.
wait_for_all_outcomes() {
  local api_url="$1"
  local api_key="$2"
  local msg_id="$3"
  local expected_count="$4"
  local timeout="${5:-30}"
  local attempt
  local json
  local resolved

  for attempt in $(seq 1 "$timeout"); do
    json=$(api_json_get "$api_url" "$api_key" "/fmsg/$msg_id")
    resolved=$(printf '%s' "$json" | jq '[.to_delivery[]? | select(.response_code != null)] | length' 2>/dev/null || echo 0)
    if [ "$resolved" = "$expected_count" ]; then
      printf '%s' "$json"
      return
    fi
    sleep 1
  done

  fail_test "timed out waiting for all $expected_count recipients of message $msg_id to have an outcome"
}

# Assert one recipient's recorded code, and whether it counts as delivered.
assert_recipient() {
  local label="$1"
  local json="$2"
  local addr="$3"
  local expected_code="$4"
  local expect_delivered="$5"   # yes | no
  local code
  local delivered

  code=$(recipient_field "$json" "$addr" response_code)
  if [ "$code" != "$expected_code" ]; then
    fail_test "[$label] expected code $expected_code for $addr, got '${code:-<absent>}'"
  fi

  delivered=$(recipient_field "$json" "$addr" time_delivered)
  if [ "$expect_delivered" = "yes" ] && [ -z "$delivered" ]; then
    fail_test "[$label] $addr has code $code but no time_delivered"
  fi
  if [ "$expect_delivered" = "no" ] && [ -n "$delivered" ]; then
    fail_test "[$label] $addr was marked delivered ($delivered) despite code $code"
  fi
}

# Assert a message's _to_ list contains every given address.
assert_to_contains() {
  local label="$1"
  local json="$2"
  shift 2
  local addr

  for addr in "$@"; do
    if ! printf '%s' "$json" | jq -e --arg a "$(lower "$addr")" \
        '[.to[]? | ascii_downcase] | index($a) != null' > /dev/null; then
      fail_test "[$label] recipient list does not contain $addr — a host must retain the complete _to_ list (SPEC §11)"
    fi
  done
}

# ── A1: [dave, bob] on one domain — expect codes [100, 200] ──
echo "    [A1] sending $ALICE_ADDR -> $DAVE_ADDR, $BOB_ADDR (in that order)"
A1_ID=$(send_to_many "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$DAVE_ADDR,$BOB_ADDR" "$A1_TEXT")
A1_JSON=$(wait_for_all_outcomes "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$A1_ID" 2)
assert_recipient "A1" "$A1_JSON" "$DAVE_ADDR" 100 no
assert_recipient "A1" "$A1_JSON" "$BOB_ADDR" 200 yes
echo "    [A1] OK: first recipient rejected 100, second accepted 200 (message $A1_ID)"

echo "    [A1] waiting for bob to receive it"
A1_BOB_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$A1_TEXT")
A1_BOB_JSON=$(api_json_get "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$A1_BOB_ID")
assert_to_contains "A1 received" "$A1_BOB_JSON" "$DAVE_ADDR" "$BOB_ADDR"
echo "    [A1] OK: received copy $A1_BOB_ID retains both recipients, including the rejected one"

# ── A2: [bob, dave] — the same pair reversed, expect [200, 100] ──
# If codes were matched to addresses rather than to positions, or the stream
# were misaligned by one, exactly one of A1/A2 would still pass.
echo "    [A2] sending $ALICE_ADDR -> $BOB_ADDR, $DAVE_ADDR (reversed)"
A2_ID=$(send_to_many "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$BOB_ADDR,$DAVE_ADDR" "$A2_TEXT")
A2_JSON=$(wait_for_all_outcomes "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$A2_ID" 2)
assert_recipient "A2" "$A2_JSON" "$BOB_ADDR" 200 yes
assert_recipient "A2" "$A2_JSON" "$DAVE_ADDR" 100 no
echo "    [A2] OK: reversing the recipients reversed the codes (message $A2_ID)"

echo "    [A2] waiting for bob to receive it"
wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$A2_TEXT" > /dev/null
echo "    [A2] OK: bob received the message"

# ── B: two domains at once — one remote, one local ──
echo "    [B] sending $BOB_ADDR -> $ALICE_ADDR (remote), $CAROL_ADDR (local)"
B_ID=$(send_to_many "$EXAMPLE_API_URL" "$BOB_API_KEY" "$ALICE_ADDR,$CAROL_ADDR" "$B_TEXT")
B_JSON=$(wait_for_all_outcomes "$EXAMPLE_API_URL" "$BOB_API_KEY" "$B_ID" 2)
# alice's outcome is recorded by fmsgd off the wire; carol's by fmsg-webapi,
# since fmsgd's sender skips the local domain entirely.
assert_recipient "B" "$B_JSON" "$ALICE_ADDR" 200 yes
assert_recipient "B" "$B_JSON" "$CAROL_ADDR" 200 yes
echo "    [B] OK: both domains accepted (message $B_ID)"

echo "    [B] waiting for alice (remote domain) to receive it"
B_ALICE_ID=$(wait_for_message_id_by_data "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$B_TEXT")
B_ALICE_JSON=$(api_json_get "$HAIRPIN_API_URL" "$ALICE_API_KEY" "/fmsg/$B_ALICE_ID")
assert_to_contains "B received" "$B_ALICE_JSON" "$ALICE_ADDR" "$CAROL_ADDR"
echo "    [B] OK: hairpin.local retained $CAROL_ADDR too, a recipient on another domain"

echo "    [B] waiting for carol (local domain) to receive it"
wait_for_message_id_by_data "$EXAMPLE_API_URL" "$CAROL_API_KEY" "$B_TEXT" > /dev/null
echo "    [B] OK: local recipient received the message"

echo "    OK: per-recipient code stream is positional, and fan-out reaches both domains"
