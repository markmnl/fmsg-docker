#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE=update

usage() {
  cat <<'EOF'
Usage: scripts/update-dd.sh [--check]

Updates local PostgreSQL DD scripts from the fmsgd, fmsgid and fmsg-webapi
repositories. A sibling checkout of each repo (../<repo>/dd.sql next to this
repo) is the preferred source when present, so local changes sync without a
push; otherwise dd.sql is fetched from GitHub at the configured ref.

Run this whenever a source repo's dd.sql changes.

Environment variables:
  FMSGD_PATH       path to a local fmsgd dd.sql       (default: ../fmsgd/dd.sql when present)
  FMSGID_PATH      path to a local fmsgid dd.sql      (default: ../fmsgid/dd.sql when present)
  FMSG_WEBAPI_PATH path to a local fmsg-webapi dd.sql (default: ../fmsg-webapi/dd.sql when present)
  FMSGD_REF        fmsgd branch to fetch from         (default: main; used when no local path)
  FMSGID_REF       fmsgid branch to fetch from        (default: main; used when no local path)
  FMSG_WEBAPI_REF  fmsg-webapi branch to fetch from   (default: main; used when no local path)

Set a <REPO>_PATH to empty (e.g. FMSGD_PATH=) to force fetching that repo
from GitHub even when a sibling checkout exists.

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

FMSGD_REF="${FMSGD_REF:-main}"
FMSGID_REF="${FMSGID_REF:-main}"
FMSG_WEBAPI_REF="${FMSG_WEBAPI_REF:-main}"

# Prefer a sibling checkout's dd.sql when one exists; ${VAR-...} (no colon)
# lets an explicitly empty <REPO>_PATH force the GitHub fetch instead.
default_path() {
  local p="$REPO_ROOT/../$1/dd.sql"
  if [ -f "$p" ]; then echo "$p"; else echo ""; fi
}
FMSGD_PATH="${FMSGD_PATH-$(default_path fmsgd)}"
FMSGID_PATH="${FMSGID_PATH-$(default_path fmsgid)}"
FMSG_WEBAPI_PATH="${FMSG_WEBAPI_PATH-$(default_path fmsg-webapi)}"

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
  local src_path="$5"
  local tmp_file="$TMP_DIR/${repo}-dd.sql"

  if [ -n "$src_path" ]; then
    echo "==> Reading ${repo} DD from ${src_path}"
    {
      printf '\\connect %s\n\n' "$database"
      cat "$src_path"
    } > "$tmp_file"
  else
    if ! command -v curl >/dev/null 2>&1; then
      echo "curl is required to fetch ${repo} (no local path)" >&2
      return 1
    fi
    local url="https://raw.githubusercontent.com/markmnl/${repo}/refs/heads/${ref}/dd.sql"
    echo "==> Fetching ${repo} DD from ${ref}"
    {
      printf '\\connect %s\n\n' "$database"
      curl -fsSL "$url"
    } > "$tmp_file"
  fi

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

write_dd "fmsgd" "$FMSGD_REF" "fmsgd" "$REPO_ROOT/docker/postgres/init/002-fmsgd-dd.sql" "$FMSGD_PATH" || STATUS=1
write_dd "fmsgid" "$FMSGID_REF" "fmsgid" "$REPO_ROOT/docker/postgres/init/002-fmsgid-dd.sql" "$FMSGID_PATH" || STATUS=1
write_dd "fmsg-webapi" "$FMSG_WEBAPI_REF" "fmsgd" "$REPO_ROOT/docker/postgres/init/003-fmsg-webapi-dd.sql" "$FMSG_WEBAPI_PATH" || STATUS=1

if [ "$MODE" = "check" ] && [ "$STATUS" -ne 0 ]; then
  echo "DD scripts are out of date. Run scripts/update-dd.sh with matching refs." >&2
fi

exit "$STATUS"
