#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# deploy.sh — Manage the Docker Compose stack for local development
#
# Usage:
#   ./scripts/deploy.sh start [--profile <core|app|monitoring>]
#   ./scripts/deploy.sh stop  [--profile <core|app|monitoring>]
#   ./scripts/deploy.sh pause [--profile <core|app|monitoring>]
#   ./scripts/deploy.sh resume
#   ./scripts/deploy.sh status
#   ./scripts/deploy.sh logs [<service>]
#   ./scripts/deploy.sh rebuild
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
ENV_FILE="environments/local/.env"
PROFILE="monitoring"   # default: everything

# Ensure .env exists
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.example and fill in values:"
  echo "  cp environments/local/.env.example environments/local/.env"
  exit 1
fi

usage() {
  grep '^#' "$0" | sed 's/^# \?//'
  exit 1
}

ACTION=${1:-start}
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

DC="docker compose --env-file $ENV_FILE --profile $PROFILE -f $COMPOSE_FILE"

case "$ACTION" in
  start)
    echo "▶  Starting stack (profile=$PROFILE)..."
    $DC up -d --build
    echo "⏳  Waiting 15 s for health checks..."
    sleep 15
    $DC ps
    echo ""
    echo "✅  Stack is up."
    echo "    Web:        http://localhost:3000"
    echo "    API:        http://localhost:8000/docs"
    echo "    Prometheus: http://localhost:9090"
    echo "    Grafana:    http://localhost:3001  (admin / \${GF_ADMIN_PASSWORD})"
    ;;
  stop)
    echo "⏹  Stopping stack..."
    $DC down
    ;;
  pause)
    echo "⏸  Pausing stack..."
    $DC pause
    ;;
  resume)
    echo "▶  Resuming stack..."
    $DC unpause
    ;;
  status)
    $DC ps
    ;;
  logs)
    SERVICE="${1:-}"
    $DC logs -f $SERVICE
    ;;
  rebuild)
    echo "🔨  Rebuilding and restarting..."
    $DC down
    $DC up -d --build
    ;;
  *)
    echo "Unknown action: $ACTION"
    usage
    ;;
esac
