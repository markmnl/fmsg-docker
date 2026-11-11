#!/usr/bin/env bash
# FMSG-008 edits: an author's edit federates as an ordinary terminal message
# and every reader, including one added later, sees the edited data.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"
ORIGINAL="I'll see you their at 5pm [$TEST_TOKEN]"
FIXED="I'll see you there at 5pm [$TEST_TOKEN]"
SECOND="See you there at 6pm [$TEST_TOKEN]"

# Poll until GET /fmsg/:id/data for the given identity equals the expected text.
wait_for_data() {
  local api_url="$1" api_key="$2" id="$3" expected="$4" attempt
  for attempt in $(seq 1 30); do
    if [ "$(api_json_get "$api_url" "$api_key" "/fmsg/$id/data")" = "$expected" ]; then
      return
    fi
    sleep 1
  done
  fail_test "timed out waiting for message $id to read: $expected"
}

echo "    Alice (hairpin) sends Bob (example) a message with a typo"
INPUT=$(jq -n --arg from "$ALICE_ADDR" --arg to "$BOB_ADDR" --arg body "$ORIGINAL" \
  '{version:1,from:$from,to:[$to],topic:"edits",type:"text/plain;charset=UTF-8",data:$body}')
ROOT_ID=$(api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST /fmsg "$INPUT" | jq -er '.id')
ROOT_HASH=$(api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST "/fmsg/$ROOT_ID/send" '{}' | jq -er '.sha256')
BOB_ROOT=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$ORIGINAL" 30)

echo "    Only the author can edit"
EDIT_INPUT=$(jq -n --arg body "hijacked" '{data:$body}')
BOB_TOKEN=$(curl -fsS -X POST -H "Authorization: Bearer $BOB_API_KEY" "$EXAMPLE_API_URL/fmsg/token" | jq -er '.access_token')
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $BOB_TOKEN" \
  -H 'Content-Type: application/json' --data "$EDIT_INPUT" "$EXAMPLE_API_URL/fmsg/$BOB_ROOT/edit")
[ "$STATUS" = 403 ] || fail_test "a recipient's edit returned HTTP $STATUS, expected 403"

echo "    Alice fixes the typo; the edit federates to Bob's host"
EDIT_INPUT=$(jq -n --arg body "$FIXED" '{data:$body}')
EDIT=$(api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST "/fmsg/$ROOT_ID/edit" "$EDIT_INPUT")
echo "$EDIT" | jq -e '.sha256 | test("^[0-9a-f]{64}$")' >/dev/null || fail_test "edit did not return a hash"
EDIT_HASH=$(echo "$EDIT" | jq -er '.sha256')
api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST "/fmsg/$ROOT_ID/edit" "$EDIT_INPUT" \
  | jq -e --arg hash "$EDIT_HASH" '.sha256 == $hash' >/dev/null || fail_test "repeating the edit was not idempotent"

wait_for_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$BOB_ROOT" "$FIXED"
api_json_get "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$BOB_ROOT" | jq -e --arg text "$FIXED" --arg hash "$ROOT_HASH" \
  '.edited != null and .edited.size == ($text | utf8bytelength) and .short_text == $text and .edit == false and .sha256 == $hash' >/dev/null \
  || fail_test "Bob's copy is not marked edited"
[ "$(api_json_get "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$BOB_ROOT/data?original=true")" = "$ORIGINAL" ] \
  || fail_test "the original is no longer available to Bob"

echo "    The edit message is a terminal reply of the edit type, flagged on Bob's host"
api_json_get "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$EDIT_HASH" | jq -e --arg root "$ROOT_HASH" \
  '.edit == true and .terminal and .no_reply and .type == "application/vnd.fmsg.edit" and .psha256 == $root' >/dev/null \
  || fail_test "Bob's host did not recognise the edit message"

echo "    Bob adds Carol; Alice edits again and Carol sees it"
ADD_INPUT=$(jq -n --arg addr "$CAROL_ADDR" '{add_to:[$addr]}')
api_json_write "$EXAMPLE_API_URL" "$BOB_API_KEY" POST "/fmsg/$BOB_ROOT/add-to" "$ADD_INPUT" >/dev/null
FOUND=false
for attempt in $(seq 1 30); do
  if api_json_get "$HAIRPIN_API_URL" "$ALICE_API_KEY" "/fmsg/$ROOT_ID" | jq -e 'any(.add_to[]?; .sha256 != null)' >/dev/null; then
    FOUND=true
    break
  fi
  sleep 1
done
[ "$FOUND" = true ] || fail_test "Alice's host did not learn of the added recipient"

EDIT_INPUT=$(jq -n --arg body "$SECOND" '{data:$body}')
api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST "/fmsg/$ROOT_ID/edit" "$EDIT_INPUT" >/dev/null
wait_for_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$BOB_ROOT" "$SECOND"
wait_for_data "$EXAMPLE_API_URL" "$CAROL_API_KEY" "$ROOT_HASH" "$SECOND"

echo "    Alice reverts; everyone reads the original again"
api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST "/fmsg/$ROOT_ID/edit" '{"data":null}' >/dev/null
wait_for_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$BOB_ROOT" "$ORIGINAL"
wait_for_data "$EXAMPLE_API_URL" "$CAROL_API_KEY" "$ROOT_HASH" "$ORIGINAL"
api_json_get "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$BOB_ROOT" | jq -e '.edited == null' >/dev/null \
  || fail_test "Bob's copy is still marked edited after the revert"

echo "    OK: edits federate, reach added recipients, stay author-only and revert"
