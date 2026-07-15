#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE=update

usage() {
  cat <<'EOF'
Usage: scripts/update-dd.sh [--check]

Updates local PostgreSQL DD scripts from the fmsgd, fmsgid and fmsg-webapi repositories.

Environment variables:
  FMSGD_REF       fmsgd branch to fetch from       (default: main)
  FMSGID_REF      fmsgid branch to fetch from      (default: main)
  FMSG_WEBAPI_REF fmsg-webapi branch to fetch from (default: main)

Options:
  --check     report drift without modifying files; exits non-zero on drift
EOF
}

for arg in "$@"; do
  case "$arg" in
    --check)
      MODE=check
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

FMSGD_REF="${FMSGD_REF:-main}"
FMSGID_REF="${FMSGID_REF:-main}"
FMSG_WEBAPI_REF="${FMSG_WEBAPI_REF:-main}"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

write_dd() {
  local repo="$1"
  local ref="$2"
  local database="$3"
  local target="$4"
  local tmp_file="$TMP_DIR/${repo}-dd.sql"
  local url="https://raw.githubusercontent.com/markmnl/${repo}/refs/heads/${ref}/dd.sql"

  echo "==> Fetching ${repo} DD from ${ref}"
  {
    printf '\\connect %s\n\n' "$database"
    curl -fsSL "$url"
  } > "$tmp_file"

  if cmp -s "$tmp_file" "$target"; then
    echo "    up to date: ${target#$REPO_ROOT/}"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    echo "    OUTDATED: ${target#$REPO_ROOT/}"
    return 1
  fi

  mv "$tmp_file" "$target"
  echo "    updated: ${target#$REPO_ROOT/}"
}

STATUS=0

write_dd "fmsgd" "$FMSGD_REF" "fmsgd" "$REPO_ROOT/docker/postgres/init/002-fmsgd-dd.sql" || STATUS=1
write_dd "fmsgid" "$FMSGID_REF" "fmsgid" "$REPO_ROOT/docker/postgres/init/002-fmsgid-dd.sql" || STATUS=1
write_dd "fmsg-webapi" "$FMSG_WEBAPI_REF" "fmsgd" "$REPO_ROOT/docker/postgres/init/003-fmsg-webapi-dd.sql" || STATUS=1

if [ "$MODE" = "check" ] && [ "$STATUS" -ne 0 ]; then
  echo "DD scripts are out of date. Run scripts/update-dd.sh with matching refs." >&2
fi

exit "$STATUS"
