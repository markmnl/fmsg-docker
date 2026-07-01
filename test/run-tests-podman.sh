#!/usr/bin/env bash
# =============================================================
# Run the fmsg integration tests using podman instead of docker.
#
# Prerequisites: podman, podman-compose (or docker-compose) go (1.24+), curl
#
# This shims a `docker` executable onto PATH that execs podman, then
# delegates straight to run-tests.sh so the two runners stay in sync.
#
# podman-compose (as of 1.6.0) has a couple of issues this shim works around:
#  - values under a YAML `!override` tag are not passed through variable
#    interpolation, so `${VAR:-default}` references inside an `!override`
#    block reach podman literally. The shim pre-resolves those itself.
#  - `up --wait` runs `podman wait --condition=running` for every service
#    without a healthcheck, including one-shot containers (like certbot
#    here) that are expected to exit — so it hangs forever. The shim strips
#    `--wait` from `compose up`; run-tests.sh already polls the webapi HTTP
#    endpoint before proceeding, so readiness is still verified.
#
# podman-compose also names containers "<project>_<service>_<index>"
# (underscores) whereas docker compose v2 names them
# "<project>-<service>-<index>" (hyphens). run-tests.sh hardcodes the
# docker-compose-v2-style names for `docker exec` targets, so the shim
# rewrites those to podman-compose's naming for that subcommand only.
#
# Usage: same as run-tests.sh, e.g.
#   ./test/run-tests-podman.sh
#   ./test/run-tests-podman.sh --no-start
#   ./test/run-tests-podman.sh cleanup
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v podman &>/dev/null || { echo "podman not found on PATH" >&2; exit 1; }

SHIM_DIR="$(mktemp -d)"
trap 'rm -rf "$SHIM_DIR"' EXIT

cat > "$SHIM_DIR/resolve-compose-vars.py" <<'EOF'
import os
import re
import sys

PATTERN = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}')


def repl(match):
    name, _, default = match.groups()
    value = os.environ.get(name)
    if value:
        return value
    return default if default is not None else ''


text = open(sys.argv[1]).read()
sys.stdout.write(PATTERN.sub(repl, text))
EOF

cat > "$SHIM_DIR/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail

args=("\$@")
if [ "\${1:-}" = "exec" ]; then
  for i in "\${!args[@]}"; do
    if [[ "\${args[\$i]}" != -* ]] && [ "\$i" != "0" ]; then
      name="\${args[\$i]}"
      if [[ "\$name" == *-fmsg-webapi-* ]]; then
        args[\$i]="\${name/-fmsg-webapi-/_fmsg-webapi_}"
      else
        args[\$i]="\${name//-/_}"
      fi
      break
    fi
  done
fi
if [ "\${1:-}" = "compose" ]; then
  filtered=()
  for i in "\${!args[@]}"; do
    if [ "\${args[\$i]}" = "-f" ]; then
      next=\$((i + 1))
      case "\${args[\$next]}" in
        */docker-compose.test.yml)
          resolved="$SHIM_DIR/\$(basename "\${args[\$next]}").\$\$.resolved.yml"
          python3 "$SHIM_DIR/resolve-compose-vars.py" "\${args[\$next]}" > "\$resolved"
          args[\$next]="\$resolved"
          ;;
      esac
    fi
    if [ "\${args[\$i]}" = "--wait" ]; then
      continue
    fi
    filtered+=("\${args[\$i]}")
  done
  args=("\${filtered[@]}")
fi

exec podman "\${args[@]}"
EOF
chmod +x "$SHIM_DIR/docker"

export PATH="$SHIM_DIR:$PATH"

exec "$SCRIPT_DIR/run-tests.sh" "$@"
