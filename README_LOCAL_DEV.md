# Local Development (no domain, no IdP, Podman)

This describes running the fmsg-docker stack entirely on your own machine:

- No real domain name (uses `fmsg.local.test` / `fmsgapi.local.test` resolved via `/etc/hosts`)
- No Let's Encrypt / certbot (self-signed TLS certs instead)
- No external IdP / JWKS login (the `FMSG_JWT_*` vars are optional — leave them unset and
  auth flows entirely through fmsg-webapi's own API key operator command, same as QUICKSTART.md)
- Podman instead of Docker

This is basically the same trick `test/docker-compose.test.yml` and `test/run-tests.sh` already
use for integration tests (self-signed certs + `FMSG_SKIP_DOMAIN_IP_CHECK` + certbot disabled),
just simplified to a single instance for interactive local dev.


## Other Docs

| Name                                       | Description                                                        |
|--------------------------------------------|--------------------------------------------------------------------|
| [QUICKSTART.md](QUICKSTART.md)             | Get a production stack up and running on your server in minutes.   |
| [README.md](README.md)                     | Full README for this code repository.                    |


**NB:** Can run `./scripts/run-local.dev.sh` to perform the below

## 1. Podman setup

Docker Compose files work unmodified with Podman via the `podman-compose` project, or with
Podman's own `podman compose` command (Podman 4.7+ ships a Docker Compose-compatible frontend
that shells out to `docker-compose`/`podman-compose` under the hood).

Check what you have:

```sh
podman compose version   # built-in, if available
# or
podman-compose version   # separate package, e.g. `dnf install podman-compose`
```

Everywhere below that says `docker compose`, substitute `podman compose` or `podman-compose`.
Rootless Podman can't bind ports below 1024 without extra privileges, so this guide maps
`fmsg-webapi` and the ACME port to unprivileged host ports (see the override file below).

Optional convenience alias so you don't have to remember to swap commands:

```sh
alias docker=podman
```

## 2. Add local hostnames

fmsgd and fmsg-webapi expect to serve `fmsg.<FMSG_DOMAIN>` and `fmsgapi.<FMSG_DOMAIN>` respectively.
Pick a fake domain and point it at your machine via `/etc/hosts`:

```sh
echo "127.0.0.1 fmsg.local.test fmsgapi.local.test" | sudo tee -a /etc/hosts
```

## 3. Generate self-signed TLS certs

Skip certbot/Let's Encrypt entirely (it requires a real domain reachable on port 80) and
generate certs the same way `test/run-tests.sh` does:

```sh
mkdir -p test/.tls
for name in fmsg.local.test fmsgapi.local.test; do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "test/.tls/${name}.key" \
    -out "test/.tls/${name}.crt" \
    -days 365 -nodes \
    -subj "//CN=${name}" \
    -addext "subjectAltName=DNS:${name}"
done
chmod 644 test/.tls/*.key
```

## 4. Local-dev compose override

Create `compose/docker-compose.local.yml` next to `docker-compose.yml`:

Note the certs live on the host at `test/.tls/` (step 3), but `FMSG_TLS_CERT`/`FMSG_TLS_KEY`
are paths *inside the container*. The `volumes:` line below mounts the host's `../test/.tls`
(relative to `compose/`, i.e. `test/.tls` at the repo root) to `/opt/fmsg/tls` inside each
container, so `/opt/fmsg/tls/fmsg.${FMSG_DOMAIN}.crt` resolves to the
`test/.tls/fmsg.local.test.crt` file generated in step 3.

```yaml
services:

  certbot:
    entrypoint: ["true"]
    restart: "no"
    ports: !override []

  postgres:
    ports:
      - "5432:5432"

  fmsgd:
    environment:
      FMSG_TLS_CERT: /opt/fmsg/tls/fmsg.${FMSG_DOMAIN}.crt
      FMSG_TLS_KEY: /opt/fmsg/tls/fmsg.${FMSG_DOMAIN}.key
    volumes:
      - ../test/.tls:/opt/fmsg/tls:ro
    depends_on: !override
      postgres:
        condition: service_healthy
      fmsgid:
        condition: service_started

  fmsg-webapi:
    environment:
      FMSG_TLS_CERT: /opt/fmsg/tls/fmsgapi.${FMSG_DOMAIN}.crt
      FMSG_TLS_KEY: /opt/fmsg/tls/fmsgapi.${FMSG_DOMAIN}.key
    volumes:
      - ../test/.tls:/opt/fmsg/tls:ro
    depends_on: !override
      fmsgd:
        condition: service_started
      fmsgid:
        condition: service_started
    ports: !override
      - "8443:${FMSG_API_PORT:-8000}"
```

