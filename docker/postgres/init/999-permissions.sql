-- =============================================================
-- Permissions — runs last, after all objects exist.
-- =============================================================

-- ── fmsgd database ──────────────────────────────────────────

\connect fmsgd

REVOKE ALL ON DATABASE fmsgd FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- fmsgd_writer: read/write access
GRANT CONNECT ON DATABASE fmsgd TO fmsgd_writer;
GRANT USAGE ON SCHEMA public TO fmsgd_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO fmsgd_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fmsgd_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO fmsgd_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO fmsgd_writer;

-- fmsgd_reader: read-only access
GRANT CONNECT ON DATABASE fmsgd TO fmsgd_reader;
GRANT USAGE ON SCHEMA public TO fmsgd_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO fmsgd_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO fmsgd_reader;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO fmsgd_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO fmsgd_reader;

-- ── fmsgid database ─────────────────────────────────────────

\connect fmsgid

REVOKE ALL ON DATABASE fmsgid FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- fmsgid_writer: read/write access
GRANT CONNECT ON DATABASE fmsgid TO fmsgid_writer;
GRANT USAGE ON SCHEMA public TO fmsgid_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO fmsgid_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO fmsgid_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO fmsgid_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO fmsgid_writer;

-- fmsgid_reader: read-only access
GRANT CONNECT ON DATABASE fmsgid TO fmsgid_reader;
GRANT USAGE ON SCHEMA public TO fmsgid_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO fmsgid_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO fmsgid_reader;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO fmsgid_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO fmsgid_reader;
