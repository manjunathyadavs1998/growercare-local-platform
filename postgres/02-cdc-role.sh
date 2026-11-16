#!/bin/sh
# SPEC-PLAT-04 D8: the Debezium login role. Runs on first start of an empty volume (after 01-init.sh); for an
# existing volume run ./apply-cdc-role.sh. Idempotent. Table-level grants come from the Flyway migrations
# (placeholder cdc_role): SELECT on outbox tables and write access to the heartbeat table only.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
  DO \$\$ BEGIN
    CREATE ROLE gc_cdc LOGIN REPLICATION PASSWORD '${GC_CDC_PASSWORD}';
  EXCEPTION WHEN duplicate_object THEN
    ALTER ROLE gc_cdc LOGIN REPLICATION PASSWORD '${GC_CDC_PASSWORD}';
  END \$\$;
  GRANT CONNECT ON DATABASE gc_iam  TO gc_cdc;
  GRANT CONNECT ON DATABASE gc_case TO gc_cdc;
SQL
