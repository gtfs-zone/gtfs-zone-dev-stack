-- Per-service roles and databases, mirroring the CNPG topology in prod
-- (gtfs-zone-infra gtfs/postgres-cluster.yaml) rather than running everything as
-- the `postgres` superuser against one `postgres` database.
--
-- The point is that grant and ownership bugs show up locally. Under a single
-- superuser every object is readable by everything, so a missing GRANT in a
-- migration is invisible until it reaches the cluster.
--
-- Runs from /docker-entrypoint-initdb.d, so ONLY on a fresh data directory.
-- An existing dev volume keeps the old single-database layout until
-- `scripts/reset.sh` (docker compose down -v) wipes it.
--
-- Passwords match the role names: this is a local-only stack whose Postgres
-- port is published to the host for psql, and nothing here is a real secret.

CREATE ROLE rt_api LOGIN PASSWORD 'rt_api';
CREATE ROLE keycloak LOGIN PASSWORD 'keycloak';
CREATE ROLE traccar LOGIN PASSWORD 'traccar';

CREATE DATABASE rt_api OWNER rt_api;
CREATE DATABASE keycloak OWNER keycloak;
CREATE DATABASE traccar OWNER traccar;

-- Each service owns its own schema outright. Without this the public schema is
-- still owned by `postgres` on PG15+, and the owner role cannot create tables
-- in the database it supposedly owns.
\connect rt_api
ALTER SCHEMA public OWNER TO rt_api;

\connect keycloak
ALTER SCHEMA public OWNER TO keycloak;

\connect traccar
ALTER SCHEMA public OWNER TO traccar;
