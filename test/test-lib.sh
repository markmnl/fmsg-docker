#!/usr/bin/env bash

fail_test() {
  echo "    FAIL: $1"
  exit 1
}

extract_send_id() {
  echo "$1" | sed -n 's/^ID: \([0-9][0-9]*\)$/\1/p' | head -1
}

fmsg_as() {
  local api_url="$1"
  local api_key="$2"
  shift 2

  FMSG_API_URL="$api_url" FMSG_API_KEY="$api_key" fmsg "$@"
}

get_max_message_id() {
  local api_url="$1"
  local api_key="$2"
  local list_output
  local ids

  list_output=$(fmsg_as "$api_url" "$api_key" list --limit 20 2>/dev/null || true)
  ids=$(echo "$list_output" | sed -n 's/^ID: \([0-9][0-9]*\).*/\1/p')

  if [ -z "$ids" ]; then
    echo 0
    return
  fi

  echo "$ids" | sort -nr | head -1
}

wait_for_new_message_id() {
  local api_url="$1"
  local api_key="$2"
  local since_id="$3"
  local timeout="${4:-15}"
  local attempt
  local latest_id

  for attempt in $(seq 1 "$timeout"); do
    latest_id=$(get_max_message_id "$api_url" "$api_key")
    if [ -n "$latest_id" ] && [ "$latest_id" -gt "$since_id" ]; then
      echo "$latest_id"
      return
    fi
    sleep 1
  done

  fail_test "timed out waiting for a new message after ID $since_id"
}

wait_for_message_id_by_data() {
  local api_url="$1"
  local api_key="$2"
  local expected_data="$3"
  local timeout="${4:-15}"
  local tmp_file
  local attempt
  local ids
  local ids_reversed
  local id

  tmp_file=$(mktemp)

  for attempt in $(seq 1 "$timeout"); do
    ids=$(fmsg_as "$api_url" "$api_key" list --limit 20 2>/dev/null | sed -n 's/^ID: \([0-9][0-9]*\).*/\1/p')
    ids_reversed=$(echo "$ids" | awk 'NF{a[++n]=$0} END{for(i=n;i>=1;i--) print a[i]}')

    for id in $ids_reversed; do
      if fmsg_as "$api_url" "$api_key" get-data "$id" "$tmp_file" >/dev/null 2>&1 && grep -Fxq "$expected_data" "$tmp_file"; then
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
