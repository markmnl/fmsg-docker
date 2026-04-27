# Quickstart - Setting up an fmsg host with fmsg-docker

This quick-start gets the docker compose stack from this repository up and running on your server. TLS provisioning is included and an HTTPS API is exposed so you can start sending and receiving fmsg messages for your domain. TCP port 4930 is also exposed for fmsg host-to-host communication.

To learn more about fmsg, see the documentation repository: [fmsg](https://github.com/markmnl/fmsg).

Read the [README.md](https://github.com/markmnl/fmsg-docker) of this repo for more about settings and environment being used in this quickstart.

## Contents

- [Requirements](#requirements)
- [Steps](#steps)
  - [0. Server Setup](#0-server-setup)
  - [1. Configure DNS](#1-configure-dns)
  - [2. Configure FMSG](#2-configure-fmsg)
- [Next Steps](#next-steps)
  - [Add Users](#add-users)
  - [Connect a Client](#connect-a-client)
- [Troubleshooting](#troubleshooting)
    - [container cannot reach `postgres` (Debian 13 / nftables hosts)](#container-cannot-reach-postgres-debian-13--nftables-hosts)

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

You can copy it into the volume with (file changes will sync automatically):

```sh
docker compose cp addresses.csv fmsgid:/opt/fmsgid/data/addresses.csv
```

### Connect a Client

* Connect a client such as [fmsg-cli](https://github.com/markmnl/fmsg-cli) to `fmsgapi.<your-domain>` configured with your `FMSG_API_JWT_SECRET` to send and retrieve messages.

_NOTE_ Anyone with `FMSG_API_JWT_SECRET` can mint tokens for your `fmsgapi.<your-domain>` for any user e.g. `@alice@<your-domain>`.


## Troubleshooting

### Container cannot reach `postgres` (Debian 13 / nftables hosts)

If a service fails to start with an error like:

```
ERROR: connecting to database: dial tcp: lookup postgres on 8.8.8.8:53: dial udp 8.8.8.8:53: connect: network is unreachable
```

the container cannot resolve `postgres` via Docker's embedded DNS and has no outbound network at all. This is almost always a host-side Docker bridge networking problem, most often seen on fresh Debian 13 installs where `nftables` is the default firewall backend. Try the following in order, least invasive first:

1. Restart the Docker daemon and recreate the stack:
   ```sh
   sudo systemctl restart docker
   cd compose && docker compose down && docker compose up -d
   ```
2. If the host has `nftables.service` enabled with its own ruleset, it can drop forwarded traffic for Docker's bridges. Either stop it or add accept rules for the docker interfaces:
   ```sh
   sudo systemctl disable --now nftables
   sudo systemctl restart docker
   ```
3. Ensure IPv4 forwarding is enabled (Docker normally sets this, but a sysctl drop-in can override it):
   ```sh
   sudo sysctl net.ipv4.ip_forward=1
   sudo systemctl restart docker
   ```
4. Use Docker's official `docker-ce` packages rather than Debian's `docker.io`, which has historically lagged on nftables support.
5. As a last resort, force the iptables-nft shim host-wide:
   ```sh
   sudo update-alternatives --set iptables /usr/sbin/iptables-nft
   sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
   sudo systemctl restart docker
   ```

After any of these, verify with:

```sh
docker compose exec fmsgd getent hosts postgres
```