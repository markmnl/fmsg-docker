#!/usr/bin/env bash
# Shared Docker-first / Podman-fallback support for local development scripts.

select_container_engine() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
    CONTAINER_HOST_GATEWAY="host.docker.internal"
    return
  fi

  if ! command -v podman >/dev/null 2>&1; then
    echo "Missing required container engine: install Docker Compose or Podman with podman-compose." >&2
    exit 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Missing required command for Podman Compose support: python3" >&2
    exit 1
  fi

  CONTAINER_ENGINE="podman"
  CONTAINER_HOST_GATEWAY="host.containers.internal"

  container_engine_shim_dir="$(mktemp -d)"
  trap 'rm -rf "$container_engine_shim_dir"' EXIT
  export container_engine_shim_dir

  cat > "$container_engine_shim_dir/resolve-compose-vars.py" <<'EOF'
import os
import re
import sys

PATTERN = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}')


def replace_variable(match):
    name, _, default = match.groups()
    value = os.environ.get(name)
    if value:
        return value
    return default if default is not None else ''


def resolve_variables(text):
    return PATTERN.sub(replace_variable, text)


# podman-compose cannot parse mapping-form `depends_on` entries with a
# `condition` nested under `!override`, so collapse that form to a list.
depends_on_re = re.compile(r'^(\s*)depends_on:\s*!override\s*$')
key_re = re.compile(r'^(\s+)([A-Za-z0-9_.-]+):\s*$')
condition_re = re.compile(r'^\s+condition:\s*\S+\s*$')


def flatten_depends_on(text):
    lines = text.split('\n')
    output = []
    index = 0
    while index < len(lines):
        match = depends_on_re.match(lines[index])
        if not match:
            output.append(lines[index])
            index += 1
            continue

        base_indent = match.group(1)
        index += 1
        services = []
        while index < len(lines):
            key_match = key_re.match(lines[index])
            if key_match and len(key_match.group(1)) > len(base_indent):
                services.append(key_match.group(2))
                index += 1
                while index < len(lines) and condition_re.match(lines[index]):
                    index += 1
                continue
            break
        output.append('{}depends_on: !override [{}]'.format(base_indent, ', '.join(services)))
    return '\n'.join(output)


# Profiles on an override are not handled correctly by podman-compose. The
# local runner replaces certbot with a no-op entrypoint, so the profile is not
# needed when `--wait` is removed by the compatibility shim.
profiles_re = re.compile(r'^\s*profiles:\s*\[.*\]\s*$')


text = open(sys.argv[1], encoding='utf-8').read()
text = resolve_variables(text)
text = flatten_depends_on(text)
sys.stdout.write('\n'.join(line for line in text.split('\n') if not profiles_re.match(line)))
EOF

  cat > "$container_engine_shim_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=("$@")
if [[ "${1:-}" == "compose" ]]; then
  for index in "${!args[@]}"; do
    if [[ "${args[$index]}" == "cp" ]]; then
      source_index=$((index + 1))
      destination_index=$((index + 2))
      destination="${args[$destination_index]}"
      service="${destination%%:*}"
      container_path="${destination#*:}"
      container_name="${COMPOSE_PROJECT_NAME}_${service}_1"
      exec podman cp "${args[$source_index]}" "${container_name}:${container_path}"
    fi
  done

  filtered=()
  for index in "${!args[@]}"; do
    if [[ "${args[$index]}" == "-f" ]]; then
      next=$((index + 1))
      case "${args[$next]}" in
        */docker-compose.local-dev.yml)
          resolved="$container_engine_shim_dir/$(basename "${args[$next]}").$$.resolved.yml"
          python3 "$container_engine_shim_dir/resolve-compose-vars.py" "${args[$next]}" > "$resolved"
          args[$next]="$resolved"
          ;;
      esac
    fi

    # podman-compose waits indefinitely for the no-op certbot container when
    # Compose is invoked with `up --wait`. It also does not accept Docker
    # Compose's `ps -a`; its `ps` command already includes stopped containers.
    if [[ "${args[$index]}" == "--wait" || "${args[$index]}" == "-a" ]]; then
      continue
    fi
    filtered+=("${args[$index]}")
  done
  args=("${filtered[@]}")
fi

exec podman "${args[@]}"
EOF
  chmod +x "$container_engine_shim_dir/docker"

  export PATH="$container_engine_shim_dir:$PATH"
}