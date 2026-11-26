#!/usr/bin/env bash
# Deleting a sent message for good (DELETE /fmsg/:id?permanent=true): each
# participant deletes their own copy, and a host removes the message once no
# local participant holds it and no delivery of it is still pending. That last
# check runs fmsg_api_delivery_pending from fmsg-webapi's dd.sql, so this test
# also fails when the stack's copy of that schema is out of date.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"

# http_status METHOD API_URL API_KEY PATH prints the status code of a request.
http_status() {
  local method="$1" api_url="$2" api_key="$3" path="$4" token
  token=$(curl -fsS -X POST -H "Authorization: Bearer $api_key" "$api_url/fmsg/token" | jq -er '.access_token')
  curl -s -o /dev/null -w '%{http_code}' -X "$method" -H "Authorization: Bearer $token" "$api_url$path"
}

# purge API_URL API_KEY ID deletes a message for good and prints the response.
purge() {
  local api_url="$1" api_key="$2" id="$3" token
  token=$(curl -fsS -X POST -H "Authorization: Bearer $api_key" "$api_url/fmsg/token" | jq -er '.access_token')
  curl -fsS -X DELETE -H "Authorization: Bearer $token" "$api_url/fmsg/$id?permanent=true" \
    || fail_test "deleting message $id for good failed at $api_url"
}

# Poll until every recipient of a sent message has a recorded outcome, so no
# delivery of it is pending when it is deleted.
wait_until_delivered() {
  local api_url="$1" api_key="$2" id="$3" attempt
  for attempt in $(seq 1 30); do
    if api_json_get "$api_url" "$api_key" "/fmsg/$id" \
      | jq -e '(.to_delivery | length) > 0 and all(.to_delivery[]; .response_code != null)' >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  fail_test "timed out waiting for message $id to be delivered"
}

echo "    Alice (hairpin) sends Bob (example) a message"
REMOTE_TEXT="delete me for good, across hosts [$TEST_TOKEN]"
ALICE_ID=$(extract_send_id "$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" send "$BOB_ADDR" "$REMOTE_TEXT")")
[ -n "$ALICE_ID" ] || fail_test "could not parse the sent message ID"
BOB_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$REMOTE_TEXT" 30)
wait_until_delivered "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$ALICE_ID"

echo "    Bob deletes it for good; his host no longer needs it"
purge "$EXAMPLE_API_URL" "$BOB_API_KEY" "$BOB_ID" \
  | jq -e '.trash == "purged" and .purged == 1 and .removed == 1' >/dev/null \
  || fail_test "Bob's delete did not remove the message from his host"
[ "$(http_status GET "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$BOB_ID")" = 404 ] \
  || fail_test "Bob can still read a message he deleted for good"
[ "$(http_status DELETE "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$BOB_ID?permanent=true")" = 404 ] \
  || fail_test "deleting an already deleted message did not answer 404"

echo "    Alice still has her copy, until she deletes it too"
[ "$(http_status GET "$HAIRPIN_API_URL" "$ALICE_API_KEY" "/fmsg/$ALICE_ID")" = 200 ] \
  || fail_test "Bob's delete took Alice's copy away"
purge "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$ALICE_ID" \
  | jq -e '.trash == "purged" and .purged == 1 and .removed == 1' >/dev/null \
  || fail_test "Alice's delete did not remove the delivered message from her host"
[ "$(http_status GET "$HAIRPIN_API_URL" "$ALICE_API_KEY" "/fmsg/$ALICE_ID")" = 404 ] \
  || fail_test "Alice can still read a message she deleted for good"

echo "    Bob sends Carol (same host) a message; the host keeps it while one of them holds it"
LOCAL_TEXT="delete me for good, on one host [$TEST_TOKEN]"
LOCAL_ID=$(extract_send_id "$(fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" send "$CAROL_ADDR" "$LOCAL_TEXT")")
[ -n "$LOCAL_ID" ] || fail_test "could not parse the sent message ID"
wait_for_message_id_by_data "$EXAMPLE_API_URL" "$CAROL_API_KEY" "$LOCAL_TEXT" 30 >/dev/null
wait_until_delivered "$EXAMPLE_API_URL" "$BOB_API_KEY" "$LOCAL_ID"

purge "$EXAMPLE_API_URL" "$CAROL_API_KEY" "$LOCAL_ID" \
  | jq -e '.trash == "purged" and .purged == 1 and .removed == 0' >/dev/null \
  || fail_test "Carol's delete removed a message Bob still holds"
[ "$(http_status GET "$EXAMPLE_API_URL" "$CAROL_API_KEY" "/fmsg/$LOCAL_ID")" = 404 ] \
  || fail_test "Carol can still read a message she deleted for good"
[ "$(http_status GET "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$LOCAL_ID")" = 200 ] \
  || fail_test "Carol's delete took Bob's copy away"

purge "$EXAMPLE_API_URL" "$BOB_API_KEY" "$LOCAL_ID" \
  | jq -e '.trash == "purged" and .purged == 1 and .removed == 1' >/dev/null \
  || fail_test "the message was not removed once nobody on the host held it"

echo "    OK: deleting for good is per participant, and a host removes a message nobody on it holds"
