#!/usr/bin/env bash
# Start / stop identity-access-service (8081) and case-service (8082) from their built jars with profile "local".
#   ./run-services.sh start    # needs: docker compose up -d --wait, and `mvn -B package -DskipTests` in gc-backend
#   ./run-services.sh status
#   ./run-services.sh stop
# The first case-service start migrates all 128 shard schemas (SPEC-PLAT-01 D3, ~4 min); later starts are no-ops.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
mkdir -p logs
PIDS=logs/services.pids
JAVA_OPTS=${JAVA_OPTS:-"-Xmx384m -XX:+UseSerialGC"}

health() { curl -fsS --max-time 3 "http://localhost:$1/actuator/health" 2>/dev/null | grep -q '"UP"'; }

wait_up() { # port name timeout-seconds
  local deadline=$((SECONDS + $3))
  until health "$1"; do
    if (( SECONDS > deadline )); then echo "  $2 did not become healthy in $3 s (see local-dev/logs/$2.log)"; return 1; fi
    sleep 3
  done
  echo "  $2 is UP on :$1"
}

start_one() { # name port
  local jar="$ROOT/services/$1/target/$1-0.1.0-SNAPSHOT.jar"
  [[ -f "$jar" ]] || { echo "missing $jar - run: mvn -B package -DskipTests"; exit 1; }
  if health "$2"; then echo "  $1 already UP on :$2"; return; fi
  # shellcheck disable=SC2086
  nohup java $JAVA_OPTS -jar "$jar" --spring.profiles.active=local > "logs/$1.log" 2>&1 &
  echo "$! $1" >> "$PIDS"
  echo "  started $1 (pid $!)"
}

case "${1:-}" in
  start)
    : > "$PIDS"
    start_one identity-access-service 8081
    wait_up 8081 identity-access-service 120
    start_one case-service 8082
    wait_up 8082 case-service 600          # first run includes the 128-shard migration
    ;;
  status)
    for p in 8081 8082; do if health $p; then echo ":$p UP"; else echo ":$p DOWN"; fi; done
    ;;
  stop)
    if [[ -f "$PIDS" ]]; then
      while read -r pid name; do kill "$pid" 2>/dev/null && echo "  stopped $name ($pid)" || true; done < "$PIDS"
      : > "$PIDS"
    fi
    ;;
  *) echo "usage: $0 start|status|stop"; exit 2 ;;
esac
