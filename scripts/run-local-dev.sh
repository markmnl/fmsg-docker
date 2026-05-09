#!/usr/bin/env bash
# =============================================================
# Run the fmsg compose stack for local development.
#
# DNS / hosts setup:
#   Pick a base domain such as hairpin.local. FMSG_DOMAIN must be
#   the base domain, not fmsg.hairpin.local.
#
#   Add the base name and service names to your OS hosts file so
#   tools on the host resolve them to localhost:
#
#     127.0.0.1 hairpin.local fmsg.hairpin.local fmsgapi.hairpin.local
#
#   Windows hosts file:
#     C:\Windows\System32\drivers\etc\hosts
#
#   Linux/macOS hosts file:
#     /etc/hosts
#
# TLS notes:
#   fmsgd requires TCP+TLS, so this script generates a self-signed
#   certificate for fmsg.<domain> and mounts it into the fmsgd container.
#   Local outbound certificate verification is skipped with
#   FMSG_TLS_INSECURE_SKIP_VERIFY=true.
#
#   fmsg-webapi supports plain HTTP for development when FMSG_TLS_CERT
#   and FMSG_TLS_KEY are omitted, so this script disables webapi TLS and
#   exposes it on http://localhost:${FMSG_WEBAPI_HOST_PORT:-8181}.
#
# JWT notes:
#   fmsg-webapi validates JWTs using a separate local IdP. The issuer is
#   the host-facing URL (default http://localhost:8080). The JWKS URL must
#   be reachable from inside the fmsg-webapi container, so the default uses
#   host.docker.internal rather than localhost.
# =============================================================
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-local-dev.sh [domain] [addresses.csv]

Examples:
  ./scripts/run-local-dev.sh hairpin.local
  ./scripts/run-local-dev.sh hairpin.local ./addresses.csv

Environment overrides:
  COMPOSE_PROJECT_NAME       default: fmsg_<domain_with_underscores>
  FMSG_PORT                  default: 4930
  FMSG_WEBAPI_HOST_PORT      default: 8181
  POSTGRES_HOST_PORT         default: 54321
  FMSG_JWT_JWKS_URL          default: http://host.docker.internal:8080/.well-known/jwks.json
  IDP_JWT_ISSUER             default: http://localhost:8080
  FMSG_JWT_ISSUER            default: value of IDP_JWT_ISSUER
  FMSG_CORS_ORIGINS          default: http://localhost:8081
  FMSG_ADDRESSES_CSV         optional path/template copied to fmsgid addresses.csv
  FMSGD_WRITER_PGPASSWORD    default: test
  FMSGD_READER_PGPASSWORD    default: test
  FMSGID_WRITER_PGPASSWORD   default: test
  FMSGID_READER_PGPASSWORD   default: test
  PGPASSWORD                 default: test
EOF
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

