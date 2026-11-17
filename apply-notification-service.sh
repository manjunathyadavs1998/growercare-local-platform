#!/usr/bin/env bash
# One-off for a stack created before notification-service (SPEC-NOT-01): init scripts only run on an empty volume.
# Idempotent. Recreate the postgres container first so it gets the new passwords:
#   docker compose up -d --wait && ./apply-notification-service.sh
# No Keycloak change: notification-service only validates tokens, and grower-service calls it with its existing client.
set -euo pipefail
cd "$(dirname "$0")"
MSYS_NO_PATHCONV=1 docker exec gc-postgres sh /docker-entrypoint-initdb.d/04-notification-db.sh
echo "gc_notification database ready"
