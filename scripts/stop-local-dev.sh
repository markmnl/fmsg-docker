#!/usr/bin/env bash
# =============================================================
# Stop the local development fmsg compose stack without deleting
# containers, volumes, generated certs, or rendered CSV files.
# =============================================================
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/stop-local-dev.sh [domain]

Examples:
  ./scripts/stop-local-dev.sh hairpin.local

Environment overrides:
  COMPOSE_PROJECT_NAME       default: fmsg_<domain_with_underscores>
EOF
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
compose_dir="$repo_root/compose"
local_override="$repo_root/.bin/local-dev/docker-compose.local-dev.yml"

# shellcheck source=lib-container-engine.sh
source "$script_dir/lib-container-engine.sh"

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

domain="${1:-}"

if [[ "$domain" == "-h" || "$domain" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$domain" ]]; then
  domain="hairpin.local"
fi

if [[ "$domain" == fmsg.* || "$domain" == fmsgapi.* ]]; then
  echo "Use the base domain only, for example: hairpin.local" >&2
  exit 1
fi

sanitized_domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"

export FMSG_DOMAIN="$domain"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fmsg_${sanitized_domain}}"
export CERTBOT_EMAIL="${CERTBOT_EMAIL:-local-dev@${domain}}"
export FMSG_API_JWT_SECRET="${FMSG_API_JWT_SECRET:-local-dev-secret}"
export FMSG_PORT="${FMSG_PORT:-4930}"
export FMSG_WEBAPI_HOST_PORT="${FMSG_WEBAPI_HOST_PORT:-8181}"
export FMSG_API_PORT="${FMSG_API_PORT:-8000}"
export FMSGID_PORT="${FMSGID_PORT:-8080}"
export GIN_MODE="${GIN_MODE:-debug}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-test}"
export FMSGD_WRITER_PGPASSWORD="${FMSGD_WRITER_PGPASSWORD:-test}"
export FMSGD_READER_PGPASSWORD="${FMSGD_READER_PGPASSWORD:-test}"
export FMSGID_WRITER_PGPASSWORD="${FMSGID_WRITER_PGPASSWORD:-test}"
export FMSGID_READER_PGPASSWORD="${FMSGID_READER_PGPASSWORD:-test}"
export FMSG_SKIP_DOMAIN_IP_CHECK="${FMSG_SKIP_DOMAIN_IP_CHECK:-true}"
export FMSG_SKIP_AUTHORISED_IPS="${FMSG_SKIP_AUTHORISED_IPS:-true}"
export FMSG_TLS_INSECURE_SKIP_VERIFY="${FMSG_TLS_INSECURE_SKIP_VERIFY:-true}"

compose_files=(-f docker-compose.yml)
if [[ -f "$local_override" ]]; then
  compose_files+=(-f "$local_override")
fi

select_container_engine

cd "$compose_dir"

echo "==> Stopping local fmsg stack"
echo "    domain:          $FMSG_DOMAIN"
echo "    compose project: $COMPOSE_PROJECT_NAME"

docker compose "${compose_files[@]}" stop

echo "==> Local fmsg stack stopped. Volumes and generated local files were preserved."
