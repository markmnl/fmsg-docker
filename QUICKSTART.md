# Quickstart - Setting up an fmsg host with fmsg-docker

This quickstart gets the docker compose stack from this repository up and running on your server. TLS provisioning is included and an HTTPS API is exposed so you can start sending and receiving fmsg messages for your domain. TCP port 4930 is also exposed for fmsg host-to-host communication.

To learn more about fmsg, see the documentation repository: (fmsg)[https://github.com/markmnl/fmsg].

Read the (README.md)[https://github.com/markmnl/fmsg-docker] of this repo for more about settings and environment being used in this quickstart.

## Requirements

1. A domain you control, e.g `example.com`
2. A server with a public IP and
    1. TCP port `4930` open to the internet (fmsg TLS)
    2. TCP port `443` open to the internet (fmsg-webapi HTTPS)
    3. TCP port `80` open to the internet (only first start - required for initial Let's Encrypt certificate issuance)
3. Docker and Docker Compose

## Steps

### 0. Server Setup

Clone this repository to the server and make sure docker is running.
```
git clone https://github.com/markmnl/fmsg-docker.git
```

### 1. Configure DNS

Create A (or AAAA if your public IP is IPv6) DNS records to resolve to your server IP for:

1. `fmsg.<your-domain>`
2. `fmsgapi.<your-domain>`

_NOTE_ Ensure DNS is kept up-to-date with your server's IP so you can send and receive messages!

### 2. Configure FMSG

Copy the example env file:

```sh
cp .env.example compose/.env
```

Edit `compose/.env` and set at least:

```env
FMSG_DOMAIN=example.com
CERTBOT_EMAIL=
FMSG_API_JWT_SECRET=<secret>
FMSGD_WRITER_PGPASSWORD=<strong-password>
FMSGID_WRITER_PGPASSWORD=<strong-password>
```

_NOTE_
* FMSG_DOMAIN is the domain part of fmsg addresses e.g. in `@user@example.com` would be `example.com`. This server you are setting up is located at the subdomain `fmsg.<your-domain>` but addresses will be at `<your-domain>`, you should only specify `<your-domain>` for FMSG_DOMAIN here.
* CERTBOT_EMAIL is an email address supplied to [Let's Encrypt](https://letsencrypt.org/) for e.g. TLS expiry warnings.
* For all secrets and passwords env vars create your own.

Start the stack for the first time from `compose/` and pass the one-time init passwords on the command line (keep these secret, keep them safe):

(might require sudo)

```sh
cd compose
PGPASSWORD=<postgres-password> \
FMSGD_READER_PGPASSWORD=<strong-password> \
FMSGID_READER_PGPASSWORD=<strong-password> \
docker compose up -d
```

If `fmsgd` is running and port `4930` is reachable on `fmsg.<your domain>`, the host is up.

On first start, certbot will request Let's Encrypt TLS certificates for `fmsg.<your-domain>` and `fmsgapi.<your-domain>`. If certificate issuance fails (e.g. the domains do not resolve to the server or port 80 is blocked), the stack will not start. Certificates are persisted in a Docker volume and reused on subsequent starts. Once certificates are issued port 80 is no longer needed until certificates need to be renewed - usually 90 days.


## Next Steps

### Add Users

Create users (message stores, analoguous to mailboxes) by placing a CSV file in the `fmsgid_data` volume at `/opt/fmsgid/data/addresses.csv`. The format is:

```csv
address,display_name,accepting_new,limit_recv_size_total,limit_recv_size_per_msg,limit_recv_size_per_1d,limit_recv_count_per_1d,limit_send_size_total,limit_send_size_per_msg,limit_send_size_per_1d,limit_send_count_per_1d
@alice@example.com,Alice,true,102400000,10240,102400,1000,102400000,10240,102400,1000
```

You can copy it into the volume with:

```sh
docker compose cp addresses.csv fmsgid:/opt/fmsgid/data/addresses.csv
docker compose restart fmsgid
```

### Connect a Client

* Connect a client such as [fmsg-cli](https://github.com/markmnl/fmsg-cli) to `fmsgapi.<your-domain>` configured with your `FMSG_API_JWT_SECRET` to send and retrieve messages.

_NOTE_ Anyone with `FMSG_API_JWT_SECRET` can mint tokens for your `fmsgapi.<your-domain>` for any user e.g. `@alice@<your-domain>`.