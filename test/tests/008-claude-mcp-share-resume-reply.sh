#!/usr/bin/env bash
# Test: fmsg-mcp (Claude MCP server) end to end — share a Claude session as a
# pid-chained fmsg thread cross-instance, resume it on the receiving side,
# reply into it, then share again and verify only the NEW exchange is sent
# (incremental re-share continuing the same thread).
#
# The MCP server is driven over real stdio JSON-RPC, with a fabricated Claude
# Code session transcript on disk — no mocks anywhere in the stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

command -v jq >/dev/null || fail_test "jq is required for this test"
[ -n "${FMSG_MCP_BIN:-}" ] && [ -x "$FMSG_MCP_BIN" ] || fail_test "FMSG_MCP_BIN not set or not executable (built by run-tests.sh)"

TEST_TOKEN="$(date +%s)-$$"
WORK_DIR=$(mktemp -d)

MCP_PIDS=()
cleanup() {
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  for pid in "${MCP_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── MCP stdio driver ─────────────────────────────────────────

start_mcp() { # name fd api_url api_key home_dir cwd
  local name="$1" fd="$2" api_url="$3" api_key="$4" home_dir="$5" cwd="$6"
  local fifo="$WORK_DIR/$name.in"
  mkfifo "$fifo"
  (
    cd "$cwd" &&
      FMSG_API_URL="$api_url" FMSG_API_KEY="$api_key" HOME="$home_dir" \
        "$FMSG_MCP_BIN" <"$fifo" >"$WORK_DIR/$name.out" 2>"$WORK_DIR/$name.err"
  ) &
  MCP_PIDS+=($!)
  eval "exec $fd>\"\$fifo\""
  mcp_send "$fd" '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"0.0.0"}}}'
  mcp_await "$name" 0 15 >/dev/null
  mcp_send "$fd" '{"jsonrpc":"2.0","method":"notifications/initialized"}'
}

mcp_send() { # fd json-line
  printf '%s\n' "$2" >&"$1"
}

mcp_await() { # name id timeout-seconds → response line
  local out="$WORK_DIR/$1.out" id="$2" timeout="${3:-120}" i line
  for i in $(seq 1 $((timeout * 2))); do
    line=$(jq -c "select(.id == $id)" "$out" 2>/dev/null | head -1 || true)
    if [ -n "$line" ]; then
      echo "$line"
      return 0
    fi
    sleep 0.5
  done
  echo "    MCP $1 stderr:" >&2
  cat "$WORK_DIR/$1.err" >&2 || true
  fail_test "timed out waiting for MCP response id=$id from $1"
}

mcp_tool() { # name fd id tool args-json → tool result text
  local name="$1" fd="$2" id="$3" tool="$4" args="$5" req resp
  req=$(jq -cn --argjson id "$id" --arg tool "$tool" --argjson a "$args" \
    '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:$tool,arguments:$a}}')
  mcp_send "$fd" "$req"
  resp=$(mcp_await "$name" "$id" 180)
  if [ "$(echo "$resp" | jq -r '.result.isError // false')" = "true" ]; then
    echo "$resp" | jq -r '.result.content[0].text' >&2
    fail_test "MCP tool $tool on $name returned an error"
  fi
  echo "$resp" | jq -r '.result.content[0].text'
}

# ── Fabricate bob's Claude Code session transcript ───────────

BOB_HOME="$WORK_DIR/bob-home"
ALICE_HOME="$WORK_DIR/alice-home"
PROJECT_DIR="$WORK_DIR/proj"
mkdir -p "$BOB_HOME" "$ALICE_HOME" "$PROJECT_DIR"

SLUG=$(printf '%s' "$PROJECT_DIR" | tr -c '[:alnum:]' '-')
SESSION_ID="e2e-$TEST_TOKEN"
TRANSCRIPT="$BOB_HOME/.claude/projects/$SLUG/$SESSION_ID.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"

append_exchange() { # prompt answer
  jq -cn --arg sid "$SESSION_ID" --arg cwd "$PROJECT_DIR" --arg t "$1" \
    '{type:"user",sessionId:$sid,cwd:$cwd,message:{role:"user",content:[{type:"text",text:$t}]}}' >>"$TRANSCRIPT"
  jq -cn --arg sid "$SESSION_ID" --arg t "$2" \
    '{type:"assistant",sessionId:$sid,message:{role:"assistant",model:"claude-e2e",content:[{type:"text",text:$t}]}}' >>"$TRANSCRIPT"
}

jq -cn --arg s "E2E shared session $TEST_TOKEN" '{type:"summary",summary:$s}' >>"$TRANSCRIPT"
append_exchange "PROMPT-ONE-$TEST_TOKEN please look into the flaky test" "ANSWER-ONE-$TEST_TOKEN found the race in setup"
append_exchange "PROMPT-TWO-$TEST_TOKEN can you fix it" "ANSWER-TWO-$TEST_TOKEN fixed and tests pass"

# ── 1. Bob shares the session to alice (cross-instance) ──────

echo "    Starting bob's MCP server ($BOB_ADDR)"
start_mcp bob 3 "$EXAMPLE_API_URL" "$BOB_API_KEY" "$BOB_HOME" "$PROJECT_DIR"

ALICE_BASE_ID=$(get_max_message_id "$HAIRPIN_API_URL" "$ALICE_API_KEY")

echo "    share_session preview"
PREVIEW=$(mcp_tool bob 3 10 share_session "$(jq -cn --arg a "$ALICE_ADDR" '{recipients:[$a]}')")
[ "$(echo "$PREVIEW" | jq -r .status)" = "needs_confirmation" ] || fail_test "expected needs_confirmation, got: $PREVIEW"
[ "$(echo "$PREVIEW" | jq -r .mode)" = "new_thread" ] || fail_test "expected mode new_thread, got: $(echo "$PREVIEW" | jq -r .mode)"
[ "$(echo "$PREVIEW" | jq -r .messages)" = "2" ] || fail_test "expected 2 messages in preview, got: $(echo "$PREVIEW" | jq -r .messages)"
TOKEN=$(echo "$PREVIEW" | jq -r .confirm_token)

echo "    share_session confirm (waits for cross-instance delivery)"
SENT=$(mcp_tool bob 3 11 share_session "$(jq -cn --arg t "$TOKEN" '{confirm_token:$t}')")
[ "$(echo "$SENT" | jq -r .status)" = "sent" ] || fail_test "share not sent: $SENT"
[ "$(echo "$SENT" | jq -r '.fmsg_ids | length')" = "2" ] || fail_test "expected 2 sent messages: $SENT"
[ "$(echo "$SENT" | jq -r '.delivery_pending // [] | length')" = "0" ] || fail_test "delivery still pending: $SENT"

# ── 2. Alice resumes the thread ──────────────────────────────

ALICE_HEAD=$(wait_for_new_message_id "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$ALICE_BASE_ID")
# The chain head is the highest of the newly arrived ids.
ALICE_HEAD=$(get_max_message_id "$HAIRPIN_API_URL" "$ALICE_API_KEY")
echo "    Alice's chain head: $ALICE_HEAD"

echo "    Starting alice's MCP server ($ALICE_ADDR)"
start_mcp alice 4 "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$ALICE_HOME" "$WORK_DIR"

echo "    continue_thread from alice's side"
RESUME=$(mcp_tool alice 4 20 continue_thread "$(jq -cn --argjson id "$ALICE_HEAD" '{fmsg_id:$id}')")
echo "$RESUME" | grep -q "fmsg thread context" || fail_test "assembled context missing header"
echo "$RESUME" | grep -q "from $BOB_ADDR" || fail_test "assembled context missing sender attribution"
echo "$RESUME" | grep -q "PROMPT-ONE-$TEST_TOKEN" || fail_test "assembled context missing first prompt"
echo "$RESUME" | grep -q "PROMPT-TWO-$TEST_TOKEN" || fail_test "assembled context missing second prompt"
POS1=$(echo "$RESUME" | grep -n "PROMPT-ONE-$TEST_TOKEN" | head -1 | cut -d: -f1)
POS2=$(echo "$RESUME" | grep -n "PROMPT-TWO-$TEST_TOKEN" | head -1 | cut -d: -f1)
[ "$POS1" -lt "$POS2" ] || fail_test "prompts out of order in assembled context"

# ── 3. Alice replies into the thread ─────────────────────────

REPLY_BODY="REPLY-FROM-ALICE-$TEST_TOKEN"
echo "    reply_to_thread from alice"
REPLY_RESULT=$(mcp_tool alice 4 21 reply_to_thread "$(jq -cn --argjson id "$ALICE_HEAD" --arg b "$REPLY_BODY" '{fmsg_id:$id,body:$b}')")
echo "    Waiting for bob to receive the reply..."
BOB_REPLY_ID=$(wait_for_message_id_by_data "$EXAMPLE_API_URL" "$BOB_API_KEY" "$REPLY_BODY")
BOB_REPLY_MSG=$(fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" get "$BOB_REPLY_ID")
echo "$BOB_REPLY_MSG" | grep -q "^From: $ALICE_ADDR$" || fail_test "reply not from $ALICE_ADDR"
echo "$BOB_REPLY_MSG" | grep -q '^PID:' || fail_test "reply lost its pid link"

# ── 4. Bob extends the session and re-shares: incremental ────

append_exchange "PROMPT-THREE-$TEST_TOKEN one more tweak" "ANSWER-THREE-$TEST_TOKEN done"
ALICE_BEFORE_INC=$(get_max_message_id "$HAIRPIN_API_URL" "$ALICE_API_KEY")

echo "    share_session again — expect incremental continuation"
PREVIEW2=$(mcp_tool bob 3 12 share_session "$(jq -cn --arg a "$ALICE_ADDR" '{recipients:[$a]}')")
[ "$(echo "$PREVIEW2" | jq -r .mode)" = "continue_shared_thread" ] || fail_test "expected continue_shared_thread, got: $PREVIEW2"
[ "$(echo "$PREVIEW2" | jq -r .messages)" = "1" ] || fail_test "expected only 1 new message, got: $(echo "$PREVIEW2" | jq -r .messages)"
[ "$(echo "$PREVIEW2" | jq -r .already_shared)" = "2" ] || fail_test "expected already_shared 2: $PREVIEW2"
TOKEN2=$(echo "$PREVIEW2" | jq -r .confirm_token)

SENT2=$(mcp_tool bob 3 13 share_session "$(jq -cn --arg t "$TOKEN2" '{confirm_token:$t}')")
[ "$(echo "$SENT2" | jq -r .status)" = "sent" ] || fail_test "incremental share not sent: $SENT2"
[ "$(echo "$SENT2" | jq -r '.fmsg_ids | length')" = "1" ] || fail_test "incremental share sent more than the delta: $SENT2"

ALICE_INC_ID=$(wait_for_new_message_id "$HAIRPIN_API_URL" "$ALICE_API_KEY" "$ALICE_BEFORE_INC")
ALICE_INC_MSG=$(fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" get "$ALICE_INC_ID")
echo "$ALICE_INC_MSG" | grep -q '^PID:' || fail_test "incremental message not chained (no pid)"

echo "    PASS: share -> resume -> reply -> incremental re-share, cross-instance"
