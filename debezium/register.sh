#!/usr/bin/env bash
# SPEC-PLAT-04 D8: registers (or updates) the Debezium outbox connectors. Idempotent: PUT /connectors/<name>/config.
#   ./debezium/register.sh            # needs: docker compose up -d --wait, and the services started once (migrations)
set -euo pipefail
cd "$(dirname "$0")"
CONNECT=${CONNECT_URL:-http://localhost:8083}

for file in iam-outbox.json case-outbox.json; do
  name=$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$file")
  python -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))['config']))" "$file" \
    | curl -fsS -X PUT -H 'Content-Type: application/json' --data @- "$CONNECT/connectors/$name/config" > /dev/null
  for _ in $(seq 1 30); do
    state=$(curl -fsS "$CONNECT/connectors/$name/status" | python -c "import json,sys; s=json.load(sys.stdin); print(s['connector']['state'], *[t['state'] for t in s['tasks']])" || true)
    case "$state" in
      "RUNNING RUNNING") echo "  $name: RUNNING"; break ;;
      *FAILED*) echo "  $name: $state"; curl -fsS "$CONNECT/connectors/$name/status"; exit 1 ;;
    esac
    sleep 2
  done
  [[ "$state" == "RUNNING RUNNING" ]] || { echo "  $name did not start: $state"; exit 1; }
done
