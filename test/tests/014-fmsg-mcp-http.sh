#!/usr/bin/env bash
# Test: fmsg-mcp (general MCP server, https://github.com/markmnl/fmsg-mcp) in
# Streamable HTTP mode against a real stack, driven with curl over JSON-RPC.
#
# One fmsg-mcp instance is started for the hairpin host with `npx` (the
# published npm package; FMSG_MCP_NPM_SPEC picks the version). Alice
# authenticates to it with her API key as a bearer token; Bob is on the other
# host and uses fmsg-cli. Asserts: unauthenticated requests get 401, whoami
# reports Alice, send_message reaches Bob cross-host, wait_for_message returns
# Bob's reply pushed over the host WebSocket, get_thread shows both messages,
# react succeeds and delivery_status reports Bob as delivered.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

for tool in node npx jq curl; do
  command -v "$tool" >/dev/null || fail_test "$tool is required for this test"
done

FMSG_MCP_NPM_SPEC="${FMSG_MCP_NPM_SPEC:-@markmnl/fmsg-mcp@latest}"
MCP_PORT="${FMSG_MCP_TEST_PORT:-8765}"
MCP_URL="http://127.0.0.1:$MCP_PORT/mcp"
TEST_TOKEN="$(date +%s)-$$"
WORK_DIR=$(mktemp -d)
MCP_PID=""
cleanup() {
  [ -n "$MCP_PID" ] && kill "$MCP_PID" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Start fmsg-mcp for the hairpin host ──────────────────────
echo "    Starting fmsg-mcp ($FMSG_MCP_NPM_SPEC) in HTTP mode for $HAIRPIN_API_URL"
FMSG_API_URL="$HAIRPIN_API_URL" npx -y "$FMSG_MCP_NPM_SPEC" --http "127.0.0.1:$MCP_PORT" \
  >"$WORK_DIR/mcp.log" 2>&1 &
MCP_PID=$!
for _ in $(seq 1 120); do
  curl -sf "http://127.0.0.1:$MCP_PORT/healthz" >/dev/null 2>&1 && break
  kill -0 "$MCP_PID" 2>/dev/null || { cat "$WORK_DIR/mcp.log"; fail_test "fmsg-mcp exited before becoming healthy"; }
  sleep 0.5
done
curl -sf "http://127.0.0.1:$MCP_PORT/healthz" >/dev/null || { cat "$WORK_DIR/mcp.log"; fail_test "fmsg-mcp did not become healthy"; }

# ── JSON-RPC over Streamable HTTP ────────────────────────────
# Responses may be plain JSON or an SSE stream of `data:` lines; keep the JSON.
mcp_rpc() { # api_key id method params-json → result JSON (fails on JSON-RPC error)
  local api_key="$1" id="$2" method="$3" params="$4" req body
  req=$(jq -cn --argjson id "$id" --arg m "$method" --argjson p "$params" '{jsonrpc:"2.0",id:$id,method:$m,params:$p}')
  body=$(curl -s -X POST "$MCP_URL" \
    -H "content-type: application/json" -H "accept: application/json, text/event-stream" \
    -H "authorization: Bearer $api_key" --data "$req")
  case "$body" in
    event:*|data:*) body=$(echo "$body" | sed -n 's/^data: //p' | jq -c "select(.id == $id)" | tail -1) ;;
  esac
  if [ -z "$body" ]; then fail_test "empty response for $method"; fi
  if [ "$(echo "$body" | jq -r 'has("error")')" = "true" ]; then
    echo "$body" >&2
    fail_test "JSON-RPC error from $method"
  fi
  echo "$body" | jq -c '.result'
}

mcp_tool() { # api_key id tool args-json → structuredContent JSON
  local result
  result=$(mcp_rpc "$1" "$2" tools/call "$(jq -cn --arg t "$3" --argjson a "$4" '{name:$t,arguments:$a}')")
  if [ "$(echo "$result" | jq -r '.isError // false')" = "true" ]; then
    echo "$result" | jq -r '.content[0].text' >&2
    fail_test "MCP tool $3 returned an error"
  fi
  echo "$result" | jq -c '.structuredContent'
}

# ── 1. Auth gate ─────────────────────────────────────────────
echo "    Unauthenticated request must be rejected"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$MCP_URL" -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"tools/list","params":{}}')
[ "$STATUS" = "401" ] || fail_test "expected 401 without a bearer key, got $STATUS"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$MCP_URL" -H "content-type: application/json" \
  -H "authorization: Bearer fmsgk_not_a_real_key" -d '{"jsonrpc":"2.0","id":0,"method":"tools/list","params":{}}')
[ "$STATUS" = "401" ] || fail_test "expected 401 for an unknown key, got $STATUS"

