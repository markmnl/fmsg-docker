# Local Development

The local-development scripts run a self-contained fmsg stack on this machine.
They use Docker Compose when it is available and otherwise fall back to Podman
with `podman-compose`.

The default stack uses:

- Address domain: `hairpin.local`
- fmsg-webapi: `http://localhost:8181`
- fmsgd: `fmsg.hairpin.local:4930`
- PostgreSQL: `localhost:54321`
- Seeded addresses: `@alice@hairpin.local`, `@bob@hairpin.local`,
  `@carol@hairpin.local`, and `@dave@hairpin.local`

## Other Docs

| Name | Description |
|---|---|
| [QUICKSTART.md](QUICKSTART.md) | Production deployment setup. |
| [README.md](README.md) | Repository configuration and reference. |

## 1. Prerequisites

Install either Docker with Docker Compose or Podman with `podman-compose`.
The scripts select Docker when available, otherwise Podman. `openssl` is also
required to generate the local fmsg TLS certificate.

For the command examples below, install [fmsg-cli](https://github.com/markmnl/fmsg-cli)
and make sure `fmsg` is on `PATH`.

## 2. Start the stack

From this repo, run:

```sh
./scripts/start-local-dev.sh hairpin.local
```

The runner creates a self-signed certificate, starts the services, and copies
[compose/addresses.csv](compose/addresses.csv) into fmsgid. It chooses the
default `hairpin.local` domain if the argument is omitted.

If port 8181 is already occupied, choose another API port:

```sh
FMSG_WEBAPI_HOST_PORT=8183 ./scripts/start-local-dev.sh hairpin.local
```

Use that same port in the `FMSG_API_URL` commands below.

## 3. Check the stack

The command matching the installed engine shows the services:

```sh
docker compose ps
# or, when Docker is unavailable:
podman ps
```

`fmsg-webapi` does not define a route at `/`, so an HTTP `404` from that path
still proves that the local API is reachable.

## 4. Stop or remove the stack

Stop the containers while keeping data, generated certificates, and the
rendered addresses CSV:

```sh
./scripts/stop-local-dev.sh hairpin.local
```

Start the stopped stack again:

```sh
./scripts/start-local-dev.sh hairpin.local
```

Remove the stack, volumes, generated certificate, rendered CSV, and generated
Compose override:

```sh
./scripts/del-local-dev.sh hairpin.local
```

## 5. API authentication

fmsg-cli authenticates with either a user JWT or an fmsg API key. The local
runner is ready to use with API keys; no external identity provider or JWT is
needed for the workflow below.

The API-key helper creates a delegated key inside the running local
`fmsg-webapi` container. Its default address is the seeded
`@alice@hairpin.local` user. Calling the helper again rotates the key: use the
new key to log in and any previously issued key stops working.

```sh
./scripts/create-local-dev-api-key.sh hairpin.local
```

Pass a different seeded address as the second argument when needed:

```sh
./scripts/create-local-dev-api-key.sh hairpin.local @bob@hairpin.local
```

## 6. Connect fmsg-cli

These commands match the default stack started by
`./scripts/start-local-dev.sh hairpin.local` and can be copied verbatim:

```sh
export FMSG_API_URL=http://localhost:8181

fmsg login "$(./scripts/create-local-dev-api-key.sh hairpin.local @alice@hairpin.local)"

fmsg list
fmsg send @bob@hairpin.local "Hello from local development"
```

`fmsg login` stores the API key-derived credentials in
`~/.config/fmsg/auth.json` (or `$XDG_CONFIG_HOME/fmsg/auth.json`). For a
non-interactive shell, keep the API key in an environment variable instead:

```sh
export FMSG_API_URL=http://localhost:8181
export FMSG_API_KEY="$(./scripts/create-local-dev-api-key.sh hairpin.local @alice@hairpin.local)"

fmsg list
```

The API key is exchanged for short-lived JWTs automatically by fmsg-cli.
