#!/bin/sh
# Runs once, on first initialisation of the development database volume (docker-entrypoint-initdb.d).
# Least privilege:
#   gossy_owner - owns the database/schema; used ONLY by Alembic migrations.
#   gossy_app   - runtime role for api/ingest: SELECT/INSERT/UPDATE, no DDL, no DELETE.
# The timescaledb extension needs superuser, so it is created here, not by migrations.
# Passwords are read from the development secrets volume; DEVELOPMENT ONLY.

OWNER_PW="$(cat /run/gossy-secrets/db/owner.password)"
APP_PW="$(cat /run/gossy-secrets/db/app.password)"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
     -v owner_pw="$OWNER_PW" -v app_pw="$APP_PW" <<'SQL'
CREATE ROLE gossy_owner LOGIN PASSWORD :'owner_pw';
CREATE ROLE gossy_app LOGIN PASSWORD :'app_pw';
CREATE DATABASE gossy OWNER gossy_owner;
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname gossy <<'SQL'
CREATE EXTENSION IF NOT EXISTS timescaledb;
REVOKE ALL ON DATABASE gossy FROM PUBLIC;
GRANT CONNECT ON DATABASE gossy TO gossy_owner, gossy_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO gossy_owner;
GRANT USAGE ON SCHEMA public TO gossy_app;
ALTER DEFAULT PRIVILEGES FOR ROLE gossy_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO gossy_app;
ALTER DEFAULT PRIVILEGES FOR ROLE gossy_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO gossy_app;
SQL
