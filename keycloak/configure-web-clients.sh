#!/usr/bin/env bash
# SPEC-FE-01 D3 (growercare-frontend): one public PKCE client per web app, each only with its own redirect URIs and the
# gc-api audience. The realm file has them for fresh stacks; Keycloak keeps an existing realm in Postgres, so this
# idempotent script brings an existing realm to the same state:   ./keycloak/configure-web-clients.sh
#   grower-web     http://localhost:5173   (the former shared client gc-web is removed)
#   staff-console  http://localhost:5174
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

DOCKER=${DOCKER:-docker}
command -v "$DOCKER" > /dev/null || DOCKER="${LOCALAPPDATA:-}/Programs/DockerDesktop/resources/bin/docker.exe"   # Windows
KCADM=/opt/keycloak/bin/kcadm.sh
kc() { MSYS_NO_PATHCONV=1 "$DOCKER" exec -i gc-keycloak "$KCADM" "$@"; }
PY=${PY:-python}

for attempt in 1 2 3 4 5 6; do
  kc config credentials --server http://localhost:8180 --realm master \
    --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" < /dev/null > /dev/null 2>&1 && break
  [[ $attempt == 6 ]] && { echo "keycloak admin login failed" >&2; exit 1; }
  sleep 5
done

# the client definitions come from the realm file, so fresh and existing stacks end up identical
for client in grower-web staff-console; do
  "$PY" -c 'import json,sys; print(json.dumps(next(c for c in json.load(open(sys.argv[1], encoding="utf-8"))["clients"] if c["clientId"] == sys.argv[2])))' \
    keycloak/growercare-realm.json "$client" > "/tmp/gc-client-$client.json"
  id=$(kc get clients -r growercare -q clientId="$client" --fields id --format csv --noquotes < /dev/null | tr -d '\r')
  if [[ -z "$id" ]]; then
    kc create clients -r growercare -f - < "/tmp/gc-client-$client.json" > /dev/null && echo "created $client"
  else
    kc update "clients/$id" -r growercare -f - < "/tmp/gc-client-$client.json" && echo "updated $client"
  fi
done
old=$(kc get clients -r growercare -q clientId=gc-web --fields id --format csv --noquotes < /dev/null | tr -d '\r')
[[ -n "$old" ]] && kc delete "clients/$old" -r growercare < /dev/null && echo "removed gc-web"
echo "web clients ready"
