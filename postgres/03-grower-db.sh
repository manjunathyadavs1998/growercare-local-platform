#!/bin/sh
# SPEC-GRW-01 (growercare-grower-service): database gc_grower with its owner/app roles, the same split as 01-init.sh.
# Runs on first start of an empty volume (after 01/02); for an existing volume run ./apply-grower-service.sh.
# Idempotent: roles and database are created only when missing.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
  DO \$\$ BEGIN
    CREATE ROLE gc_grower_owner LOGIN PASSWORD '${GC_GROWER_OWNER_PASSWORD}';
  EXCEPTION WHEN duplicate_object THEN
    ALTER ROLE gc_grower_owner LOGIN PASSWORD '${GC_GROWER_OWNER_PASSWORD}';
  END \$\$;
  DO \$\$ BEGIN
    CREATE ROLE gc_grower_app LOGIN PASSWORD '${GC_GROWER_APP_PASSWORD}';
  EXCEPTION WHEN duplicate_object THEN
    ALTER ROLE gc_grower_app LOGIN PASSWORD '${GC_GROWER_APP_PASSWORD}';
  END \$\$;
  SELECT 'CREATE DATABASE gc_grower OWNER gc_grower_owner'
   WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'gc_grower') \gexec
  REVOKE ALL ON DATABASE gc_grower FROM PUBLIC;
  GRANT CONNECT ON DATABASE gc_grower TO gc_grower_app;
  GRANT CONNECT ON DATABASE gc_grower TO gc_cdc;
SQL

# Objects created later by the owner role are usable (DML) by the app role; migrations REVOKE what must stay closed.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname gc_grower <<-SQL
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
  ALTER DEFAULT PRIVILEGES FOR ROLE gc_grower_owner GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO gc_grower_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE gc_grower_owner GRANT USAGE, SELECT ON SEQUENCES TO gc_grower_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE gc_grower_owner GRANT EXECUTE ON FUNCTIONS TO gc_grower_app;
SQL
