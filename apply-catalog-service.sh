#!/usr/bin/env bash
# One-off for a stack created before catalog-registry-service (SPEC-CAT-01): init scripts and the realm import only run
# on an empty volume / a new realm. Idempotent. Recreate the postgres container first so it gets the new passwords:
#   docker compose up -d --wait && ./apply-catalog-service.sh
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a

# 1. database gc_catalog + roles (same script as on a fresh volume)
MSYS_NO_PATHCONV=1 docker exec gc-postgres sh /docker-entrypoint-initdb.d/05-catalog-db.sh
echo "gc_catalog database ready"

# 2. Keycloak clients "catalog-registry-service" (calls IAM) and "erp-sync" (catalog import), taken from the realm file
KCADM=/opt/keycloak/bin/kcadm.sh
for attempt in 1 2 3 4 5 6; do
  MSYS_NO_PATHCONV=1 docker exec gc-keycloak $KCADM config credentials --server http://localhost:8180 --realm master \
    --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1 && break
  [[ $attempt == 6 ]] && { echo "keycloak admin login failed" >&2; exit 1; }
  sleep 5
done
for client in catalog-registry-service erp-sync; do
  if MSYS_NO_PATHCONV=1 docker exec gc-keycloak $KCADM get clients -r growercare -q clientId=$client --fields id | grep -q '"id"'; then
    echo "keycloak client $client exists"
  else
    python -c "import json,sys; c=[c for c in json.load(open('keycloak/growercare-realm.json'))['clients'] if c['clientId']==sys.argv[1]][0]; print(json.dumps(c))" "$client" \
      | MSYS_NO_PATHCONV=1 docker exec -i gc-keycloak $KCADM create clients -r growercare -f - >/dev/null
    echo "keycloak client $client created"
  fi
done