This disables certbot, points both services at the self-signed certs from step 3, remaps
`fmsg-webapi` to host port `8443` so rootless Podman doesn't need to bind `443`, and exposes
`postgres` on host port `5432` so you can connect directly with `psql` or a GUI client while
developing (e.g. `psql -h localhost -U postgres`, password from `PGPASSWORD` in step 6).

## 5. Configure env

Compose auto-loads a file literally named `.env` in the working directory, so reusing that
name risks silently overwriting (or being confused with) a real `compose/.env` you already
have configured for a non-local deployment. Use a separate `compose/.env.local` instead, and
pass it explicitly with `--env-file` — this is the standard way to keep multiple compose env
profiles side by side without clobbering the default one:

```sh
cp .env.example compose/.env.local
```

Edit `compose/.env.local`:

```env
FMSG_DOMAIN=local.test
CERTBOT_EMAIL=dev@local.test          # unused, certbot is disabled, but the var is required
FMSG_API_TOKEN_ED25519_PRIVATE_KEY=<output of `openssl rand -base64 32`>
FMSGD_WRITER_PGPASSWORD=devpassword
FMSGID_WRITER_PGPASSWORD=devpassword
FMSG_SKIP_DOMAIN_IP_CHECK=true
FMSG_SKIP_AUTHORISED_IPS=true
```

Leave the `FMSG_JWT_*` vars unset — that's what opts out of JWKS/IdP login.

`FMSG_SKIP_DOMAIN_IP_CHECK=true` is required because fmsgd normally verifies your domain's DNS
resolves to the host's public IP, which a fake local domain never will. `FMSG_SKIP_AUTHORISED_IPS=true`
avoids needing real allow-listed peer IPs for host-to-host TCP.

Because `compose/.env.local` isn't auto-loaded, every `podman compose` invocation below passes
`--env-file .env.local` explicitly (paths are relative to `compose/`, where these commands are
run from). If you forget it, compose falls back to `compose/.env` (or nothing), and the local
overrides silently won't apply.

## 6. Start the stack

```sh
cd compose
PGPASSWORD=devpgpass \
FMSGD_READER_PGPASSWORD=devpassword \
FMSGID_READER_PGPASSWORD=devpassword \
podman compose --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

Check everything came up:

```sh
podman compose --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml ps
```

fmsg-webapi is now reachable at `https://fmsgapi.local.test:8443` (self-signed, so clients need
`-k`/insecure-skip-verify), and fmsgd is listening on TCP `4930` for host-to-host traffic.

## Stopping the stack

Stops containers but keeps them (and their data volumes) around so `up -d` again is fast and
your postgres data / issued certs persist:

```sh
cd compose
podman compose --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml stop
```

Restart later with:

```sh
podman compose --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml start
```

## Stopping and removing the stack

Removes the containers (and network), but by default leaves named volumes (`postgres_data`,
`fmsg_data`, `fmsgid_data`, `letsencrypt`) intact:

```sh
cd compose
podman compose --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml down
```

To also wipe all persisted data (postgres DB, fmsg/fmsgid data, certs) and start completely
fresh next time, add `-v`:

```sh
podman compose --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml down -v
```

Then remove the self-signed TLS certs generated in step 3 too, since they're outside the
compose volumes:

```sh
rm -rf ../test/.tls
```

## 7. Add a user and API key

Same as QUICKSTART.md's "Next Steps", just against the local containers:

```sh
printf 'address,display_name,accepting_new,limit_recv_size_total,limit_recv_size_per_msg,limit_recv_size_per_1d,limit_recv_count_per_1d,limit_send_size_total,limit_send_size_per_msg,limit_send_size_per_1d,limit_send_count_per_1d\n@alice@local.test,Alice,true,102400000,10240,102400,1000,102400000,10240,102400,1000\n' > addresses.csv

podman compose --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml cp addresses.csv fmsgid:/opt/fmsgid/data/addresses.csv

podman compose --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml exec fmsg-webapi \
  /opt/fmsg-webapi/fmsg-webapi api-key create-delegation \
  -owner @alice@local.test \
  -agent cli \
  -addr @alice@local.test \
  -cidr 127.0.0.1/32 \
  -expires 2099-01-01T00:00:00Z
```

Then use [fmsg-cli](https://github.com/markmnl/fmsg-cli) against it:

```sh
FMSG_API_URL=https://fmsgapi.local.test:8443 \
FMSG_API_KEY=fmsgk_<key_id>_<secret> \
FMSG_TLS_INSECURE_SKIP_VERIFY=true \
fmsg list
```

## TODO before folding into README.md

- Confirm exact `podman compose` / `podman-compose` invocation on this machine works as-is
  (rootless networking between containers, volume permissions).
- Confirm `fmsg-cli` actually supports `FMSG_TLS_INSECURE_SKIP_VERIFY`, or find the right flag.
- Decide whether this override file should be checked into the repo (e.g. as
  `compose/docker-compose.dev.yml`) rather than living only in this doc.
