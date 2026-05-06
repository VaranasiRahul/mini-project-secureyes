#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# load-test.sh — Generate traffic to trigger Prometheus alerts in the demo
# Usage: ./scripts/load-test.sh [--url http://localhost:8000] [--requests 300]
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

URL="http://localhost:8000"
REQUESTS=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)      URL="$2"; shift 2 ;;
    --requests) REQUESTS="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

echo "🚀 Sending $REQUESTS requests to $URL ..."

for i in $(seq 1 "$REQUESTS"); do
  # Alternate between listing and creating tasks
  if (( i % 3 == 0 )); then
    curl -s -o /dev/null -w "" \
      -X POST "${URL}/tasks?title=load-test-task-${i}" &
  else
    curl -s -o /dev/null -w "" "${URL}/tasks" &
  fi
  # Small pause to avoid overwhelming the local machine
  if (( i % 20 == 0 )); then
    wait
    echo "   Sent $i / $REQUESTS"
  fi
done

wait
echo ""
echo "✅ Done. Check alerts:"
echo "   Prometheus: http://localhost:9090/alerts"
echo "   Grafana:    http://localhost:3001"
