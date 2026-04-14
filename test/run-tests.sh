#!/usr/bin/env bash
# =============================================================
# Run the fmsg integration tests.
#
# Prerequisites: docker, docker compose, go (1.24+), curl
#
# Usage:
#   ./test/run-tests.sh            # run tests (start stacks fresh)
#   ./test/run-tests.sh --no-start # run tests against already-running stacks
#   ./test/run-tests.sh --rebuild-cli # force rebuilding fmsg CLI
#   ./test/run-tests.sh cleanup    # tear down stacks & network
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Cleanup function ─────────────────────────────────────────
cleanup() {
  echo "==> Tearing down stacks..."
  cd "$REPO_ROOT/compose"

  COMPOSE_PROJECT_NAME=hairpin FMSG_DOMAIN=hairpin.local FMSG_WEBAPI_HOST_PORT=8181 \
    docker compose -f docker-compose.yml -f ../test/docker-compose.test.yml down -v 2>/dev/null || true

  COMPOSE_PROJECT_NAME=example FMSG_DOMAIN=example.com FMSG_WEBAPI_HOST_PORT=8182 \
    docker compose -f docker-compose.yml -f ../test/docker-compose.test.yml down -v 2>/dev/null || true

  docker network rm fmsg-test 2>/dev/null || true
  rm -rf "$REPO_ROOT/test/.tls"
  echo "==> Cleanup complete."
}

SKIP_START=false
FORCE_REBUILD_CLI=false

for arg in "$@"; do
  case "$arg" in
    cleanup)
      cleanup
      exit 0
      ;;
    --no-start)
      SKIP_START=true
      ;;
    --rebuild-cli)
      FORCE_REBUILD_CLI=true
      ;;
    "")
      ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: ./test/run-tests.sh [--no-start] [--rebuild-cli]"
      echo "       ./test/run-tests.sh cleanup"
      exit 1
      ;;
  esac
done

# ── Trap to dump logs + clean up on failure ──────────────────
on_error() {
  echo ""
  echo "==> TEST FAILED — dumping logs..."
  cd "$REPO_ROOT/compose"
  echo "--- hairpin.local logs ---"
  COMPOSE_PROJECT_NAME=hairpin FMSG_DOMAIN=hairpin.local FMSG_WEBAPI_HOST_PORT=8181 \
    docker compose -f docker-compose.yml -f ../test/docker-compose.test.yml logs 2>/dev/null || true
  echo "--- example.com logs ---"
  COMPOSE_PROJECT_NAME=example FMSG_DOMAIN=example.com FMSG_WEBAPI_HOST_PORT=8182 \
    docker compose -f docker-compose.yml -f ../test/docker-compose.test.yml logs 2>/dev/null || true
}
trap on_error ERR

# ── Common env vars ──────────────────────────────────────────
export PGPASSWORD=testpgpass
export FMSGD_WRITER_PGPASSWORD=testfmsgdwriter
export FMSGD_READER_PGPASSWORD=testfmsgdreader
export FMSGID_WRITER_PGPASSWORD=testfmsgidwriter
export FMSGID_READER_PGPASSWORD=testfmsgidreader
export FMSG_SKIP_DOMAIN_IP_CHECK=true
export FMSG_SKIP_AUTHORISED_IPS=true
export FMSG_API_JWT_SECRET=test-jwt-secret
export FMSG_JWT_SECRET=test-jwt-secret
export FMSG_TLS_INSECURE_SKIP_VERIFY=true

# ── Pass through ref overrides for Docker build args ─────────
export FMSGD_REF=${FMSGD_REF:-main}
export FMSGID_REF=${FMSGID_REF:-main}
export FMSG_WEBAPI_REF=${FMSG_WEBAPI_REF:-main}
FMSG_CLI_REF=${FMSG_CLI_REF:-main}

# ── Pass through optional SSL verification override ──────────
export GIT_SSL_NO_VERIFY=${GIT_SSL_NO_VERIFY:-}

# ── Ensure Go is on PATH ──────────────────────────────────────
if ! command -v go &>/dev/null && [ -x /usr/local/go/bin/go ]; then
  export PATH="/usr/local/go/bin:$PATH"
fi

# ── Build fmsg CLI ───────────────────────────────────────────
FMSG_BIN="$REPO_ROOT/test/.bin/fmsg"
FMSG_BIN_REF_FILE="$REPO_ROOT/test/.bin/.fmsg-cli-ref"
NEED_BUILD_CLI=true

mkdir -p "$(dirname "$FMSG_BIN")"

if [ "$FORCE_REBUILD_CLI" != "true" ] && [ -x "$FMSG_BIN" ] && [ -f "$FMSG_BIN_REF_FILE" ]; then
  BUILT_CLI_REF="$(cat "$FMSG_BIN_REF_FILE")"
  if [ "$BUILT_CLI_REF" = "$FMSG_CLI_REF" ]; then
    NEED_BUILD_CLI=false
  fi
fi

