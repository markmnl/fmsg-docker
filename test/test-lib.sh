#!/usr/bin/env bash

fail_test() {
  echo "    FAIL: $1"
  exit 1
}

extract_send_id() {
  echo "$1" | sed -n 's/^ID: \([0-9][0-9]*\)$/\1/p' | head -1
}

extract_wait_latest_id() {
  echo "$1" | sed -n 's/^New message available\. Latest ID: \([0-9][0-9]*\)$/\1/p' | head -1
}

get_max_message_id() {
  local list_output
  local ids

  list_output=$(fmsg list 2>/dev/null || true)
  ids=$(echo "$list_output" | sed -n 's/^ID: \([0-9][0-9]*\).*/\1/p')

  if [ -z "$ids" ]; then
    echo 0
    return
  fi

  echo "$ids" | sort -nr | head -1
}

wait_for_new_message_id() {
  local since_id="$1"
  local timeout="${2:-15}"
  local wait_output
  local latest_id

  wait_output=$(fmsg wait --since-id "$since_id" --timeout "$timeout")
  echo "    $wait_output" >&2

  latest_id=$(extract_wait_latest_id "$wait_output")
  if [ -z "$latest_id" ]; then
    fail_test "timed out waiting for a new message after ID $since_id"
  fi

  echo "$latest_id"
}

wait_for_message_id_by_data() {
  local expected_data="$1"
  local timeout="${2:-15}"
  local tmp_file
  local attempt
  local ids
  local id

  tmp_file=$(mktemp)

  for attempt in $(seq 1 "$timeout"); do
    ids=$(fmsg list --limit 20 2>/dev/null | sed -n 's/^ID: \([0-9][0-9]*\).*/\1/p')

    for id in $ids; do
      if fmsg get-data "$id" "$tmp_file" >/dev/null 2>&1 && grep -Fxq "$expected_data" "$tmp_file"; then
        rm -f "$tmp_file"
        echo "$id"
        return
      fi
    done

    sleep 1
  done

  rm -f "$tmp_file"
  fail_test "timed out waiting for expected message data"
}

get_auth_token() {
  local auth_file
  local token

  # Prefer explicit XDG path, then Windows APPDATA, then default ~/.config.
  if [ -n "${XDG_CONFIG_HOME:-}" ] && [ -f "$XDG_CONFIG_HOME/fmsg/auth.json" ]; then
    auth_file="$XDG_CONFIG_HOME/fmsg/auth.json"
  elif [ -n "${APPDATA:-}" ] && [ -f "$APPDATA/fmsg/auth.json" ]; then
    auth_file="$APPDATA/fmsg/auth.json"
  else
    auth_file="$HOME/.config/fmsg/auth.json"
  fi

  token=$(sed -n 's/^[[:space:]]*"token":[[:space:]]*"\([^"]*\)".*/\1/p' "$auth_file" | head -1)

  if [ -z "$token" ]; then
    fail_test "could not determine auth token from $auth_file"
  fi

  echo "$token"
}