print_client_env() {
  cat <<EOF

Local fmsg stack is running.

Client environment for fmsg-cli:
  export FMSG_API_URL=http://localhost:$FMSG_WEBAPI_HOST_PORT

JWTs must be issued by the local IdP:
  issuer: $FMSG_JWT_ISSUER

Example:
  fmsg login @alice@$FMSG_DOMAIN
  fmsg list
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
compose_dir="$repo_root/compose"
initial_dir="$PWD"
local_dev_dir="$repo_root/.bin/local-dev"
tls_dir="$local_dev_dir/tls"
local_override="$local_dev_dir/docker-compose.local-dev.yml"

if [[ $# -gt 2 ]]; then
  usage
  exit 1
fi

domain="${1:-}"
addresses_csv="${2:-${FMSG_ADDRESSES_CSV:-}}"

if [[ "$domain" == "-h" || "$domain" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$domain" ]]; then
  read -r -p "Local fmsg domain [hairpin.local]: " domain
  domain="${domain:-hairpin.local}"
fi

if [[ "$domain" == fmsg.* || "$domain" == fmsgapi.* ]]; then
  echo "Use the base domain only, for example: hairpin.local" >&2
  echo "Do not use fmsg.$domain or fmsgapi.$domain as FMSG_DOMAIN." >&2
  exit 1
fi

if [[ -n "$addresses_csv" && "$addresses_csv" != /* && ! "$addresses_csv" =~ ^[A-Za-z]: ]]; then
  addresses_csv="$initial_dir/$addresses_csv"
fi

sanitized_domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"

export FMSG_DOMAIN="$domain"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fmsg_${sanitized_domain}}"
export CERTBOT_EMAIL="${CERTBOT_EMAIL:-local-dev@${domain}}"
export IDP_JWT_ISSUER="${IDP_JWT_ISSUER:-http://localhost:8080}"
export FMSG_JWT_ISSUER="${FMSG_JWT_ISSUER:-$IDP_JWT_ISSUER}"
export FMSG_JWT_JWKS_URL="${FMSG_JWT_JWKS_URL:-http://host.docker.internal:8080/.well-known/jwks.json}"
export FMSG_CORS_ORIGINS="${FMSG_CORS_ORIGINS:-http://localhost:8081}"
export FMSG_API_JWT_SECRET="${FMSG_API_JWT_SECRET:-}"
export FMSG_PORT="${FMSG_PORT:-4930}"
export FMSG_WEBAPI_HOST_PORT="${FMSG_WEBAPI_HOST_PORT:-8181}"
export POSTGRES_HOST_PORT="${POSTGRES_HOST_PORT:-54321}"
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

require_command docker
docker compose version >/dev/null

cd "$compose_dir"

compose_files=(-f docker-compose.yml)
if [[ -f "$local_override" ]]; then
  compose_files+=(-f "$local_override")

  if grep -Fq -- "FMSG_JWT_JWKS_URL: \"${FMSG_JWT_JWKS_URL}\"" "$local_override" && \
    grep -Fq -- "FMSG_JWT_ISSUER: \"${FMSG_JWT_ISSUER}\"" "$local_override" && \
    grep -Fq -- "FMSG_CORS_ORIGINS: \"${FMSG_CORS_ORIGINS}\"" "$local_override" && \
    grep -Fq -- "- \"${POSTGRES_HOST_PORT}:5432\"" "$local_override" && \
    grep -Fq -- "- \"${FMSG_WEBAPI_HOST_PORT}:${FMSG_API_PORT}\"" "$local_override"; then
    existing_container_ids="$(docker compose "${compose_files[@]}" ps -a -q 2>/dev/null || true)"
    running_container_ids="$(docker compose "${compose_files[@]}" ps -q 2>/dev/null || true)"

    if [[ -n "$existing_container_ids" && -z "$running_container_ids" ]]; then
      echo "==> Starting existing local fmsg stack"
      echo "    domain:          $FMSG_DOMAIN"
      echo "    compose project: $COMPOSE_PROJECT_NAME"
      echo "    fmsgd:           fmsg.$FMSG_DOMAIN:$FMSG_PORT"
      echo "    fmsg-webapi:     http://localhost:$FMSG_WEBAPI_HOST_PORT"
      echo "    postgres:        localhost:$POSTGRES_HOST_PORT"

      docker compose "${compose_files[@]}" start
      print_client_env
      exit 0
    fi
  fi
fi

require_command openssl

if ! docker network inspect fmsg-local >/dev/null 2>&1; then
  echo "==> Creating shared Docker network: fmsg-local"
  docker network create fmsg-local >/dev/null
fi

mkdir -p "$tls_dir"

cert_file="$tls_dir/fmsg.${FMSG_DOMAIN}.crt"
key_file="$tls_dir/fmsg.${FMSG_DOMAIN}.key"

if [[ ! -s "$cert_file" || ! -s "$key_file" ]]; then
  echo "==> Generating self-signed TLS certificate for fmsg.${FMSG_DOMAIN}"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$key_file" \
    -out "$cert_file" \
    -days 30 -nodes \
    -subj "//CN=fmsg.${FMSG_DOMAIN}" \
    -addext "subjectAltName=DNS:fmsg.${FMSG_DOMAIN},DNS:${FMSG_DOMAIN},DNS:localhost,IP:127.0.0.1"
else
  echo "==> Using existing local TLS certificate: $cert_file"
fi

chmod 0644 "$cert_file" "$key_file" 2>/dev/null || true

cat > "$local_override" <<YAML
services:

  certbot:
    entrypoint: ["true"]
    restart: "no"
    ports: !override []
    profiles: ["certbot"]

  postgres:
    ports:
      - "${POSTGRES_HOST_PORT}:5432"

  fmsgd:
    environment:
      FMSG_TLS_CERT: /opt/fmsg/tls/fmsg.${FMSG_DOMAIN}.crt
      FMSG_TLS_KEY: /opt/fmsg/tls/fmsg.${FMSG_DOMAIN}.key
      FMSG_TLS_INSECURE_SKIP_VERIFY: "${FMSG_TLS_INSECURE_SKIP_VERIFY}"
    volumes:
      - "${tls_dir}:/opt/fmsg/tls:ro"
    depends_on: !override
      postgres:
        condition: service_healthy
      fmsgid:
        condition: service_started
    networks:
      default:
      fmsg-local:
        aliases:
          - ${FMSG_DOMAIN}
          - fmsg.${FMSG_DOMAIN}

  fmsg-webapi:
    environment:
      FMSG_API_JWT_SECRET: ""
      FMSG_JWT_JWKS_URL: "${FMSG_JWT_JWKS_URL}"
      FMSG_JWT_ISSUER: "${FMSG_JWT_ISSUER}"
      FMSG_CORS_ORIGINS: "${FMSG_CORS_ORIGINS}"
      FMSG_TLS_CERT: ""
      FMSG_TLS_KEY: ""
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on: !override
      fmsgd:
        condition: service_started
      fmsgid:
        condition: service_started
    ports: !override
      - "${FMSG_WEBAPI_HOST_PORT}:${FMSG_API_PORT}"
    networks:
      default:
      fmsg-local:
        aliases:
          - fmsgapi.${FMSG_DOMAIN}

networks:
  fmsg-local:
    external: true
    name: fmsg-local
YAML

if [[ -z "$addresses_csv" ]]; then
  if [[ -f "$repo_root/addresses.csv" ]]; then
    addresses_csv="$repo_root/addresses.csv"
  elif [[ -f "$compose_dir/addresses.csv" ]]; then
    addresses_csv="$compose_dir/addresses.csv"
  fi
fi

echo "==> Starting local fmsg stack"
echo "    domain:          $FMSG_DOMAIN"
echo "    compose project: $COMPOSE_PROJECT_NAME"
echo "    fmsgd:           fmsg.$FMSG_DOMAIN:$FMSG_PORT"
echo "    fmsg-webapi:     http://localhost:$FMSG_WEBAPI_HOST_PORT"
echo "    postgres:        localhost:$POSTGRES_HOST_PORT"

docker compose -f docker-compose.yml -f "$local_override" up -d --build --wait

if [[ -n "$addresses_csv" ]]; then
  if [[ ! -f "$addresses_csv" ]]; then
    echo "addresses.csv not found: $addresses_csv" >&2
    exit 1
  fi

  rendered_addresses_csv="$local_dev_dir/addresses.csv"
  sed_domain="$(printf '%s' "$FMSG_DOMAIN" | sed 's/[&|\\]/\\&/g')"
  sed "s|__FMSG_DOMAIN__|$sed_domain|g" "$addresses_csv" > "$rendered_addresses_csv"

  echo "==> Copying addresses CSV to fmsgid: $addresses_csv"
  docker compose -f docker-compose.yml -f "$local_override" cp \
    "$rendered_addresses_csv" fmsgid:/opt/fmsgid/data/addresses.csv
else
  echo "==> No addresses.csv copied. Set FMSG_ADDRESSES_CSV or pass a second argument to seed users."
fi

print_client_env
