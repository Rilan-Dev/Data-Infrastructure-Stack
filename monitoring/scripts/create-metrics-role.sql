-- Least-privilege read-only role for the Paperclip identity-context exporter.
--
-- Do not run this file directly: it expects the psql variable `role_password` to
-- already be set. Use ./provision-metrics-role.sh, which pipes the password in
-- over stdin so it never appears in argv (and therefore never in `ps` output,
-- shell history, or the Docker command log).
--
-- The role is deliberately allowed to do exactly one thing: SELECT from
-- public.run_identity_contexts. verify-readonly.sh asserts that.

\set ON_ERROR_STOP on

SELECT NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = 'paperclip_metrics_ro'
) AS role_missing \gset

\if :role_missing
CREATE ROLE paperclip_metrics_ro LOGIN PASSWORD :'role_password';
\else
ALTER ROLE paperclip_metrics_ro LOGIN PASSWORD :'role_password';
\endif

-- No superuser/createdb/createrole/replication/bypassrls, and a small
-- connection budget so a runaway exporter cannot exhaust max_connections.
ALTER ROLE paperclip_metrics_ro
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 4;

-- Revoke everything this role might have been granted before, then hand back
-- only what the exporter query needs.
REVOKE ALL ON DATABASE paperclip FROM paperclip_metrics_ro;
GRANT CONNECT ON DATABASE paperclip TO paperclip_metrics_ro;

REVOKE ALL ON SCHEMA public FROM paperclip_metrics_ro;
GRANT USAGE ON SCHEMA public TO paperclip_metrics_ro;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM paperclip_metrics_ro;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM paperclip_metrics_ro;

GRANT SELECT ON public.run_identity_contexts TO paperclip_metrics_ro;

-- Note on cross-database reach: PostgreSQL grants CONNECT on most databases to
-- PUBLIC, and revoking it per-role does not override that. This role can
-- therefore open a connection to another database on the cluster, but it holds
-- no table, sequence, function, or schema-CREATE privilege anywhere else (PG16
-- no longer grants CREATE on `public` to PUBLIC), so it can read and write
-- nothing there. verify-readonly.sh checks that explicitly rather than
-- pretending the connection itself is blocked.

\echo 'paperclip_metrics_ro provisioned.'
