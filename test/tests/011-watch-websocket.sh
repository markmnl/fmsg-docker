#!/usr/bin/env bash
# Test: `fmsg watch` streams a cross-instance new_msg over the WebSocket.
#
# Alice (hairpin) runs `fmsg --json watch --events new_msg --once` in the
# background; Bob (example) sends her a message. Asserts: the first line
# printed is {"type":"ready"} (emitted after the upgrade so callers know when
# to do a `list` catch-up), the next is a new_msg envelope whose data carries
# Bob's message in the list-item shape (id, from, topic), and --once exits 0.
# Then asserts a watch on a quiet inbox with --timeout exits 2 (no event).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-lib.sh
source "$SCRIPT_DIR/../test-lib.sh"

TEST_TOKEN="$(date +%s)-$$"
TOPIC="watch-$TEST_TOKEN"
BODY="watch websocket test $TEST_TOKEN"
WATCH_OUT="$(mktemp)"
trap 'rm -f "$WATCH_OUT"' EXIT

echo "    Starting watch as $ALICE_ADDR (background, --once, 60s timeout)"
fmsg_as "$HAIRPIN_API_URL" "$ALICE_API_KEY" --json watch --events new_msg --once --timeout 60s > "$WATCH_OUT" 2>&1 &
WATCH_PID=$!

# Wait for the socket to be open before sending, so the event can't be missed.
for _ in $(seq 1 100); do
  grep -q '"type":"ready"' "$WATCH_OUT" 2>/dev/null && break
  sleep 0.2
done
grep -q '"type":"ready"' "$WATCH_OUT" || { cat "$WATCH_OUT"; fail_test "watch never printed the ready line"; }

echo "    Sending: $BOB_ADDR -> $ALICE_ADDR"
SEND_OUTPUT=$(fmsg_as "$EXAMPLE_API_URL" "$BOB_API_KEY" send --topic "$TOPIC" "$ALICE_ADDR" "$BODY")
echo "$SEND_OUTPUT"

set +e
wait "$WATCH_PID"
WATCH_EXIT=$?
set -e
echo "    watch output:"
cat "$WATCH_OUT"

[ "$WATCH_EXIT" -eq 0 ] || fail_test "watch --once exited $WATCH_EXIT, expected 0"
[ "$(head -n1 "$WATCH_OUT")" = '{"type":"ready"}' ] || fail_test "first line was not the ready marker"

EVENT_LINE=$(sed -n 2p "$WATCH_OUT")
echo "$EVENT_LINE" | grep -q '"type":"new_msg"' || fail_test "second line is not a new_msg event"
echo "$EVENT_LINE" | grep -q "\"from\":\"$BOB_ADDR\"" || fail_test "event was not from $BOB_ADDR"
echo "$EVENT_LINE" | grep -q "\"topic\":\"$TOPIC\"" || fail_test "event did not carry topic $TOPIC"
echo "$EVENT_LINE" | grep -Eq '"id":[0-9]+' || fail_test "event data has no id"
[ "$(wc -l < "$WATCH_OUT")" -eq 2 ] || fail_test "expected exactly 2 lines (ready + event) with --once"

echo "    Quiet inbox: watch --timeout 3s should exit 2"
set +e
fmsg_as "$EXAMPLE_API_URL" "$CAROL_API_KEY" --json watch --events new_msg --timeout 3s > "$WATCH_OUT" 2>&1
QUIET_EXIT=$?
set -e
[ "$QUIET_EXIT" -eq 2 ] || { cat "$WATCH_OUT"; fail_test "quiet watch exited $QUIET_EXIT, expected 2"; }
[ "$(head -n1 "$WATCH_OUT")" = '{"type":"ready"}' ] || fail_test "quiet watch did not print ready"

echo "    OK: watch streamed a cross-instance new_msg and timed out cleanly on a quiet inbox"
