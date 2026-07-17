# AGENTS.md

This file is the primary instruction source for coding agents working in this repository.

## Scope

- Follow this file before using other repo-specific agent instruction files.
- Treat this repository as a Docker-based (or podman) integration-test harness, a production worthy or local dev fmsg stack consisting of:
  - fmsgd: https://github.com/markmnl/fmsgd, the back-end daemon for host-to-host fmsg comms
  - fmsg-webapi: https://github.com/markmnl/fmsg-webapi, the HTTP API for clients to retieve and send messages via their fmsgd host
  - fmsgid: https://github.com/markmnl/fmsgid, an HTTP API used by both fmsg-webapi and fmsgd defining users and message quotas
  - A PostgreSQL database owned by fmsgd and shared by fmsg-webapi for storing this host's messages
- fmsg-cli: https://github.com/markmnl/fmsg-cli which provides the CLI: `fmsg`, to drive fmsg-webapi - used by tests and examples as no UI is included
- No Identity Providers is included to manually specifying users to fmsgid

## Integration Test Guidance

- The integration tests live under `test/` and exercise the system with `fmsg-cli`.
- For CLI behavior, flags, and command syntax used by the integration tests, use the fmsg-cli README as the authoritative reference:
  https://github.com/markmnl/fmsg-cli/blob/main/README.md

## Editing Guidance

- Keep changes minimal and targeted.
- Preserve the existing shell style in test scripts and runner scripts.
- When adding or updating integration tests, follow the existing numbering and naming pattern in `test/tests/`.
