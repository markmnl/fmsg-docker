# Quickstart - Setting up an fmsg host with fmsg-docker

This quickstart gets the docker compose stack from this repository up and running on your public fmsg server.

TLS provisioning is included and an HTTPS API is exposed so you can start sending and receiving fmsg messages for your domain. TCP port 4930 is also exposed for fmsg host-to-host communication.

Read the [README.md](https://github.com/markmnl/fmsg-docker) of this repo for more about settings and environment being used in this quickstart.

## Requirements

1. A domain you control, e.g `example.com`
2. A server with a public IP and
    1. TCP port `4930` open to the internet (fmsg TLS)
    2. TCP port `443` open to the internet (fmsg-webapi HTTPS)
    3. TCP port `80` open to the internet (only first start - required for initial Let's Encrypt certificate issuance)
3. Docker and Docker Compose, or Podman and podman-compose

## Steps

_NOTE_ This quickstart uses `docker compose` throughout. If you are using Podman, replace each occurrence with `podman compose`.

### 0. Server Setup

Make sure Docker is installed and running. Create a dedicated non-root `fmsg` operator account, create its checkout location, and shallow-clone the repository's default branch:

```sh
sudo useradd --create-home --shell /bin/bash fmsg
sudo install -d --owner=fmsg --group=fmsg /opt/fmsg-docker
sudo -u fmsg git clone --depth 1 https://github.com/markmnl/fmsg-docker.git /opt/fmsg-docker
sudo -u fmsg -H bash
```


### 1. Configure DNS

Create A (or AAAA if your public IP is IPv6) DNS records to resolve to your server IP for:

1. `fmsg.<your-domain>`
2. `fmsgapi.<your-domain>`

_NOTE_ Ensure DNS is kept up-to-date with your server's IP so you can send and receive messages!

### 2. Configure FMSG

As the `fmsg` user, configure the checkout in `/opt/fmsg-docker`. Copy the example env file:

```sh
cd /opt/fmsg-docker
cp .env.example compose/.env
```

Edit `compose/.env` and set at least:

```env
FMSG_DOMAIN=example.com
CERTBOT_EMAIL=
FMSG_API_TOKEN_ED25519_PRIVATE_KEY=<base64-ed25519-seed>
FMSGD_READER_PGPASSWORD=<strong-password>
FMSGD_WRITER_PGPASSWORD=<strong-password>
FMSGD_READER_PGPASSWORD=<strong-password>
FMSGID_WRITER_PGPASSWORD=<strong-password>
```

_NOTE_
* FMSG_DOMAIN is the domain part of fmsg addresses e.g. in `@user@example.com` would be `example.com`. This server you are setting up is located at the subdomain `fmsg.<your-domain>` but addresses will be at `<your-domain>`, you should only specify `<your-domain>` for FMSG_DOMAIN here.
* CERTBOT_EMAIL is an email address supplied to [Let's Encrypt](https://letsencrypt.org/) for e.g. TLS expiry warnings.
* Generate `FMSG_API_TOKEN_ED25519_PRIVATE_KEY` with `openssl rand -base64 32`.
* For all secrets and passwords env vars create your own.


Exit the fmsg login shell and start the stack for the first time by changing into `/opt/fmsg-docker/compose` and passing the one-time postgres super user password on the command line. (Generate and keep PGPASSWORD yourself, this will only be needed first time running compose up).

```sh
exit
cd /opt/fmsg-docker/compose
sudo env PGPASSWORD='<postgres-password>' docker compose up -d
```

First time will take a few minutes to pull docker images and initalise the database. After than check everything started with:

```
sudo docker compose ps
```

If `fmsgd` is running and port `4930` is reachable on `fmsg.<your domain>`, the host is up.

On first start, certbot will request Let's Encrypt TLS certificates for `fmsg.<your-domain>` and `fmsgapi.<your-domain>`. If certificate issuance fails (e.g. the domains do not resolve to the server or port 80 is blocked by firewall, or already in use), the stack will not start. Certificates are persisted in a Docker volume and reused on subsequent starts. Once certificates are issued port 80 is no longer needed until certificates need to be renewed - usually 90 days.


## Next Steps

### Add Users

Create users (message stores, analoguous to mailboxes) by placing a CSV file in the `fmsgid_data` volume at `/opt/fmsgid/data/addresses.csv`. The format is:

```csv
address,display_name,accepting_new,limit_recv_size_total,limit_recv_size_per_msg,limit_recv_size_per_1d,limit_recv_count_per_1d,limit_send_size_total,limit_send_size_per_msg,limit_send_size_per_1d,limit_send_count_per_1d
@alice@example.com,Alice,true,102400000,10240,102400,1000,102400000,10240,102400,1000
```

You can copy it into the volume with (file changes will sync automatically):

```sh
sudo docker compose cp addresses.csv fmsgid:/opt/fmsgid/data/addresses.csv
```

### Connect a Client

Create an API key for a user, then use it with [fmsg-cli](https://github.com/markmnl/fmsg-cli) or access the [fmsg-webapi](https://github.com/markmnl/fmsg-webapi) API directly at `https://fmsgapi.<your-domain>`.

To create an API key for `@alice@example.com`:

```sh
sudo docker compose exec fmsg-webapi /opt/fmsg-webapi/fmsg-webapi api-key create-delegation \
  -owner @alice@example.com \
  -agent cli \
  -addr @alice@example.com \
  -cidr 0.0.0.0/0,::/0 \
  -expires 2027-12-31T00:00:00Z

```

The command prints the plaintext API key only once. Store it securely. The `owner` and `addr` are the same, so the key authenticates as `@alice@example.com`; it does not impersonate another user. The CIDR values permit connections from any IPv4 or IPv6 address. Restrict them when the deployment is ready for production use.

Then use it from fmsg-cli:

```sh
export FMSG_API_URL=https://fmsgapi.<your-domain>

fmsg login <fmsg-key>

fmsg list
fmsg send @recipient@example.com "Hello, world!"
fmsg send @recipient@example.com ./message.txt
echo "Hello via stdin" | fmsg send @recipient@example.com -
```

To use the API directly, exchange the API key for a short-lived JWT:

```sh
export FMSG_API_URL=https://fmsgapi.<your-domain>
export FMSG_API_KEY=fmsgk_<key_id>_<secret>

curl --fail --silent --show-error \
  -X POST \
  -H "Authorization: Bearer $FMSG_API_KEY" \
  "$FMSG_API_URL/fmsg/token"
```

The response contains an `access_token`. Send it as a Bearer token with API requests:

```sh
curl --fail --silent --show-error \
  -H "Authorization: Bearer <access_token>" \
  "$FMSG_API_URL/fmsg"
```