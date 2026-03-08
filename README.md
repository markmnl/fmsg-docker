# fmsg-docker
Dockerised stack composing a full fmsg setup including: fmsgd, fmsgid, fmsg-webapi and fmsg-cli

## Structure

```
fmsg-docker/
├── docker/
│   └── fmsgd/
│       └── Dockerfile        # builds fmsgd from source
│
├── compose/
│   ├── docker-compose.yml    # full fmsg stack
│   └── .env                  # environment configuration
│
└── README.md
```

## Getting Started

1. Edit `compose/.env` and set your domain and a secure database password:

   ```
   FMSG_DOMAIN=example.com
   PGPASSWORD=changeme
   ```

2. From the `compose/` directory, start the stack:

   ```
   docker compose up -d
   ```

3. fmsgd will be available on port `4930` (or the port set by `FMSG_PORT` in `.env`).

## Services

| Service       | Description                                      |
|---------------|--------------------------------------------------|
| `postgres`    | PostgreSQL database shared by fmsgd and fmsgid   |
| `fmsgid`      | fmsg Id HTTP API — manages users and quotas      |
| `fmsgd`       | fmsg host — sends and receives fmsg messages     |
| `fmsg-webapi` | fmsg Web API — HTTP interface to the fmsg stack  |
