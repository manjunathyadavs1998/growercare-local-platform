#!/usr/bin/env bash
# SPEC-FE-04 D2 / FE-R401: the browser PUTs photos to presigned URLs in the staging bucket and downloads clean files, so
# those two buckets answer CORS for the two app origins only (http://localhost:5173 grower-web, :5174 staff-console);
# any other origin's preflight is refused (403). The server flag -s3.allowedOrigins does NOT restrict (SeaweedFS 4.53
# echoes any origin), so the rules are S3 bucket CORS (PutBucketCors), which SeaweedFS enforces.
# Creates the buckets when missing (case-service only creates what is absent). Idempotent; run after
# `docker compose up -d --wait`:   ./seaweedfs/configure-cors.sh
set -euo pipefail
cd "$(dirname "$0")/.."

S3=${S3:-http://localhost:8333}
KEYS=${S3_KEYS:-gc-dev-access:gc-dev-secret}          # the dev identity of seaweedfs/s3.json
ORIGINS=${WEB_ORIGINS:-http://localhost:5173 http://localhost:5174}
BUCKETS=${CORS_BUCKETS:-gc-media-staging gc-media-clean}
PY=${PY:-python}

s3() { curl -s -o /dev/null -w '%{http_code}' --aws-sigv4 "aws:amz:us-east-1:s3" --user "$KEYS" "$@"; }

xml="<CORSConfiguration><CORSRule>"
for origin in $ORIGINS; do xml+="<AllowedOrigin>$origin</AllowedOrigin>"; done
xml+="<AllowedMethod>PUT</AllowedMethod><AllowedMethod>GET</AllowedMethod><AllowedMethod>HEAD</AllowedMethod>"
xml+="<AllowedHeader>*</AllowedHeader><ExposeHeader>ETag</ExposeHeader><MaxAgeSeconds>3000</MaxAgeSeconds></CORSRule></CORSConfiguration>"
md5=$(printf '%s' "$xml" | "$PY" -c "import sys,hashlib,base64; print(base64.b64encode(hashlib.md5(sys.stdin.buffer.read()).digest()).decode())")

for bucket in $BUCKETS; do
  code=$(s3 -I "$S3/$bucket")
  if [[ $code == 404 ]]; then
    code=$(s3 -X PUT "$S3/$bucket")
    [[ $code == 200 ]] || { echo "creating bucket $bucket failed: HTTP $code" >&2; exit 1; }
    echo "bucket $bucket created"
  elif [[ $code != 200 ]]; then
    echo "bucket $bucket: HTTP $code (is SeaweedFS up?)" >&2; exit 1
  fi
  code=$(s3 -X PUT "$S3/$bucket?cors" -H "Content-MD5: $md5" -H "Content-Type: application/xml" --data-binary "$xml")
  [[ $code == 200 ]] || { echo "CORS for $bucket failed: HTTP $code" >&2; exit 1; }
  echo "bucket $bucket: CORS for $ORIGINS"
done
