#!/usr/bin/env bash
# One-off for a stack created before grower-service (SPEC-GRW-01): init scripts and the realm import only run on an
# empty volume / a new realm. Idempotent. Recreate the postgres container first so it gets the new passwords:
#   docker compose up -d --wait && ./apply-grower-service.sh
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a

# 1. database gc_grower + roles (same script as on a fresh volume)
MSYS_NO_PATHCONV=1 docker exec gc-postgres sh /docker-entrypoint-initdb.d/03-grower-db.sh
echo "gc_grower database ready"

# 2. Keycloak client "grower-service" (service-to-service), taken from the realm file
KCADM=/opt/keycloak/bin/kcadm.sh
# Keycloak may briefly refuse the admin login right after postgres was recreated (seen: unauthorized_client); retry.
for attempt in 1 2 3 4 5 6; do
  MSYS_NO_PATHCONV=1 docker exec gc-keycloak $KCADM config credentials --server http://localhost:8180 --realm master \
    --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1 && break
  [[ $attempt == 6 ]] && { echo "keycloak admin login failed" >&2; exit 1; }
  sleep 5
done
if MSYS_NO_PATHCONV=1 docker exec gc-keycloak $KCADM get clients -r growercare -q clientId=grower-service --fields id | grep -q '"id"'; then
  echo "keycloak client grower-service exists"
else
  python -c "import json; c=[c for c in json.load(open('keycloak/growercare-realm.json'))['clients'] if c['clientId']=='grower-service'][0]; print(json.dumps(c))" \
    | MSYS_NO_PATHCONV=1 docker exec -i gc-keycloak $KCADM create clients -r growercare -f - >/dev/null
  echo "keycloak client grower-service created"
fi
