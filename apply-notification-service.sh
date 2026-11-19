#!/usr/bin/env bash
# One-off for a stack created before notification-service (SPEC-NOT-01): init scripts only run on an empty volume.
# Idempotent. Recreate the postgres container first so it gets the new passwords:
#   docker compose up -d --wait && ./apply-notification-service.sh
# SPEC-NOT-02 adds the Keycloak client "notification-service" (it reads contacts from grower-service and IAM).
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a

# 1. database gc_notification + roles (same script as on a fresh volume)
MSYS_NO_PATHCONV=1 docker exec gc-postgres sh /docker-entrypoint-initdb.d/04-notification-db.sh
echo "gc_notification database ready"

# 2. Keycloak client "notification-service" (service-to-service), taken from the realm file
KCADM=/opt/keycloak/bin/kcadm.sh
for attempt in 1 2 3 4 5 6; do
  MSYS_NO_PATHCONV=1 docker exec gc-keycloak $KCADM config credentials --server http://localhost:8180 --realm master \
    --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1 && break
  [[ $attempt == 6 ]] && { echo "keycloak admin login failed" >&2; exit 1; }
  sleep 5
done
if MSYS_NO_PATHCONV=1 docker exec gc-keycloak $KCADM get clients -r growercare -q clientId=notification-service --fields id | grep -q '"id"'; then
  echo "keycloak client notification-service exists"
else
  python -c "import json; c=[c for c in json.load(open('keycloak/growercare-realm.json', encoding='utf-8'))['clients'] if c['clientId']=='notification-service'][0]; print(json.dumps(c))" \
    | MSYS_NO_PATHCONV=1 docker exec -i gc-keycloak $KCADM create clients -r growercare -f - >/dev/null
  echo "keycloak client notification-service created"
fi