if [ "$NEED_BUILD_CLI" = "true" ]; then
  echo "==> Building fmsg CLI (ref: $FMSG_CLI_REF)..."
  FMSG_CLI_DIR=$(mktemp -d)
  if [ "$GIT_SSL_NO_VERIFY" = "true" ]; then git config --global http.sslVerify false; fi
  git clone --branch "$FMSG_CLI_REF" --depth 1 https://github.com/markmnl/fmsg-cli.git "$FMSG_CLI_DIR"
  if [ "$GIT_SSL_NO_VERIFY" = "true" ]; then
    GOINSECURE='*' GONOSUMDB='*' GONOSUMCHECK='*' GOPROXY=direct \
      bash -c "cd \"$FMSG_CLI_DIR\" && go build -o \"$FMSG_BIN\" ."
  else
    (cd "$FMSG_CLI_DIR" && go build -o "$FMSG_BIN" .)
  fi
  rm -rf "$FMSG_CLI_DIR"
  echo "$FMSG_CLI_REF" > "$FMSG_BIN_REF_FILE"
else
  echo "==> Using cached fmsg CLI (ref: $FMSG_CLI_REF)"
fi

export PATH="$(dirname "$FMSG_BIN"):$PATH"
echo "==> fmsg CLI: $FMSG_BIN"

if [ "$SKIP_START" != "true" ]; then
  # ── Clean up any previous run ──────────────────────────────
  cleanup

  # ── Create shared Docker network ──────────────────────────
  echo "==> Creating fmsg-test network..."
  docker network create fmsg-test

  # ── Generate self-signed TLS certificates ─────────────────
  echo "==> Generating self-signed TLS certificates..."
  TLS_DIR="$REPO_ROOT/test/.tls"
  mkdir -p "$TLS_DIR"
  for domain in hairpin.local example.com; do
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$TLS_DIR/fmsg.${domain}.key" \
      -out "$TLS_DIR/fmsg.${domain}.crt" \
      -days 1 -nodes \
      -subj "/CN=fmsg.${domain}" \
      -addext "subjectAltName=DNS:fmsg.${domain}"
  done
  chmod 644 "$TLS_DIR"/*.key

  export CACHEBUST=$(date +%s)

  # ── Start hairpin.local ────────────────────────────────────
  echo "==> Starting hairpin.local stack..."
  cd "$REPO_ROOT/compose"
  COMPOSE_PROJECT_NAME=hairpin \
  FMSG_DOMAIN=hairpin.local \
  FMSG_PORT=4931 \
  FMSG_WEBAPI_HOST_PORT=8181 \
    docker compose -f docker-compose.yml -f ../test/docker-compose.test.yml up -d --build --force-recreate --no-deps --wait

  # ── Start example.com ──────────────────────────────────────
  echo "==> Starting example.com stack..."
  COMPOSE_PROJECT_NAME=example \
  FMSG_DOMAIN=example.com \
  FMSG_PORT=4932 \
  FMSG_WEBAPI_HOST_PORT=8182 \
    docker compose -f docker-compose.yml -f ../test/docker-compose.test.yml up -d --build --force-recreate --wait

  # ── Debug: show running containers & port mappings ────────
  echo "==> Running containers:"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

  # ── Wait for webapi endpoints ──────────────────────────────
  for port in 8181 8182; do
    echo "==> Waiting for fmsg-webapi on port $port..."
    for i in $(seq 1 30); do
      if curl -s -o /dev/null --connect-timeout 2 "http://localhost:$port/" 2>/dev/null; then
        echo "    ready"
        break
      fi
      if [ "$i" -eq 30 ]; then
        echo "    timed out waiting for port $port"
        echo "    trying verbose curl for diagnosis:"
        curl -v "http://localhost:$port/" 2>&1 || true
        exit 1
      fi
      sleep 2
    done
  done

  # ── Seed test users ────────────────────────────────────────
  echo "==> Seeding users..."
  docker exec -i hairpin-postgres-1 psql -U postgres < "$REPO_ROOT/test/seed-hairpin.sql"
  docker exec -i example-postgres-1 psql -U postgres < "$REPO_ROOT/test/seed-example.sql"
fi

# ── Export env vars for test scripts ──────────────────────────
export HAIRPIN_API_URL=http://localhost:8181
export EXAMPLE_API_URL=http://localhost:8182

# ── Run test scripts ─────────────────────────────────────────
TESTS_DIR="$SCRIPT_DIR/tests"
PASSED=0
FAILED=0
FAILED_TESTS=()

for test_script in "$TESTS_DIR"/*.sh; do
  [ -f "$test_script" ] || continue
  test_name="$(basename "$test_script")"
  echo ""
  echo "==> Running test: $test_name"
  if bash "$test_script"; then
    echo "    PASSED: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "    FAILED: $test_name"
    FAILED=$((FAILED + 1))
    FAILED_TESTS+=("$test_name")
  fi
done

echo ""
echo "========================================"
echo "  Results: $PASSED passed, $FAILED failed"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for failed_test in "${FAILED_TESTS[@]}"; do
    echo "  - $failed_test"
  done
  on_error
  exit 1
fi

echo ""
echo "Run './test/run-tests.sh cleanup' to tear down the stacks."
