#!/usr/bin/env bash
# Create an API key for a seeded local-development fmsg address.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/create-local-dev-api-key.sh [domain] [address]

Examples:
  ./scripts/create-local-dev-api-key.sh hairpin.local
  ./scripts/create-local-dev-api-key.sh hairpin.local @alice@hairpin.local

Prints an API key for the supplied address. The local stack must be running.
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
compose_dir="$repo_root/compose"
local_override="$repo_root/.bin/local-dev/docker-compose.local-dev.yml"

# shellcheck source=lib-container-engine.sh
source "$script_dir/lib-container-engine.sh"

if [[ $# -gt 2 ]]; then
  usage
  exit 1
fi

domain="${1:-hairpin.local}"
address="${2:-@alice@$domain}"

if [[ "$domain" == "-h" || "$domain" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$domain" == fmsg.* || "$domain" == fmsgapi.* ]]; then
  echo "Use the base domain only, for example: hairpin.local" >&2
  exit 1
fi

if [[ "$address" != @*"@$domain" ]]; then
  echo "Address must use the supplied domain: $address" >&2
  exit 1
fi

sanitized_domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"

export FMSG_DOMAIN="$domain"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fmsg_${sanitized_domain}}"

if [[ ! -f "$local_override" ]]; then
  echo "Local development stack configuration not found. Run $repo_root/scripts/start-local-dev.sh first." >&2
  exit 1
fi

select_container_engine

container_id="$(compose_service_container_id fmsg-webapi)"

if [[ -z "$container_id" ]]; then
  echo "Local fmsg-webapi container is not running. Run $repo_root/scripts/start-local-dev.sh first." >&2
  exit 1
fi

if ! api_key_output="$(docker exec "$container_id" /opt/fmsg-webapi/fmsg-webapi api-key create-delegation \
  -owner "$address" \
  -agent local-dev-cli \
  -addr "$address" \
  -cidr 0.0.0.0/0,::/0 \
  -expires 2099-01-01T00:00:00Z 2>/dev/null)"; then
  api_key_output="$(docker exec "$container_id" /opt/fmsg-webapi/fmsg-webapi api-key rotate-delegation \
    -owner "$address" \
    -agent local-dev-cli \
    -expires 2099-01-01T00:00:00Z)"
fi

printf '%s\n' "$api_key_output" | awk -F= '$1 == "api_key" { print $2; exit }'