#!/usr/bin/env bash
# One-off for a data volume created before SPEC-PLAT-04: init scripts only run on an empty volume.
# Recreate the postgres container first so it gets GC_CDC_PASSWORD:  docker compose up -d --wait
set -euo pipefail
MSYS_NO_PATHCONV=1 docker exec gc-postgres sh /docker-entrypoint-initdb.d/02-cdc-role.sh   # no path rewrite on Git Bash
echo "gc_cdc role ready"
