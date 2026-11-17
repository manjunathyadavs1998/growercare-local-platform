#!/bin/sh
# SPEC-CAT-01 (growercare-catalog-registry-service): database gc_catalog with its owner/app roles, the same split as 01-init.sh.
# Runs on first start of an empty volume (after 01-04); for an existing volume run ./apply-catalog-service.sh.
# Idempotent: roles and database are created only when missing.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
  DO \$\$ BEGIN
    CREATE ROLE gc_catalog_owner LOGIN PASSWORD '${GC_CATALOG_OWNER_PASSWORD}';
  EXCEPTION WHEN duplicate_object THEN
    ALTER ROLE gc_catalog_owner LOGIN PASSWORD '${GC_CATALOG_OWNER_PASSWORD}';
  END \$\$;
  DO \$\$ BEGIN
    CREATE ROLE gc_catalog_app LOGIN PASSWORD '${GC_CATALOG_APP_PASSWORD}';
  EXCEPTION WHEN duplicate_object THEN
    ALTER ROLE gc_catalog_app LOGIN PASSWORD '${GC_CATALOG_APP_PASSWORD}';
  END \$\$;
  SELECT 'CREATE DATABASE gc_catalog OWNER gc_catalog_owner'
   WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'gc_catalog') \gexec
  REVOKE ALL ON DATABASE gc_catalog FROM PUBLIC;
  GRANT CONNECT ON DATABASE gc_catalog TO gc_catalog_app;
  GRANT CONNECT ON DATABASE gc_catalog TO gc_cdc;
SQL

# Objects created later by the owner role are usable (DML) by the app role; migrations REVOKE what must stay closed.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname gc_catalog <<-SQL
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
  ALTER DEFAULT PRIVILEGES FOR ROLE gc_catalog_owner GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO gc_catalog_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE gc_catalog_owner GRANT USAGE, SELECT ON SEQUENCES TO gc_catalog_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE gc_catalog_owner GRANT EXECUTE ON FUNCTIONS TO gc_catalog_app;
SQL
