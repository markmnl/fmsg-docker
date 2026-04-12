# AGENTS.md

This file is the primary instruction source for coding agents working in this repository.

## Scope

- Follow this file before using other repo-specific agent instruction files.
- Treat this repository as a Docker-based integration-test harness for the fmsg stack.

## Integration Test Guidance

- The integration tests live under `test/` and exercise the system with `fmsg-cli`.
- For CLI behavior, flags, and command syntax used by the integration tests, use the fmsg-cli README as the authoritative reference:
  https://github.com/markmnl/fmsg-cli/blob/main/README.md
- Do not assume `CLI_USAGE.md` in this repository is the canonical CLI reference if it conflicts with the upstream fmsg-cli README.

## Editing Guidance

- Keep changes minimal and targeted.
- Preserve the existing shell style in test scripts and runner scripts.
- When adding or updating integration tests, follow the existing numbering and naming pattern in `test/tests/`.
