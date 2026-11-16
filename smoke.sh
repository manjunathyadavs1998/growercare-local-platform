#!/usr/bin/env bash
# SPEC-PLAT-01 R10: end-to-end smoke test against the real local stack
# (Docker: Postgres, Redis, Keycloak + identity-access-service :8081 + case-service :8082, profile local).
# Real Keycloak tokens (client gc-dev-cli). Prints a PASS/FAIL table; exit code = number of failed checks.
set -uo pipefail

KC=${KC:-http://localhost:8180/realms/growercare}
IAM=${IAM:-http://localhost:8081}
CASE=${CASE:-http://localhost:8082}
PY=${PY:-python}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0
ROWS=()

json() { "$PY" -c "import sys,json; d=json.load(open(sys.argv[1])); v=eval('d'+sys.argv[2]); print('' if v is None else v)" "$1" "$2" 2>/dev/null; }

token() { # user password
  curl -fsS -X POST "$KC/protocol/openid-connect/token" -d grant_type=password -d client_id=gc-dev-cli \
       -d "username=$1" --data-urlencode "password=$2" -o "$TMP/tok.json" || { echo "token for $1 failed" >&2; return 1; }
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

echo "== GrowerCare smoke test =="

# ---------------------------------------------------------------- S01 health
for target in "$IAM/actuator/health" "$CASE/actuator/health" "http://localhost:8180/realms/growercare"; do
  STATUS=$(curl -s -o "$TMP/body" -w '%{http_code}' "$target")
  check PLAT-S01 "reachable: $target" "$([[ $STATUS == 200 ]]; echo $?)"
done

T_GROWER=$(token grower.in1 'Grower#Pass1')
T_CARE=$(token care.in 'Staff#Pass12')
T_CARE_BR=$(token care.br 'Staff#Pass12')
T_TM=$(token tm.in 'Staff#Pass12')
T_AGRO=$(token agro.in 'Staff#Pass12')
T_RET2=$(token retailer2.in 'Partner#Pass1')

# ---------------------------------------------------------------- S02 IAM /me
call GET "$IAM/me" "$T_CARE"
check PLAT-S02 "IAM /me as care.in → CARE_AGENT" "$([[ $STATUS == 200 && $(json "$TMP/body" "['grants'][0]['roleCode']") == CARE_AGENT ]]; echo $?)"

# ---------------------------------------------------------------- S03/S04 create + idempotent replay
KEY=$("$PY" -c "import uuid; print(uuid.uuid4())")
BODY='{"growerId":"70001","caseType":"PRODUCT_COMPLAINT","title":"Smoke: leaves yellowing","description":"Spots after spray (smoke test)","farmId":"80001","productId":"9001","batchNo":"AZX2604-117"}'
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
