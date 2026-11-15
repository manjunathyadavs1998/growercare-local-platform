#!/bin/sh
# Runs once, on first start of an empty data volume (docker-entrypoint-initdb.d).
# Creates one database per service plus two roles each:
#   <svc>_owner : owns the schema objects, used ONLY by Flyway migrations (DDL)
#   <svc>_app   : runtime role used by the service — DML only, cannot create/alter/drop
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
  CREATE ROLE gc_iam_owner  LOGIN PASSWORD '${GC_IAM_OWNER_PASSWORD}';
  CREATE ROLE gc_iam_app    LOGIN PASSWORD '${GC_IAM_APP_PASSWORD}';
  CREATE ROLE gc_case_owner LOGIN PASSWORD '${GC_CASE_OWNER_PASSWORD}';
  CREATE ROLE gc_case_app   LOGIN PASSWORD '${GC_CASE_APP_PASSWORD}';
  CREATE ROLE keycloak      LOGIN PASSWORD '${KEYCLOAK_DB_PASSWORD}';

  CREATE DATABASE gc_iam   OWNER gc_iam_owner;
  CREATE DATABASE gc_case  OWNER gc_case_owner;
  CREATE DATABASE keycloak OWNER keycloak;

  REVOKE ALL ON DATABASE gc_iam  FROM PUBLIC;
  REVOKE ALL ON DATABASE gc_case FROM PUBLIC;
  GRANT CONNECT ON DATABASE gc_iam  TO gc_iam_app;
  GRANT CONNECT ON DATABASE gc_case TO gc_case_app;
SQL

# Objects created later by the owner role are automatically usable (DML only) by the app role.
for pair in "gc_iam:gc_iam_owner:gc_iam_app" "gc_case:gc_case_owner:gc_case_app"; do
  db=$(echo "$pair" | cut -d: -f1); owner=$(echo "$pair" | cut -d: -f2); app=$(echo "$pair" | cut -d: -f3)
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-SQL
    REVOKE CREATE ON SCHEMA public FROM PUBLIC;
    ALTER DEFAULT PRIVILEGES FOR ROLE ${owner} GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${app};
    ALTER DEFAULT PRIVILEGES FOR ROLE ${owner} GRANT USAGE, SELECT ON SEQUENCES TO ${app};
    ALTER DEFAULT PRIVILEGES FOR ROLE ${owner} GRANT EXECUTE ON FUNCTIONS TO ${app};
SQL
done
