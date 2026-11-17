#!/usr/bin/env bash
# SPEC-IAM-03 D1 (growercare-identity-access-service): growers sign up on Keycloak's own registration page with their
# mobile number as username. Idempotent; run after `docker compose up -d --wait` (fresh or existing realm):
#   ./keycloak/configure-registration.sh
# - registration on (the realm's existing password policy applies), email and names optional;
# - the username must be a phone number in E.164 (+<country code><number>).
# Registration stays OFF in the realm file: it is switched on only here, together with the phone-number validator,
# so a stack that skips this script never offers an open sign-up that accepts any username. The user profile is one
# JSON document in Keycloak, patched here rather than replaced.
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


kc get users/profile -r growercare < /dev/null | "$PY" -c '
import json, sys
profile = json.load(sys.stdin)
if not any(a["name"] == "username" for a in profile["attributes"]):
    sys.exit("the realm user profile has no username attribute: refusing to enable registration")
for attribute in profile["attributes"]:
    if attribute["name"] == "username":
        attribute.setdefault("validations", {})["pattern"] = {
            "pattern": "^\\+[1-9][0-9]{7,14}$",
            "error-message": "Use your mobile number with the country code, for example +919876543210"}
    if attribute["name"] in ("email", "firstName", "lastName"):
        attribute.pop("required", None)            # sign-up needs the phone and a password only
print(json.dumps(profile))
' | kc update users/profile -r growercare -f -

# Only now, with the validator in place, is registration switched on (set -e: any failure above leaves it off).
# the realm's own password policy (growercare-realm.json) is kept: it is stricter than SPEC-IAM-03 D1 asks for
kc update realms/growercare -s registrationAllowed=true -s registrationEmailAsUsername=false \
  -s loginWithEmailAllowed=false < /dev/null

echo "registration on; usernames must be phone numbers (E.164)"
