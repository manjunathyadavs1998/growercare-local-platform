#!/bin/sh
# SPEC-NOT-01 (growercare-notification-service): database gc_notification with its owner/app roles, the same split as 01-init.sh.
# Runs on first start of an empty volume (after 01–03); for an existing volume run ./apply-notification-service.sh.
# Idempotent: roles and database are created only when missing.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
  DO \$\$ BEGIN
    CREATE ROLE gc_notification_owner LOGIN PASSWORD '${GC_NOTIFICATION_OWNER_PASSWORD}';
  EXCEPTION WHEN duplicate_object THEN
    ALTER ROLE gc_notification_owner LOGIN PASSWORD '${GC_NOTIFICATION_OWNER_PASSWORD}';
  END \$\$;
  DO \$\$ BEGIN
    CREATE ROLE gc_notification_app LOGIN PASSWORD '${GC_NOTIFICATION_APP_PASSWORD}';
  EXCEPTION WHEN duplicate_object THEN
    ALTER ROLE gc_notification_app LOGIN PASSWORD '${GC_NOTIFICATION_APP_PASSWORD}';
  END \$\$;
  SELECT 'CREATE DATABASE gc_notification OWNER gc_notification_owner'
   WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'gc_notification') \gexec
  REVOKE ALL ON DATABASE gc_notification FROM PUBLIC;
  GRANT CONNECT ON DATABASE gc_notification TO gc_notification_app;
SQL

# Objects created later by the owner role are usable (DML) by the app role; migrations REVOKE what must stay closed.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname gc_notification <<-SQL
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
  ALTER DEFAULT PRIVILEGES FOR ROLE gc_notification_owner GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO gc_notification_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE gc_notification_owner GRANT USAGE, SELECT ON SEQUENCES TO gc_notification_app;
  ALTER DEFAULT PRIVILEGES FOR ROLE gc_notification_owner GRANT EXECUTE ON FUNCTIONS TO gc_notification_app;
SQL
