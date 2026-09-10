#!/usr/bin/env bash
# Local-only identities remain stable when later federated through add-to.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"
BODY="$(printf 'A compressible message for immutable local delivery. %.0s' {1..40}) [$TEST_TOKEN]"
INPUT=$(jq -n --arg from "$BOB_ADDR" --arg to "$CAROL_ADDR" --arg body "$BODY" \
  '{version:1,from:$from,to:[$to],type:"text/plain;charset=UTF-8",data:$body}')
ROOT_ID=$(api_json_write "$EXAMPLE_API_URL" "$BOB_API_KEY" POST /fmsg "$INPUT" | jq -er '.id')
api_json_get "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$ROOT_ID" | jq -e '.time == null and .sha256 == null' >/dev/null
ROOT_HASH=$(api_json_write "$EXAMPLE_API_URL" "$BOB_API_KEY" POST "/fmsg/$ROOT_ID/send" '{}' | jq -er '.sha256')
[[ "$ROOT_HASH" =~ ^[0-9a-f]{64}$ ]] || fail_test "local-only send did not return a hash"
api_json_get "$EXAMPLE_API_URL" "$CAROL_API_KEY" "/fmsg/$ROOT_HASH" | jq -e --arg hash "$ROOT_HASH" '.sha256 == $hash and .time != null' >/dev/null

echo "    Local-only delivery has an immediately usable identity"
REPLY_INPUT=$(jq -n --arg from "$CAROL_ADDR" --arg to "$BOB_ADDR" --arg pid "$ROOT_HASH" \
  '{version:1,from:$from,to:[$to],pid:$pid,type:"text/plain;charset=UTF-8",data:"local reply"}')
REPLY_ID=$(api_json_write "$EXAMPLE_API_URL" "$CAROL_API_KEY" POST /fmsg "$REPLY_INPUT" | jq -er '.id')
api_json_write "$EXAMPLE_API_URL" "$CAROL_API_KEY" POST "/fmsg/$REPLY_ID/send" '{}' | jq -e '.sha256 | test("^[0-9a-f]{64}$")' >/dev/null
api_json_get "$EXAMPLE_API_URL" "$CAROL_API_KEY" "/fmsg/$REPLY_ID" | jq -e --arg hash "$ROOT_HASH" '.psha256 == $hash' >/dev/null
api_json_write "$EXAMPLE_API_URL" "$CAROL_API_KEY" POST "/fmsg/$ROOT_HASH/react" '{"emoji":"👍"}' | jq -e '.sha256 | test("^[0-9a-f]{64}$")' >/dev/null

echo "    Adding a remote participant after local-only delivery"
ADD_INPUT=$(jq -n --arg addr "$ALICE_ADDR" '{add_to:[$addr]}')
BATCH_HASH=$(api_json_write "$EXAMPLE_API_URL" "$BOB_API_KEY" POST "/fmsg/$ROOT_HASH/add-to" "$ADD_INPUT" | jq -er '.sha256')
ALICE_ROOT=$(wait_for_message_id_by_data "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$BODY" 30)
api_json_get "$HAIRPIN_API_URL" "$ALICE_API_KEY" "/fmsg/$ROOT_HASH" | jq -e --arg root "$ROOT_HASH" --arg batch "$BATCH_HASH" \
  '.sha256 == $root and any(.add_to[]; .sha256 == $batch)' >/dev/null
api_json_get "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$ROOT_ID" | jq -e --arg hash "$ROOT_HASH" '.sha256 == $hash' >/dev/null

REPLY_TEXT="remote batch reply [$TEST_TOKEN]"
REPLY_INPUT=$(jq -n --arg from "$ALICE_ADDR" --arg to "$BOB_ADDR" --arg pid "$BATCH_HASH" --arg body "$REPLY_TEXT" \
  '{version:1,from:$from,to:[$to],pid:$pid,type:"text/plain;charset=UTF-8",data:$body}')
REPLY_ID=$(api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST /fmsg "$REPLY_INPUT" | jq -er '.id')
REPLY_HASH=$(api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST "/fmsg/$REPLY_ID/send" '{}' | jq -er '.sha256')
BOB_REPLY=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$REPLY_TEXT" 30)
api_json_get "$EXAMPLE_API_URL" "$BOB_API_KEY" "/fmsg/$BOB_REPLY" | jq -e --arg parent "$BATCH_HASH" --arg hash "$REPLY_HASH" \
  '.psha256 == $parent and .sha256 == $hash' >/dev/null

echo "    Verifying a locally hashed batch on the notification-only (11) path"
NOTIFY_BODY="$(printf 'Compression also survives a batch notification. %.0s' {1..30}) [$TEST_TOKEN]"
INPUT=$(jq -n --arg from "$ALICE_ADDR" --arg to "$BOB_ADDR" --arg body "$NOTIFY_BODY" \
  '{version:1,from:$from,to:[$to],type:"text/plain;charset=UTF-8",data:$body}')
ID=$(api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST /fmsg "$INPUT" | jq -er '.id')
HASH=$(api_json_write "$HAIRPIN_API_URL" "$ALICE_API_KEY" POST "/fmsg/$ID/send" '{}' | jq -er '.sha256')
wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$NOTIFY_BODY" 30 >/dev/null
ADD_INPUT=$(jq -n --arg addr "$CAROL_ADDR" '{add_to:[$addr]}')
NOTIFY_HASH=$(api_json_write "$EXAMPLE_API_URL" "$BOB_API_KEY" POST "/fmsg/$HASH/add-to" "$ADD_INPUT" | jq -er '.sha256')
FOUND=false
for attempt in $(seq 1 30); do
  if api_json_get "$HAIRPIN_API_URL" "$ALICE_API_KEY" "/fmsg/$HASH" | jq -e --arg hash "$NOTIFY_HASH" 'any(.add_to[]?; .sha256 == $hash)' >/dev/null; then
    FOUND=true
    break
  fi
  sleep 1
done
[ "$FOUND" = true ] || fail_test "notification-only host did not retain the batch identity"
CODE=$(docker exec example-postgres-1 psql -U postgres -d fmsgd -tAc \
  "select n.response_code from msg_add_to_notify n join msg_add_to_batch b on b.id=n.batch_id where b.sha256=decode('$NOTIFY_HASH','hex')")
[ "$CODE" = 11 ] || fail_test "expected notification code 11, got $CODE"

if [ "${FMSG_CHALLENGE_MODE:-}" = ALWAYS ]; then
  docker logs example-fmsgd-1 2>&1 | grep 'CHALLENGE RESP' >/dev/null || fail_test "no challenge response recorded"
fi
echo "    OK: hashes survive local delivery, reactions, compression, federation, batch replies and notifications"
