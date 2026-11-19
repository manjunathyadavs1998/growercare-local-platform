#!/usr/bin/env bash
# SPEC-PLAT-01 R10: end-to-end smoke test against the real local stack
# (Docker: Postgres, Redis, Keycloak + identity-access-service :8081 + case-service :8082 + grower-service :8084
#  + notification-service :8085 with the dev mailbox + catalog-registry-service :8086).
# Real Keycloak tokens (client gc-dev-cli). Prints a PASS/FAIL table; exit code = number of failed checks.
set -uo pipefail

KC=${KC:-http://localhost:8180/realms/growercare}
IAM=${IAM:-http://localhost:8081}
CASE=${CASE:-http://localhost:8082}
GROWER=${GROWER:-http://localhost:8084}
NOTIFY=${NOTIFY:-http://localhost:8085}
CATALOG=${CATALOG:-http://localhost:8086}
GW=${GW:-http://localhost:8080}
PY=${PY:-python}
export PYTHONIOENCODING=utf-8                  # message bodies are Marathi/Hindi: read and print UTF-8, not the Windows code page
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0
ROWS=()

json() { "$PY" -c "import sys,json; d=json.load(open(sys.argv[1], encoding='utf-8')); v=eval('d'+sys.argv[2]); print('' if v is None else v)" "$1" "$2" 2>/dev/null; }

token() { # user password
  curl -fsS -X POST "$KC/protocol/openid-connect/token" -d grant_type=password -d client_id=gc-dev-cli \
       --data-urlencode "username=$1" --data-urlencode "password=$2" -o "$TMP/tok.json" || { echo "token for $1 failed" >&2; return 1; }
  json "$TMP/tok.json" "['access_token']"
}

# call METHOD URL TOKEN [BODY] [extra curl args...] → sets $STATUS, body in $TMP/body, headers in $TMP/headers
call() {
  local method=$1 url=$2 tok=$3 body=${4:-}; shift 4 2>/dev/null || shift $#
  local args=(-s -X "$method" "$url" -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}')
  [[ -n "$tok" ]] && args+=(-H "Authorization: Bearer $tok")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data "$body")
  STATUS=$(curl "${args[@]}" "$@")
}

check() { # id description condition-result(0/1)
  if [[ "$3" == 0 ]]; then ROWS+=("PASS  $1  $2"); else ROWS+=("FAIL  $1  $2  (status=$STATUS body=$(head -c 300 "$TMP/body" 2>/dev/null))"); FAILED=$((FAILED + 1)); fi
}

header() { grep -i "^$1:" "$TMP/headers" | head -1 | cut -d' ' -f2- | tr -d '\r'; }

# Sections (SPEC-PLAT-06): run what the started compose profiles cover. Default: everything.
#   core    IAM + case: auth, lifecycle, isolation, attachments, errors     (always-on containers)
#   events  outbox → Debezium → Kafka, principal-cache eviction            (profile events)
#   grower  grower registry, PRD J2 with OTP via notification-service      (profile grower)
#   catalog PRD J3 farms + J4 catalog complaint                            (profiles grower + catalog)
#   gateway PRD J5/J6/J8/J9 through the edge gateway :8080                  (profiles grower + gateway)
#   notify  PRD J7: case events → messages in the dev mailbox (SPEC-NOT-02) (profiles events + grower)
#   web     the apps' nginx images :5173/:5174 + object-store CORS (FE-04) (profiles gateway + web)
SECTIONS=" ${*:-core events grower catalog gateway notify web} "
want() { [[ "$SECTIONS" == *" $1 "* ]]; }
for s in $SECTIONS; do
  [[ " core events grower catalog gateway notify web " == *" $s "* ]] || { echo "unknown section: $s (core events grower catalog gateway notify web)" >&2; exit 2; }
done
want core || { echo "section core is required (tokens, the case later checks use)" >&2; exit 2; }
if want catalog && ! want grower; then echo "section catalog needs grower (farms live in grower-service)" >&2; exit 2; fi
if want gateway && ! want grower; then echo "section gateway needs grower (J5 finds the grower by phone)" >&2; exit 2; fi
if want notify && ! { want grower && want events; }; then echo "section notify needs grower and events (case events reach notification-service through Debezium)" >&2; exit 2; fi
if want web && ! want gateway; then echo "section web needs gateway (the apps proxy /api to it)" >&2; exit 2; fi

echo "== GrowerCare smoke test:${SECTIONS}=="

# ---------------------------------------------------------------- S01 health
TARGETS=("$IAM/actuator/health" "$CASE/actuator/health" "http://localhost:8180/realms/growercare")
want grower && TARGETS+=("$GROWER/actuator/health" "$NOTIFY/actuator/health")
want catalog && TARGETS+=("$CATALOG/actuator/health")
want gateway && TARGETS+=("$GW/actuator/health")
want web && TARGETS+=("http://localhost:5173/config.json" "http://localhost:5174/config.json")
for target in "${TARGETS[@]}"; do
  STATUS=$(curl -s -o "$TMP/body" -w '%{http_code}' "$target")
  check PLAT-S01 "reachable: $target" "$([[ $STATUS == 200 ]]; echo $?)"
done

T_GROWER=$(token grower.in1 'Grower#Pass1')
T_CARE=$(token care.in 'Staff#Pass12')
T_CARE_BR=$(token care.br 'Staff#Pass12')
T_TM=$(token tm.in 'Staff#Pass12')
T_AGRO=$(token agro.in 'Staff#Pass12')
T_RET=$(token retailer.in 'Partner#Pass1')
T_RET2=$(token retailer2.in 'Partner#Pass1')

# ---------------------------------------------------------------- S00 warm-up (cold JVMs after a fresh start)
# The first authenticated call goes case-service → Keycloak (client token) → IAM (principal). On cold containers it can
# exceed the 2 s IAM read timeout and fail closed with 503 (SPEC-CASE-01 R9a); production gets traffic only when warm.
WARM=""
for _ in $(seq 1 30); do
  call GET "$CASE/cases?limit=1" "$T_GROWER"
  [[ $STATUS == 200 ]] && { WARM=yes; break; }
  sleep 2
done
check PLAT-S00 "services warm: an authenticated call through IAM succeeds within 60 s (503 while cold, never 500)" "$([[ -n "$WARM" ]]; echo $?)"

# ---------------------------------------------------------------- S02 IAM /me
call GET "$IAM/me" "$T_CARE"
check PLAT-S02 "IAM /me as care.in → CARE_AGENT" "$([[ $STATUS == 200 && $(json "$TMP/body" "['grants'][0]['roleCode']") == CARE_AGENT ]]; echo $?)"

# ---------------------------------------------------------------- S03/S04 create + idempotent replay
KEY=$("$PY" -c "import uuid; print(uuid.uuid4())")
# SPEC-CASE-06 E152a: G1 by its grower-service id (the case replica's seed follows grower-service, D6)
G1=110165911145454593
BODY='{"growerId":"'$G1'","caseType":"PRODUCT_COMPLAINT","title":"Smoke: leaves yellowing","description":"Spots after spray (smoke test)","farmId":"80011","productId":"9001","batchNo":"AZX2604-117"}'
call POST "$CASE/cases" "$T_GROWER" "$BODY" -H "Idempotency-Key: $KEY"
CASE_ID=$(json "$TMP/body" "['caseId']"); CASE_NO=$(json "$TMP/body" "['caseNo']")
check PLAT-S03 "grower.in1 creates a case (via IAM client-credentials) → 201, case_no 71-…" "$([[ $STATUS == 201 && $CASE_NO == 71-* ]]; echo $?)"
call POST "$CASE/cases" "$T_GROWER" "$BODY" -H "Idempotency-Key: $KEY"
check PLAT-S04 "same Idempotency-Key replays → 200 + Idempotent-Replayed" "$([[ $STATUS == 200 && $(header Idempotent-Replayed) == true && $(json "$TMP/body" "['caseId']") == "$CASE_ID" ]]; echo $?)"

# ---------------------------------------------------------------- S05/S06 read + isolation
call GET "$CASE/cases/$CASE_ID" "$T_CARE"
check PLAT-S05 "care.in reads it, grower name masked" "$([[ $STATUS == 200 && $(json "$TMP/body" "['growerName']") == 'R***** P****' ]]; echo $?)"
call GET "$CASE/cases/$CASE_ID" "$T_CARE_BR"
check PLAT-S06 "care.br (Brazil) cannot see it → 404" "$([[ $STATUS == 404 ]]; echo $?)"

# ---------------------------------------------------------------- S07 transition + optimistic lock
call POST "$CASE/cases/$CASE_ID/transitions" "$T_CARE" '{"toStatus":"TRIAGED","note":"smoke triage"}' -H 'If-Match: "0"'
check PLAT-S07a "care.in triages with If-Match \"0\" → 200, ETag \"1\"" "$([[ $STATUS == 200 && $(header ETag) == '"1"' ]]; echo $?)"
call POST "$CASE/cases/$CASE_ID/transitions" "$T_CARE" '{"toStatus":"NEED_INFO"}' -H 'If-Match: "0"'
check PLAT-S07b "stale If-Match → 412" "$([[ $STATUS == 412 ]]; echo $?)"

# ---------------------------------------------------------------- S08/S09 assignment (IAM by-id lookup)
call PUT "$CASE/cases/$CASE_ID/assignee" "$T_TM" '{"assigneeUserId":"102"}' -H 'If-Match: "1"'
check PLAT-S08 "tm.in assigns to agronomist 102 → 200" "$([[ $STATUS == 200 && $(json "$TMP/body" "['assigneeUserId']") == 102 ]]; echo $?)"
call GET "$CASE/cases?assignedToMe=true&limit=100" "$T_AGRO"
check PLAT-S09 "agro.in sees it in assignedToMe" "$([[ $STATUS == 200 && $(json "$TMP/body" "['items']" | grep -c "$CASE_ID") -ge 1 ]]; echo $?)"

# ---------------------------------------------------------------- S10 comment + share
MSG=$("$PY" -c "import uuid; print(uuid.uuid4())")
call POST "$CASE/cases/$CASE_ID/comments" "$T_GROWER" "{\"clientMsgId\":\"$MSG\",\"visibility\":\"PUBLIC\",\"body\":\"Photos attached (smoke)\"}"
check PLAT-S10a "grower comments PUBLIC → 201" "$([[ $STATUS == 201 ]]; echo $?)"
call PUT "$CASE/cases/$CASE_ID/shares/502" "$T_GROWER"
check PLAT-S10b "grower shares with retailer 502 → 200" "$([[ $STATUS == 200 ]]; echo $?)"
call GET "$CASE/cases/$CASE_ID" "$T_RET2"
check PLAT-S10c "retailer2.in can now read it" "$([[ $STATUS == 200 ]]; echo $?)"

# ---------------------------------------------------------------- SPEC-CASE-05: attachment upload → scan → download
# Bytes go straight to SeaweedFS through the presigned URL; the scheduled scan job (every 10 s) publishes them.
printf '%%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\n%%%%EOF\n' > "$TMP/evidence.pdf"
read -r SIZE SHA < <("$PY" -c "import hashlib,os,sys; b=open(sys.argv[1],'rb').read(); print(len(b), hashlib.sha256(b).hexdigest())" "$TMP/evidence.pdf" | tr -d '\r')
call POST "$CASE/cases/$CASE_ID/attachments" "$T_GROWER" "{\"kind\":\"INVOICE\",\"contentType\":\"application/pdf\",\"sizeBytes\":$SIZE,\"sha256\":\"$SHA\"}"
ATT_ID=$(json "$TMP/body" "['attachmentId']")
UPLOAD_URL=$(json "$TMP/body" "['upload']['url']")
mapfile -t UPLOAD_HEADERS < <("$PY" -c "import json,sys; [print(f'{k}: {v}') for k,v in json.load(open(sys.argv[1]))['upload']['headers'].items()]" "$TMP/body" | tr -d '\r')
HDR_ARGS=(); for h in "${UPLOAD_HEADERS[@]}"; do HDR_ARGS+=(-H "$h"); done
PUT_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${HDR_ARGS[@]}" --data-binary @"$TMP/evidence.pdf" "$UPLOAD_URL")
call POST "$CASE/cases/$CASE_ID/attachments/$ATT_ID/complete" "$T_GROWER"
check CASE-S12a "grower uploads an invoice via presigned PUT and completes → PENDING" \
  "$([[ -n "$ATT_ID" && $PUT_STATUS == 200 && $STATUS == 200 && $(json "$TMP/body" "['status']") == PENDING ]]; echo $?)"
ATT_STATUS=""
for _ in $(seq 1 30); do
  call GET "$CASE/cases/$CASE_ID/attachments" "$T_GROWER"
  ATT_STATUS=$("$PY" -c "import json,sys; print(next((a['status'] for a in json.load(open(sys.argv[1]))['items'] if a['attachmentId']==sys.argv[2]), ''))" "$TMP/body" "$ATT_ID" | tr -d '\r')
  [[ "$ATT_STATUS" == PENDING ]] || break
  sleep 2
done
check CASE-S12b "scan job marks it CLEAN within 60 s" "$([[ "$ATT_STATUS" == CLEAN ]]; echo $?)"
call GET "$CASE/cases/$CASE_ID/attachments/$ATT_ID/download" "$T_RET2"
DL_URL=$(json "$TMP/body" "['url']")
DL_STATUS=$(curl -s -o "$TMP/downloaded.pdf" -w '%{http_code}' "$DL_URL")
check CASE-S12c "retailer2 (case shared) downloads the identical file via presigned GET" \
  "$([[ $DL_STATUS == 200 ]] && cmp -s "$TMP/evidence.pdf" "$TMP/downloaded.pdf"; echo $?)"

# ---------------------------------------------------------------- SPEC-PLAT-05: errors are always problem+json
call GET "$CASE/cases/$CASE_ID/attachments//download" "$T_GROWER"          # an empty id, as a buggy client sends
check PLAT-E86 "empty path segment (real Tomcat + firewall) → 400 problem+json, not the Boot error page"   "$([[ $STATUS == 400 && $(header Content-Type) == application/problem+json* && $(json "$TMP/body" "['errors'][0]['field']") == path ]]; echo $?)"

# ---------------------------------------------------------------- SPEC-PLAT-04: events through Debezium + Kafka
# Needs the kafka + connect containers and ./debezium/register.sh. Reads topics with the broker's console consumer.
DOCKER=${DOCKER:-docker}
command -v "$DOCKER" > /dev/null || DOCKER="${LOCALAPPDATA:-}/Programs/DockerDesktop/resources/bin/docker.exe"
dexec() { MSYS_NO_PATHCONV=1 "$DOCKER" exec "$@"; }   # Git Bash: keep container paths (/opt/kafka) unconverted
ENV_FILE="$(dirname "$0")/.env"
REDIS_PW=${REDIS_PASSWORD:-$(grep '^REDIS_PASSWORD=' "$ENV_FILE" | cut -d= -f2 | tr -d '\r')}

topic_lines() { # topic → one line per record: headers | key | value
  dexec gc-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic "$1" \
    --from-beginning --timeout-ms 6000 --property print.key=true --property print.headers=true \
    --property key.separator=' | ' 2>/dev/null
}
await_topic() { # topic grep-pattern → sets $LINES (matching records, retried for ~20 s)
  for _ in 1 2 3; do LINES=$(topic_lines "$1" | grep -- "$2"); [[ -n "$LINES" ]] && return 0; done; return 1
}
cached() { # subject → 1 when case-service has the principal in Redis
  dexec gc-redis redis-cli -a "$REDIS_PW" --no-auth-warning EXISTS "gc:principal:$1" | tr -d '\r'
}
await_evicted() { # subject → 0 once evicted within 10 s
  for _ in $(seq 1 20); do [[ $(cached "$1") == 0 ]] && return 0; sleep 0.5; done; return 1
}

if want events; then
await_topic case.case.events "$CASE_ID"
TYPES=$(echo "$LINES" | grep -o 'eventType:[a-z._]*' | head -2 | tr '\n' ' ')
check PLAT-E72 "case.case.events: case.created then case.routed, key = caseId" \
  "$([[ "$TYPES" == "eventType:case.created eventType:case.routed " ]]; echo $?)"

T_ADMIN=$(token admin.in 'Staff#Pass12')
CARE_SUB=6f1c0a10-0101-4a00-8000-000000000101          # care.in (user 101)
call GET "$CASE/cases?limit=1" "$T_CARE"                  # caches care.in's principal
call POST "$IAM/grants" "$T_ADMIN" '{"userId":"101","roleCode":"QUALITY_INVESTIGATOR","countryCodes":["IN"],"buCodes":["CP"],"reason":"Smoke: event flow"}'
GRANT_ID=$(json "$TMP/body" "['grantId']")
await_topic iam.grant.events " | $GRANT_ID | "
check PLAT-E71 "iam.grant.events: grant $GRANT_ID, key = grantId, header eventType=iam.grant.created" \
  "$([[ -n "$GRANT_ID" && "$LINES" == *eventType:iam.grant.created* ]]; echo $?)"
check PLAT-E74a "grant created → care.in's cached principal evicted within 10 s" "$(await_evicted "$CARE_SUB"; echo $?)"

call GET "$CASE/cases?limit=1" "$T_CARE"                  # cached again
call DELETE "$IAM/grants/$GRANT_ID?reason=Smoke%20done" "$T_ADMIN"
check PLAT-E74b "grant revoked → evicted again within 10 s (no 5-minute TTL wait)" \
  "$([[ $STATUS == 200 ]] && await_evicted "$CARE_SUB"; echo $?)"
fi   # events

if want grower; then
# ---------------------------------------------------------------- SPEC-GRW-01: grower-service (registry, phone search, events)
call POST "$GROWER/growers/search" "$T_CARE" '{"phone":"+919876543210","countryCode":"IN"}'
check GRW-E60 "care.in finds G1 by phone (POST body, name masked)" \
  "$([[ $STATUS == 200 && $(json "$TMP/body" "['items'][0]['displayName']") == 'R***** P****' ]]; echo $?)"

PHONE="+919$("$PY" -c "import random; print(random.randint(100000000, 999999999))")"     # fresh per run
GKEY=$("$PY" -c "import uuid; print(uuid.uuid4())")
GBODY="{\"territoryId\":\"1002\",\"displayName\":\"Smoke Grower\",\"phone\":\"$PHONE\",\"preferredLanguage\":\"mr\"}"
call POST "$GROWER/growers" "$T_CARE" "$GBODY" -H "Idempotency-Key: $GKEY"
GROWER_ID=$(json "$TMP/body" "['growerId']")
check GRW-E21 "care.in registers an assisted grower → 201 PENDING_CONSENT" \
  "$([[ $STATUS == 201 && $(json "$TMP/body" "['status']") == PENDING_CONSENT ]]; echo $?)"
# SPEC-CASE-06 E152b: case-service learns the new grower across services (event or read-through) and respects consent
CKEY=$("$PY" -c "import uuid; print(uuid.uuid4())")
call POST "$CASE/cases" "$T_CARE" "{\"growerId\":\"$GROWER_ID\",\"caseType\":\"AGRONOMY_ADVICE\",\"title\":\"Smoke: pending grower\",\"description\":\"Should wait for consent\",\"buCode\":\"CP\"}" -H "Idempotency-Key: $CKEY"
check CASE-E152b "case for the new assisted grower (PENDING_CONSENT) → 422 case.grower-not-active"   "$([[ $STATUS == 422 && $(json "$TMP/body" "['rule']") == case.grower-not-active ]]; echo $?)"

call POST "$GROWER/growers" "$T_CARE" "$GBODY" -H "Idempotency-Key: $GKEY"
check GRW-E30 "same Idempotency-Key replays → 200 + Idempotent-Replayed" \
  "$([[ $STATUS == 200 && $(header Idempotent-Replayed) == true && $(json "$TMP/body" "['growerId']") == "$GROWER_ID" ]]; echo $?)"

call GET "$GROWER/growers/$GROWER_ID" "$T_TM"
check GRW-E42 "tm.in reads it with the full name (FULL clearance), no phone field" \
  "$([[ $STATUS == 200 && $(json "$TMP/body" "['displayName']") == 'Smoke Grower' && $(header ETag) == '"0"' && $(json "$TMP/body" "['phone']") == '' ]]; echo $?)"
call PATCH "$GROWER/growers/$GROWER_ID" "$T_CARE" '{"preferredLanguage":"hi"}' -H 'If-Match: "0"'
check GRW-E43 "care.in updates the language with If-Match → 200, ETag \"1\"" \
  "$([[ $STATUS == 200 && $(header ETag) == '"1"' ]]; echo $?)"

# case-service's own client secret, from the env file the service itself runs with (never a copy in this script)
CASE_ENV="$(dirname "$0")/services/case-service.env"; [[ -f "$CASE_ENV" ]] || CASE_ENV="$CASE_ENV.example"
CASE_SECRET=$(grep '^IAM_CLIENT_SECRET=' "$CASE_ENV" | cut -d= -f2 | tr -d '\r')
T_CASE_SVC=$(curl -fsS -X POST "$KC/protocol/openid-connect/token" -d grant_type=client_credentials \
  -d client_id=case-service -d client_secret="$CASE_SECRET" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
call GET "$GROWER/internal/growers/$GROWER_ID" "$T_CASE_SVC"
check GRW-E72 "case-service reads the replica view (client credentials): phone only as HMAC + last 4" \
  "$([[ $STATUS == 200 && $(json "$TMP/body" "['phoneLast4']") == "${PHONE: -4}" && -n $(json "$TMP/body" "['phoneHmac']") ]]; echo $?)"

if want events; then
# both events must have arrived: the PATCH ran just before, so grower.updated may still be in flight (outbox → Debezium)
for _ in 1 2 3 4 5; do
  await_topic grower.grower.events " | $GROWER_ID | " && [[ $(echo "$LINES" | grep -c "eventType:grower.updated") -ge 1 ]] && break
done
GTYPES=$(echo "$LINES" | grep -o 'eventType:[a-z._]*' | head -2 | tr '\n' ' ')
check GRW-R55 "grower.grower.events: grower.registered then grower.updated, key = growerId, no phone" \
  "$([[ "$GTYPES" == "eventType:grower.registered eventType:grower.updated " && "$LINES" != *"${PHONE:3}"* ]]; echo $?)"
fi   # events

# ---------------------------------------------------------------- SPEC-GRW-03 + SPEC-NOT-01: PRD J2, assisted onboarding with OTP
PHONE2="+919$("$PY" -c "import random; print(random.randint(100000000, 999999999))")"
call POST "$GROWER/growers" "$T_RET" "{\"territoryId\":\"1002\",\"displayName\":\"Smoke Assisted\",\"phone\":\"$PHONE2\",\"preferredLanguage\":\"mr\"}"   -H "Idempotency-Key: $("$PY" -c "import uuid; print(uuid.uuid4())")"
J2_ID=$(json "$TMP/body" "['growerId']")
check GRW-E100 "retailer.in registers a grower → 201 PENDING_CONSENT" "$([[ $STATUS == 201 && $(json "$TMP/body" "['status']") == PENDING_CONSENT ]]; echo $?)"

call POST "$GROWER/growers/$J2_ID/verifications" "$T_RET" '{"purpose":"ACTIVATION"}'
VID=$(json "$TMP/body" "['verificationId']")
check GRW-E101 "retailer.in starts the verification → 202, last 4 of the phone, no code in the response"   "$([[ $STATUS == 202 && $(json "$TMP/body" "['phoneLast4']") == "${PHONE2: -4}" && $(json "$TMP/body" "['code']") == '' ]]; echo $?)"

# the dev mailbox (local only) is where the grower "receives" the SMS
call GET "$NOTIFY/dev/mailbox?recipient=%2B${PHONE2:1}" ""
OTP=$(json "$TMP/body" "['items'][0]['body']" | grep -oE '[0-9]{6}' | head -1)
check NOT-E8 "the code arrives in the dev mailbox (Marathi text, 6 digits)" "$([[ $STATUS == 200 && ${#OTP} == 6 && $(json "$TMP/body" "['items'][0]['language']") == mr ]]; echo $?)"

call POST "$GROWER/growers/$J2_ID/verifications/$VID/confirm" "$T_RET2"   "{\"code\":\"$OTP\",\"noticeVersion\":\"in-2026-11\",\"language\":\"mr\",\"consents\":[{\"purpose\":\"SERVICE\",\"granted\":true}]}"
check GRW-E102 "retailer2.in (other partner) cannot confirm it → 404" "$([[ $STATUS == 404 ]]; echo $?)"

call POST "$GROWER/growers/$J2_ID/verifications/$VID/confirm" "$T_RET"   "{\"code\":\"$OTP\",\"noticeVersion\":\"in-2026-11\",\"language\":\"mr\",\"consents\":[{\"purpose\":\"SERVICE\",\"granted\":true},{\"purpose\":\"MARKETING\",\"granted\":false}]}"
check GRW-E107 "retailer.in confirms the code the grower read out → 200 ACTIVE" "$([[ $STATUS == 200 && $(json "$TMP/body" "['status']") == ACTIVE ]]; echo $?)"

call GET "$GROWER/growers/$J2_ID/consents" "$T_CARE"
CONSENTS=$(json "$TMP/body" "['items']")     # ordered by purpose: MARKETING, SERVICE
check GRW-E120 "care.in reads the consents: SERVICE granted, ASSISTED by retailer.in (201)"   "$([[ $STATUS == 200 && $CONSENTS == *"'purpose': 'SERVICE', 'granted': True"*"'channel': 'ASSISTED', 'recordedByUserId': '201'"* ]]; echo $?)"

# PRD J2: a case is accepted only after confirmation; case-service learns it from grower.updated (outbox → Debezium)
if want events; then
J2_CASE=""
for _ in $(seq 1 20); do
  call POST "$CASE/cases" "$T_CARE" "{\"growerId\":\"$J2_ID\",\"caseType\":\"AGRONOMY_ADVICE\",\"title\":\"Smoke: activated grower\",\"description\":\"Accepted after consent\",\"buCode\":\"CP\"}"     -H "Idempotency-Key: $("$PY" -c "import uuid; print(uuid.uuid4())")"
  [[ $STATUS == 201 ]] && { J2_CASE=$(json "$TMP/body" "['caseId']"); break; }
  [[ $STATUS == 422 ]] || break
  sleep 1
done
check GRW-E133 "after confirmation case-service accepts a case for the grower within 20 s (PRD J2)" "$([[ -n "$J2_CASE" ]]; echo $?)"
fi   # events
# ---------------------------------------------------------------- SPEC-IAM-03 + SPEC-GRW-06: PRD J1, a grower signs up on their own
# Keycloak's registration page is a browser form; the admin API creates the same user (phone as username, a password).
ENV_FILE_J1="$(dirname "$0")/.env"
KC_ADMIN=$(grep '^KEYCLOAK_ADMIN=' "$ENV_FILE_J1" | cut -d= -f2 | tr -d '\r')
KC_ADMIN_PW=$(grep '^KEYCLOAK_ADMIN_PASSWORD=' "$ENV_FILE_J1" | cut -d= -f2 | tr -d '\r')
T_KC_ADMIN=$(curl -fsS -X POST "http://localhost:8180/realms/master/protocol/openid-connect/token" -d grant_type=password \
  -d client_id=admin-cli -d "username=$KC_ADMIN" --data-urlencode "password=$KC_ADMIN_PW" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
PHONE3="+919$("$PY" -c "import random; print(random.randint(100000000, 999999999))")"
SIGNUP_PW='Smoke#Pass123'
call POST "http://localhost:8180/admin/realms/growercare/users" "$T_KC_ADMIN" \
  "{\"username\":\"$PHONE3\",\"enabled\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"$SIGNUP_PW\",\"temporary\":false}]}"
T_NEW=$(token "$PHONE3" "$SIGNUP_PW")
call GET "$IAM/me" "$T_NEW"
NO_ACCOUNT=$STATUS
call POST "$IAM/self-registration" "$T_NEW" '{"countryCode":"IN","displayName":"Smoke Self"}'
check IAM-E60 "a new Keycloak user (phone as username) gets a GROWER account on the first call → 201 (before: 401)" \
  "$([[ $NO_ACCOUNT == 401 && $STATUS == 201 && $(json "$TMP/body" "['userType']") == GROWER ]]; echo $?)"

call POST "$GROWER/growers" "$T_NEW" "{\"territoryId\":\"1002\",\"displayName\":\"Smoke Self\",\"phone\":\"$PHONE3\",\"preferredLanguage\":\"mr\"}" \
  -H "Idempotency-Key: $("$PY" -c "import uuid; print(uuid.uuid4())")"
J1_ID=$(json "$TMP/body" "['growerId']")
call GET "$GROWER/growers/me" "$T_NEW"
check GRW-E300 "the new grower registers and finds their grower at /growers/me (PENDING_CONSENT)" \
  "$([[ $STATUS == 200 && -n "$J1_ID" && $(json "$TMP/body" "['growerId']") == "$J1_ID" && $(json "$TMP/body" "['status']") == PENDING_CONSENT ]]; echo $?)"

call GET "$GROWER/consent-notices?country=IN&language=mr" "$T_NEW"
NOTICE=$("$PY" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); print([n['version'] for n in d['items'] if n['purpose'] == 'SERVICE'][0])" "$TMP/body" 2>/dev/null)
check GRW-E302 "the app shows the current SERVICE notice with its text" "$([[ $STATUS == 200 && -n "$NOTICE" ]]; echo $?)"

call POST "$GROWER/growers/$J1_ID/verifications" "$T_NEW" '{"purpose":"ACTIVATION"}'
VID3=$(json "$TMP/body" "['verificationId']")
call GET "$NOTIFY/dev/mailbox?recipient=%2B${PHONE3:1}" ""
OTP3=$(json "$TMP/body" "['items'][0]['body']" | grep -oE '[0-9]{6}' | head -1)
call POST "$GROWER/growers/$J1_ID/verifications/$VID3/confirm" "$T_NEW" \
  "{\"code\":\"$OTP3\",\"noticeVersion\":\"$NOTICE\",\"language\":\"mr\",\"consents\":[{\"purpose\":\"SERVICE\",\"granted\":true}]}"
check GRW-E106 "the grower confirms the code from their phone → ACTIVE, consent SELF" "$([[ $STATUS == 200 && $(json "$TMP/body" "['status']") == ACTIVE ]]; echo $?)"

J1_CASE=""
for _ in $(seq 1 20); do       # with events running, case-service may still hold the PENDING replica for a moment
  call POST "$CASE/cases" "$T_NEW" "{\"growerId\":\"$J1_ID\",\"caseType\":\"AGRONOMY_ADVICE\",\"title\":\"Smoke: my first question\",\"description\":\"Signed up today\",\"buCode\":\"CP\"}" \
    -H "Idempotency-Key: $("$PY" -c "import uuid; print(uuid.uuid4())")"
  [[ $STATUS == 201 ]] && { J1_CASE=$(json "$TMP/body" "['caseId']"); break; }
  [[ $STATUS == 422 ]] || break
  sleep 1
done
check IAM-E67 "the self-registered grower raises their first case → 201 (PRD J1 end to end)" "$([[ -n "$J1_CASE" ]]; echo $?)"
fi   # grower

if want catalog; then
# ---------------------------------------------------------------- SPEC-GRW-02 + SPEC-CAT-01 + SPEC-CASE-08: PRD J3 farms, J4 complaint
G1=110165911145454593
FKEY=$("$PY" -c "import uuid; print(uuid.uuid4())")
call POST "$GROWER/growers/$G1/farms" "$T_GROWER" '{"name":"Smoke vineyard","areaHa":1.5,"crops":["GRAPE"],"location":{"latitude":18.531234,"longitude":73.861234}}' \
  -H "Idempotency-Key: $FKEY"
FARM_ID=$(json "$TMP/body" "['farmId']")
check GRW-E200 "grower.in1 adds a farm → 201, exact location for the grower" \
  "$([[ $STATUS == 201 && $(json "$TMP/body" "['locationPrecision']") == EXACT ]]; echo $?)"
call GET "$GROWER/growers/$G1/farms/$FARM_ID" "$T_CARE"
check GRW-E208 "care.in (MASKED) sees the district, not the field" \
  "$([[ $STATUS == 200 && $(json "$TMP/body" "['location']['latitude']") == 18.5 && $(json "$TMP/body" "['locationPrecision']") == DISTRICT ]]; echo $?)"

call GET "$CATALOG/products?country=IN&q=azo" "$T_GROWER"
check CAT-E1 "grower.in1 finds Azoxa Duo in the India catalog" "$([[ $STATUS == 200 && $(json "$TMP/body" "['items'][0]['productId']") == 9001 ]]; echo $?)"
call GET "$CATALOG/products?country=BR" "$T_GROWER"
check CAT-E4 "grower.in1 cannot browse Brazil's catalog → 404" "$([[ $STATUS == 404 ]]; echo $?)"
call GET "$CATALOG/products/9001/batches/AZX2604-117" "$T_GROWER"
check CAT-E6 "the batch on the pack is a batch of that product → 200" "$([[ $STATUS == 200 ]]; echo $?)"

# J3/J4: a complaint on the new farm (case-service learns the farm by event or read-through)
call POST "$CASE/cases" "$T_GROWER" "{\"growerId\":\"$G1\",\"caseType\":\"PRODUCT_COMPLAINT\",\"title\":\"Smoke: spots on grapes\",\"description\":\"Brown spots after spraying\",\"farmId\":\"$FARM_ID\",\"productId\":\"9001\",\"batchNo\":\"AZX2604-117\"}" \
  -H "Idempotency-Key: $("$PY" -c "import uuid; print(uuid.uuid4())")"
check GRW-E222 "grower.in1 raises a complaint on the farm just added → 201 (PRD J3)" "$([[ $STATUS == 201 && $(json "$TMP/body" "['farmId']") == "$FARM_ID" ]]; echo $?)"
call POST "$CASE/cases" "$T_GROWER" "{\"growerId\":\"$G1\",\"caseType\":\"PRODUCT_COMPLAINT\",\"title\":\"Smoke: unknown batch\",\"description\":\"Batch not on any pack\",\"farmId\":\"$FARM_ID\",\"productId\":\"9001\",\"batchNo\":\"NOPE-0001\"}" \
  -H "Idempotency-Key: $("$PY" -c "import uuid; print(uuid.uuid4())")"
check CASE-E181 "an unknown batch is refused with a clear rule → 422 case.batch-unknown (PRD J4)" \
  "$([[ $STATUS == 422 && $(json "$TMP/body" "['rule']") == case.batch-unknown ]]; echo $?)"

# a product the ERP sync adds now reaches case-service without any seed: import → event / read-through → case
ERP_SECRET=$("$PY" -c "import json; print([c for c in json.load(open('$(dirname "$0")/keycloak/growercare-realm.json', encoding='utf-8'))['clients'] if c['clientId']=='erp-sync'][0]['secret'])")
T_ERP=$(curl -fsS -X POST "$KC/protocol/openid-connect/token" -d grant_type=client_credentials -d client_id=erp-sync \
  -d client_secret="$ERP_SECRET" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
PCODE="SMK-$("$PY" -c "import random; print(random.randint(100000, 999999))")"
call PUT "$CATALOG/internal/products/$PCODE" "$T_ERP" '{"buCode":"CP","name":"Smoke Fungicide 250 EC","kind":"FUNGICIDE","status":"ACTIVE","version":1,"activeIngredients":[{"name":"Smokazole","concentration":"250 g/L"}],"packSizes":["1 L"]}'
NEW_PRODUCT=$(json "$TMP/body" "['productId']")
PRODUCT_STATUS=$STATUS
call PUT "$CATALOG/internal/products/$PCODE/registrations/IN" "$T_ERP" '{"registrationNo":"CIR-SMOKE","status":"REGISTERED","validUntil":"2030-12-31","version":1}'
REG_STATUS=$STATUS
call PUT "$CATALOG/internal/products/$PCODE/batches/SMK-0001" "$T_ERP" '{"mfgDate":"2026-10-01","expiryDate":"2028-09-30","plantCode":"IN-GOA","status":"RELEASED","version":1}'
check CAT-E10 "erp-sync imports a new product, its India registration and a batch → 201 ×3" \
  "$([[ $PRODUCT_STATUS == 201 && -n "$NEW_PRODUCT" && $REG_STATUS == 201 && $STATUS == 201 ]]; echo $?)"
call POST "$CASE/cases" "$T_GROWER" "{\"growerId\":\"$G1\",\"caseType\":\"PRODUCT_COMPLAINT\",\"title\":\"Smoke: new product\",\"description\":\"Complaint about a product added today\",\"productId\":\"$NEW_PRODUCT\",\"batchNo\":\"SMK-0001\"}" \
  -H "Idempotency-Key: $("$PY" -c "import uuid; print(uuid.uuid4())")"
check CASE-E172 "a complaint about the newly imported product and batch → 201, BU from the catalog (no seed)" \
  "$([[ $STATUS == 201 && $(json "$TMP/body" "['buCode']") == CP ]]; echo $?)"

fi   # catalog

# ---------------------------------------------------------------- SPEC-EDGE-01 E13: PRD J5/J6/J8/J9 through the gateway
if want gateway; then
T_ADMIN=${T_ADMIN:-$(token admin.in 'Staff#Pass12')}
call GET "$GW/api/iam/me" ""
check EDGE-E4 "gateway: no token → 401 UNAUTHENTICATED, nothing forwarded" "$([[ $STATUS == 401 && $(json "$TMP/body" "['code']") == UNAUTHENTICATED ]]; echo $?)"
call GET "$GW/api/grower/internal/growers/$G1" "$T_CARE"
check EDGE-E3 "gateway: an internal API is never routed → 404" "$([[ $STATUS == 404 ]]; echo $?)"
RID=$("$PY" -c "import uuid; print(uuid.uuid4())")
call GET "$GW/api/iam/me" "$T_CARE" "" -H "X-Request-Id: $RID" -H "X-Country: BR"
check EDGE-E6 "gateway: routed with the prefix stripped, X-Request-Id kept, X-Country ignored" \
  "$([[ $STATUS == 200 && $(header X-Request-Id) == "$RID" && $(json "$TMP/body" "['homeCountry']") == IN ]]; echo $?)"

# J5: the grower calls; care finds them by phone and works their new case
GKEY=$("$PY" -c "import uuid; print(uuid.uuid4())")
call POST "$GW/api/cases/cases" "$T_GROWER" "${BODY/Smoke: leaves yellowing/Smoke J5: via the gateway}" -H "Idempotency-Key: $GKEY"
GW_CASE=$(json "$TMP/body" "['caseId']")
check EDGE-E1 "J5 grower.in1 raises a case through the gateway → 201, ETag passed back" "$([[ $STATUS == 201 && -n "$GW_CASE" && $(header ETag) == '"0"' ]]; echo $?)"
call POST "$GW/api/grower/growers/search" "$T_CARE" '{"phone":"+919876543210","countryCode":"IN"}'
FOUND=$(json "$TMP/body" "['items'][0]['growerId']")
call GET "$GW/api/cases/cases?growerId=$FOUND&limit=100" "$T_CARE"
check CASE-E215a "J5 care.in finds G1 by phone, then lists G1's cases (growerId filter) incl. the new one" \
  "$([[ "$FOUND" == "$G1" && $STATUS == 200 && $(json "$TMP/body" "['items']" | grep -c "$GW_CASE") -ge 1 ]]; echo $?)"
call GET "$GW/api/cases/cases?growerId=$G1" "$T_CARE_BR"
check CASE-E201 "J5 care.br filtering by an Indian grower → empty page" "$([[ $STATUS == 200 && $(json "$TMP/body" "['items']") == '[]' ]]; echo $?)"
call POST "$GW/api/cases/cases/$GW_CASE/transitions" "$T_CARE" '{"toStatus":"TRIAGED","note":"J5 triage via gateway"}' -H 'If-Match: "0"'
check J5-a "J5 care.in triages (If-Match through the gateway) → 200" "$([[ $STATUS == 200 && $(header ETag) == '"1"' ]]; echo $?)"
call PUT "$GW/api/cases/cases/$GW_CASE/assignee" "$T_CARE" '{"assigneeUserId":"102"}' -H 'If-Match: "1"'
check J5-b "J5 care.in assigns agro.in → 200" "$([[ $STATUS == 200 ]]; echo $?)"

# J6: the agronomist takes an offered transition; a stale update is refused
call GET "$GW/api/cases/cases/$GW_CASE" "$T_AGRO"
NEXT=$(json "$TMP/body" "['allowedTransitions'][0]['toStatus']"); VER=$(header ETag)
call POST "$GW/api/cases/cases/$GW_CASE/transitions" "$T_AGRO" "{\"toStatus\":\"$NEXT\",\"note\":\"J6 field visit\"}" -H "If-Match: $VER"
check J6-a "J6 agro.in applies the first offered transition ($NEXT) → 200" "$([[ -n "$NEXT" && $STATUS == 200 ]]; echo $?)"
call GET "$GW/api/cases/cases/$GW_CASE" "$T_AGRO"
AFTER=$(json "$TMP/body" "['allowedTransitions'][0]['toStatus']")
call POST "$GW/api/cases/cases/$GW_CASE/transitions" "$T_AGRO" "{\"toStatus\":\"$AFTER\"}" -H "If-Match: $VER"
check J6-b "J6 an offered move with the old version (stale) through the gateway → 412" "$([[ $STATUS == 412 ]]; echo $?)"

# J9: the territory overview
call GET "$GW/api/cases/cases/overview" "$T_TM"
check CASE-E215b "J9 tm.in overview over Maharashtra → 200 with counts" \
  "$([[ $STATUS == 200 && $(json "$TMP/body" "['scope']['territoryIds']") == *1002* && -n $(json "$TMP/body" "['openByStatus']") ]]; echo $?)"
call GET "$GW/api/cases/cases/overview?territoryId=1005" "$T_TM"
check CASE-E211 "J9 a territory outside tm.in's scope → 404" "$([[ $STATUS == 404 ]]; echo $?)"
call GET "$GW/api/cases/cases/overview" "$T_CARE"
check CASE-E212 "J9 care.in has no dashboard permission → 403" "$([[ $STATUS == 403 ]]; echo $?)"

# J8: the admin finds agro.in, grants a temporary role in Karnataka, revokes it
call GET "$GW/api/iam/users?q=vik" "$T_ADMIN"
check IAM-E86a "J8 admin.in finds Vikram Agro (102) in the directory" "$([[ $STATUS == 200 && $(json "$TMP/body" "['items'][0]['userId']") == 102 ]]; echo $?)"
call GET "$GW/api/iam/users?type=GROWER" "$T_ADMIN"
check IAM-E82 "J8 grower names are masked for admin.in" "$([[ $STATUS == 200 && $(json "$TMP/body" "['items'][0]['displayName']") == *'*'* ]]; echo $?)"
VALID_TO=$("$PY" -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
call POST "$GW/api/iam/grants" "$T_ADMIN" "{\"userId\":\"102\",\"roleCode\":\"TERRITORY_MANAGER\",\"territoryIds\":[\"1005\"],\"validTo\":\"$VALID_TO\",\"reason\":\"Smoke J8: cover Karnataka\"}"
J8_GRANT=$(json "$TMP/body" "['grantId']")
check IAM-E86b "J8 temporary TERRITORY_MANAGER grant for Karnataka → 201" "$([[ $STATUS == 201 && -n "$J8_GRANT" ]]; echo $?)"
if want events; then
  OK=1; for _ in $(seq 1 10); do call GET "$GW/api/cases/cases/overview?territoryId=1005" "$T_AGRO"; [[ $STATUS == 200 ]] && { OK=0; break; }; sleep 1; done
  check IAM-E86c "J8 the grant takes effect in case-service within 10 s (agro.in sees the Karnataka overview)" "$OK"
fi
call DELETE "$GW/api/iam/grants/$J8_GRANT?reason=Smoke%20J8%20done" "$T_ADMIN"
check IAM-E86d "J8 revoke → 200" "$([[ $STATUS == 200 ]]; echo $?)"
if want events; then
  OK=1; for _ in $(seq 1 10); do call GET "$GW/api/cases/cases/overview?territoryId=1005" "$T_AGRO"; [[ $STATUS == 403 ]] && { OK=0; break; }; sleep 1; done
  check IAM-E86e "J8 the revocation takes effect within 10 s (403 again)" "$OK"
fi
call GET "$GW/api/cases/cases/$GW_CASE" "$T_CARE_BR"
check J8-a "J8 care.br opens the Indian case by URL through the gateway → 404" "$([[ $STATUS == 404 ]]; echo $?)"
fi   # gateway

# ---------------------------------------------------------------- SPEC-NOT-02 E48: PRD J7, everyone is kept informed
if want notify; then
G1_PHONE=${G1_PHONE:-+919876543210}            # grower.in1 (G1), language mr
AGRO_EMAIL=${AGRO_EMAIL:-agro.in@growercare.test}
call POST "$CASE/cases" "$T_GROWER" "${BODY/Smoke: leaves yellowing/Smoke J7: notifications}" -H "Idempotency-Key: $("$PY" -c "import uuid; print(uuid.uuid4())")"
J7_CASE=$(json "$TMP/body" "['caseId']")
check NOT-E48a "J7 grower.in1 raises a case → 201" "$([[ $STATUS == 201 && -n "$J7_CASE" ]]; echo $?)"
call POST "$CASE/cases/$J7_CASE/comments" "$T_CARE" "{\"clientMsgId\":\"$("$PY" -c "import uuid; print(uuid.uuid4())")\",\"visibility\":\"INTERNAL\",\"body\":\"Smoke J7 internal note\"}"
check NOT-E48b "J7 care.in adds an internal note → 201" "$([[ $STATUS == 201 ]]; echo $?)"
call POST "$CASE/cases/$J7_CASE/comments" "$T_CARE" "{\"clientMsgId\":\"$("$PY" -c "import uuid; print(uuid.uuid4())")\",\"visibility\":\"PUBLIC\",\"body\":\"Smoke J7 public reply\"}"
check NOT-E48c "J7 care.in replies publicly → 201" "$([[ $STATUS == 201 ]]; echo $?)"
call GET "$CASE/cases/$J7_CASE" "$T_CARE"
call PUT "$CASE/cases/$J7_CASE/assignee" "$T_CARE" '{"assigneeUserId":"102"}' -H "If-Match: $(header ETag)"
check NOT-E48d "J7 care.in assigns agro.in → 200" "$([[ $STATUS == 200 ]]; echo $?)"
# the templates a recipient got for this case (oldest first), e.g. "case.created/mr case.reply/mr"
mail_for() { # recipient-url-encoded case-id
  curl -s -o "$TMP/mail" "$NOTIFY/dev/mailbox?recipient=$1"
  "$PY" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); print(' '.join(m['template']+'/'+m['language'] for m in reversed(d['items']) if '/cases/'+sys.argv[2] in m['body']))" "$TMP/mail" "$2" 2>/dev/null
}
# the grower: the new case at once, the public reply when the (local: 20 s) window ends; never the internal note
OK=1; for _ in $(seq 1 45); do GOT=$(mail_for "%2B${G1_PHONE:1}" "$J7_CASE"); [[ "$GOT" == "case.created/mr case.reply/mr" ]] && { OK=0; break; }; sleep 2; done
STATUS=200; echo "grower mailbox: $GOT" > "$TMP/body"
check NOT-E48e "J7 grower.in1 gets case.created and the reply in Marathi, nothing for the note (≤ 90 s)" "$OK"
OK=1; for _ in $(seq 1 15); do GOT=$(mail_for "${AGRO_EMAIL/@/%40}" "$J7_CASE"); [[ "$GOT" == "staff.assigned/en" ]] && { OK=0; break; }; sleep 2; done
echo "agro.in mailbox: $GOT" > "$TMP/body"
check NOT-E48f "J7 agro.in gets the assignment email at once" "$OK"
fi   # notify

# ---------------------------------------------------------------- SPEC-FE-04 R400/R401: the apps' nginx images, object-store CORS
if want web; then
for app in grower-web:5173 staff-console:5174; do
  name=${app%%:*}; port=${app##*:}
  STATUS=$(curl -s -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}' "http://localhost:$port/")
  check FE-R400a "$name :$port serves the app with its CSP (connect-src: Keycloak + the object store)" \
    "$([[ $STATUS == 200 && $(header Content-Security-Policy) == *"connect-src 'self' http://localhost:8180 http://localhost:8333"* ]]; echo $?)"
  STATUS=$(curl -s -o "$TMP/body" -w '%{http_code}' "http://localhost:$port/config.json")
  check FE-R400b "$name /config.json names its own Keycloak client" "$([[ $STATUS == 200 && $(json "$TMP/body" "['oidcClientId']") == "$name" ]]; echo $?)"
  STATUS=$(curl -s -o "$TMP/body" -w '%{http_code}' "http://localhost:$port/cases/123")
  check FE-R400c "$name deep link /cases/123 → the app (client-side routing)" "$([[ $STATUS == 200 ]] && grep -q 'id="root"' "$TMP/body"; echo $?)"
done
call GET "http://localhost:5173/api/iam/me" "$T_GROWER"
check FE-R400d "grower-web /api reaches the gateway (grower.in1 /me through nginx → 200)" "$([[ $STATUS == 200 && $(json "$TMP/body" "['userType']") == GROWER ]]; echo $?)"
call GET "http://localhost:5174/api/cases/cases?limit=1" "$T_CARE"
check FE-R400e "staff-console /api reaches the gateway (care.in queue through nginx → 200)" "$([[ $STATUS == 200 ]]; echo $?)"
for origin in http://localhost:5173 http://localhost:5174; do
  STATUS=$(curl -s -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' -X OPTIONS "http://localhost:8333/gc-media-staging/smoke-cors.jpg" \
    -H "Origin: $origin" -H 'Access-Control-Request-Method: PUT' -H 'Access-Control-Request-Headers: content-type')
  check FE-R401a "object store: a presigned PUT from $origin is allowed (CORS preflight)" "$([[ $STATUS == 200 && $(header Access-Control-Allow-Origin) == "$origin" ]]; echo $?)"
done
STATUS=$(curl -s -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' -X OPTIONS "http://localhost:8333/gc-media-staging/smoke-cors.jpg" \
  -H 'Origin: http://evil.test' -H 'Access-Control-Request-Method: PUT')
check FE-R401b "object store: a preflight from any other origin is refused (403)" "$([[ $STATUS == 403 && -z $(header Access-Control-Allow-Origin) ]]; echo $?)"
fi   # web

# ---------------------------------------------------------------- S11 authentication failures
call GET "$CASE/cases" ""
check PLAT-S11a "no token → 401 problem+json" "$([[ $STATUS == 401 && $(header Content-Type) == application/problem+json* ]]; echo $?)"
call GET "$CASE/cases" "not-a-jwt"
check PLAT-S11b "garbage token → 401" "$([[ $STATUS == 401 ]]; echo $?)"

echo
printf '%s\n' "${ROWS[@]}"
echo
echo "case: $CASE_ID ($CASE_NO)   failed checks: $FAILED"
exit "$FAILED"