echo "    initialize + whoami as $ALICE_ADDR"
mcp_rpc "$ALICE_API_KEY" 1 initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fmsg-docker","version":"0"}}' >/dev/null
WHO=$(mcp_tool "$ALICE_API_KEY" 2 whoami '{}')
[ "$(echo "$WHO" | jq -r .address)" = "$ALICE_ADDR" ] || fail_test "whoami returned $(echo "$WHO" | jq -r .address)"
[ "$(echo "$WHO" | jq -r .transport)" = "http" ] || fail_test "whoami transport was not http"

# ── 2. Alice sends to Bob cross-host ─────────────────────────
TOPIC="mcp-http-$TEST_TOKEN"
BODY="hello from fmsg-mcp $TEST_TOKEN"
echo "    send_message: $ALICE_ADDR -> $BOB_ADDR"
SENT=$(mcp_tool "$ALICE_API_KEY" 3 send_message "$(jq -cn --arg to "$BOB_ADDR" --arg t "$TOPIC" --arg b "$BODY" '{to:[$to],topic:$t,body:$b,type:"text/plain; charset=utf-8"}')")
SENT_ID=$(echo "$SENT" | jq -r .id)
[[ "$SENT_ID" =~ ^[0-9]+$ ]] || fail_test "send_message returned no id: $SENT"

echo "    Waiting for Bob to receive it..."
BOB_COPY=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$BODY" 60)
fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get "$BOB_COPY" | grep -q "^From: $ALICE_ADDR$" || fail_test "Bob's copy is not from $ALICE_ADDR"

# ── 3. Alice waits over the WebSocket; Bob replies via CLI ───
REPLY="reply to fmsg-mcp $TEST_TOKEN"
echo "    wait_for_message (background, 60s) as $ALICE_ADDR"
mcp_tool "$ALICE_API_KEY" 4 wait_for_message "$(jq -cn --argjson id "$SENT_ID" '{after_id:($id|tostring),timeout_seconds:60,settle_seconds:1}')" >"$WORK_DIR/wait.json" 2>"$WORK_DIR/wait.err" &
WAIT_PID=$!
sleep 3
echo "    Bob replies via fmsg-cli (pid $BOB_COPY)"
fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" send --pid "$BOB_COPY" "$ALICE_ADDR" "$REPLY" >/dev/null
set +e
wait "$WAIT_PID"
WAIT_EXIT=$?
set -e
[ "$WAIT_EXIT" -eq 0 ] || { cat "$WORK_DIR/wait.err"; fail_test "wait_for_message failed"; }
WAITED=$(cat "$WORK_DIR/wait.json")
[ "$(echo "$WAITED" | jq -r .status)" = "message" ] || fail_test "wait_for_message did not return a message: $WAITED"
[ "$(echo "$WAITED" | jq -r '.messages[0].from')" = "$BOB_ADDR" ] || fail_test "waited message not from $BOB_ADDR"
[ "$(echo "$WAITED" | jq -r '.messages[0].body')" = "$REPLY" ] || fail_test "waited message body mismatch"
REPLY_ID=$(echo "$WAITED" | jq -r .reply_target_id)
echo "    wait_for_message returned Bob's reply (id $REPLY_ID, transport $(echo "$WAITED" | jq -r .transport))"

# ── 4. Thread, reaction, delivery ────────────────────────────
THREAD=$(mcp_tool "$ALICE_API_KEY" 5 get_thread "$(jq -cn --arg id "$REPLY_ID" '{id:$id}')")
[ "$(echo "$THREAD" | jq -r '.messages | length')" = "2" ] || fail_test "get_thread expected 2 messages: $THREAD"
[ "$(echo "$THREAD" | jq -r '.messages[0].body')" = "$BODY" ] || fail_test "thread root body mismatch"
[ "$(echo "$THREAD" | jq -r '.messages[1].body')" = "$REPLY" ] || fail_test "thread reply body mismatch"
[ "$(echo "$THREAD" | jq -r '.participants[0]')" = "$BOB_ADDR" ] || fail_test "thread participants should be just $BOB_ADDR"

REACTED=$(mcp_tool "$ALICE_API_KEY" 6 react "$(jq -cn --arg id "$REPLY_ID" '{id:$id,emoji:"👍"}')")
[ "$(echo "$REACTED" | jq -r .cleared)" = "false" ] || fail_test "react did not set a reaction: $REACTED"

echo "    delivery_status for $SENT_ID"
for _ in $(seq 1 30); do
  DELIVERY=$(mcp_tool "$ALICE_API_KEY" 7 delivery_status "$(jq -cn --arg id "$SENT_ID" '{id:$id}')")
  [ "$(echo "$DELIVERY" | jq -r '.recipients[0].status')" = "delivered" ] && break
  sleep 1
done
[ "$(echo "$DELIVERY" | jq -r '.recipients[0].addr')" = "$BOB_ADDR" ] || fail_test "delivery recipient mismatch: $DELIVERY"
[ "$(echo "$DELIVERY" | jq -r '.recipients[0].status')" = "delivered" ] || fail_test "Bob not reported delivered: $DELIVERY"

echo "    PASS: fmsg-mcp HTTP mode — auth gate, send, WebSocket wait, thread, react, delivery"
