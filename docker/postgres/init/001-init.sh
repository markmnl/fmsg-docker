#!/bin/bash
set -euo pipefail

# =============================================================
# First-run initialisation — executed once when the data volume
# is empty.  Runs as the POSTGRES_USER superuser.
#
# Creates application roles and databases.  Passwords are read
# from container environment variables set via docker-compose.
# =============================================================

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL

    -- ── Application roles ────────────────────────────────────
    CREATE ROLE fmsgd_writer  LOGIN PASSWORD '${FMSGD_WRITER_PGPASSWORD}';
    CREATE ROLE fmsgd_reader  LOGIN PASSWORD '${FMSGD_READER_PGPASSWORD}';
    CREATE ROLE fmsgid_writer LOGIN PASSWORD '${FMSGID_WRITER_PGPASSWORD}';
    CREATE ROLE fmsgid_reader LOGIN PASSWORD '${FMSGID_READER_PGPASSWORD}';

    -- ── Databases (owned by superuser) ───────────────────────
    CREATE DATABASE fmsgd;
    CREATE DATABASE fmsgid;

EOSQL
