#!/usr/bin/env bash
# =============================================================
# Run the fmsg integration tests.
#
# Prerequisites: docker, docker compose, go (1.24+), curl
#
# Usage:
#   ./test/run-tests.sh          # run tests
#   ./test/run-tests.sh cleanup  # tear down stacks & network
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
  echo "==> Cleanup complete."
}

if [ "${1:-}" = "cleanup" ]; then
  cleanup
  exit 0
fi

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
export FMSG_API_JWT_SECRET=test-jwt-secret
export FMSG_JWT_SECRET=test-jwt-secret

# ── Pass through ref overrides for Docker build args ─────────
export FMSGD_REF=${FMSGD_REF:-main}
export FMSGID_REF=${FMSGID_REF:-main}
export FMSG_WEBAPI_REF=${FMSG_WEBAPI_REF:-main}
FMSG_CLI_REF=${FMSG_CLI_REF:-main}

# ── Ensure Go is on PATH ──────────────────────────────────────
if ! command -v go &>/dev/null && [ -x /usr/local/go/bin/go ]; then
  export PATH="/usr/local/go/bin:$PATH"
fi

# ── Build fmsg CLI ───────────────────────────────────────────
FMSG_BIN="$REPO_ROOT/test/.bin/fmsg"
if [ ! -x "$FMSG_BIN" ]; then
  echo "==> Building fmsg CLI (ref: $FMSG_CLI_REF)..."
  mkdir -p "$(dirname "$FMSG_BIN")"
  FMSG_CLI_DIR=$(mktemp -d)
  git clone --branch "$FMSG_CLI_REF" --depth 1 https://github.com/markmnl/fmsg-cli.git "$FMSG_CLI_DIR"
  (cd "$FMSG_CLI_DIR" && go build -o "$FMSG_BIN" .)
  rm -rf "$FMSG_CLI_DIR"
fi
export PATH="$(dirname "$FMSG_BIN"):$PATH"
echo "==> fmsg CLI: $FMSG_BIN"

# ── Clean up any previous run ────────────────────────────────
cleanup

# ── Create shared Docker network ────────────────────────────
echo "==> Creating fmsg-test network..."
docker network create fmsg-test

# ── Start hairpin.local ──────────────────────────────────────
echo "==> Starting hairpin.local stack..."
cd "$REPO_ROOT/compose"
COMPOSE_PROJECT_NAME=hairpin \
FMSG_DOMAIN=hairpin.local \
FMSG_PORT=4931 \
FMSG_WEBAPI_HOST_PORT=8181 \
  docker compose -f docker-compose.yml -f ../test/docker-compose.test.yml up -d --build --force-recreate --no-deps --wait

# ── Start example.com ────────────────────────────────────────
echo "==> Starting example.com stack..."
COMPOSE_PROJECT_NAME=example \
FMSG_DOMAIN=example.com \
FMSG_PORT=4932 \
FMSG_WEBAPI_HOST_PORT=8182 \
  docker compose -f docker-compose.yml -f ../test/docker-compose.test.yml up -d --build --wait

# ── Debug: show running containers & port mappings ───────────
echo "==> Running containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# ── Wait for webapi endpoints ────────────────────────────────
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

# ── Seed test users ─────────────────────────────────────────
echo "==> Seeding users..."
docker exec -i hairpin-postgres-1 psql -U postgres < "$REPO_ROOT/test/seed-hairpin.sql"
docker exec -i example-postgres-1 psql -U postgres < "$REPO_ROOT/test/seed-example.sql"

# ── Export env vars for test scripts ──────────────────────────
export HAIRPIN_API_URL=http://localhost:8181
export EXAMPLE_API_URL=http://localhost:8182

# ── Run test scripts ─────────────────────────────────────────
TESTS_DIR="$SCRIPT_DIR/tests"
PASSED=0
FAILED=0
FAILURES=""

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
    FAILURES="$FAILURES  - $test_name\n"
  fi
done

echo ""
echo "========================================"
echo "  Results: $PASSED passed, $FAILED failed"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  printf "Failed tests:\n$FAILURES"
  exit 1
fi

echo ""
echo "Run './test/run-tests.sh cleanup' to tear down the stacks."
