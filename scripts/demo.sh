#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# demo.sh — One-command demo launcher for the Kind cluster
#
# Usage:
#   ./scripts/demo.sh            # start everything + open port-forwards
#   ./scripts/demo.sh --stop     # kill all demo port-forwards
#   ./scripts/demo.sh --status   # show pod health
#
# What it does:
#   1. Bootstraps the Kind cluster (skips if already running)
#   2. Ensures /etc/hosts has tasks.local entries (prompts sudo if missing)
#   3. Kills any stale port-forwards from a previous run
#   4. Starts fresh port-forwards for: ArgoCD, Grafana, Prometheus
#   5. Prints all browser URLs + ArgoCD password
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLUSTER_NAME="dev-cluster"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PF_PIDFILE="/tmp/demo-portforwards.pid"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN="\033[0;32m"; CYAN="\033[0;36m"; YELLOW="\033[1;33m"
BOLD="\033[1m"; RESET="\033[0m"

info()    { echo -e "\n${CYAN}▶  $*${RESET}"; }
success() { echo -e "${GREEN}✔  $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠  $*${RESET}"; }

# ── --stop ────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--stop" ]]; then
  info "Stopping all demo port-forwards..."
  if [[ -f "$PF_PIDFILE" ]]; then
    while read -r pid; do
      kill "$pid" 2>/dev/null && echo "   killed PID $pid" || true
    done < "$PF_PIDFILE"
    rm -f "$PF_PIDFILE"
    success "Port-forwards stopped."
  else
    warn "No PID file found — nothing to stop."
  fi
  exit 0
fi

# ── --status ──────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--status" ]]; then
  echo -e "\n${BOLD}All pods:${RESET}"
  kubectl get pods -A --context "kind-${CLUSTER_NAME}"
  echo -e "\n${BOLD}App pods (apps namespace):${RESET}"
  kubectl get pods -n apps --context "kind-${CLUSTER_NAME}"
  echo -e "\n${BOLD}NetworkPolicies:${RESET}"
  kubectl get networkpolicies -n apps --context "kind-${CLUSTER_NAME}"
  exit 0
fi

# ── Step 1: Bootstrap cluster (idempotent) ────────────────────────────────────
info "Checking Kind cluster '${CLUSTER_NAME}'..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  success "Cluster already running — skipping bootstrap."
else
  warn "Cluster not found — running bootstrap (takes ~5 min)..."
  bash "$REPO_ROOT/scripts/bootstrap-kind.sh"
fi

# ── Step 2: /etc/hosts entries ────────────────────────────────────────────────
info "Checking /etc/hosts entries..."
if grep -q "tasks.local" /etc/hosts; then
  success "/etc/hosts already has tasks.local entries."
else
  warn "tasks.local not found in /etc/hosts — attempting to add (requires sudo)..."
  if sudo -n sh -c 'echo "127.0.0.1 tasks.local tasks.qat.local" >> /etc/hosts' 2>/dev/null; then
    success "Hosts entries added automatically."
  else
    echo ""
    echo -e "${YELLOW}  ⚠  Could not auto-add /etc/hosts entry (sudo required).${RESET}"
    echo -e "  Run this once manually in a separate terminal, then re-run demo.sh:"
    echo -e "  ${BOLD}  sudo sh -c 'echo \"127.0.0.1 tasks.local tasks.qat.local\" >> /etc/hosts'${RESET}"
    echo ""
    echo -e "  ${CYAN}Continuing anyway — http://tasks.local won't work until you add the entry.${RESET}"
    echo -e "  ${CYAN}All other URLs (ArgoCD, Grafana, Prometheus) will still work fine.${RESET}"
    echo ""
  fi
fi

# ── Step 3: Kill stale port-forwards ─────────────────────────────────────────
info "Cleaning up any stale port-forwards..."
pkill -f "kubectl port-forward" 2>/dev/null || true
rm -f "$PF_PIDFILE"
sleep 1

# ── Step 4: Start port-forwards ───────────────────────────────────────────────
info "Starting port-forwards..."

start_pf() {
  local label=$1; shift
  kubectl port-forward "$@" --context "kind-${CLUSTER_NAME}" \
    >/tmp/pf-${label}.log 2>&1 &
  echo $! >> "$PF_PIDFILE"
  success "Port-forward started: ${label} (PID $!)"
}

# ArgoCD  → https://localhost:8080
start_pf "argocd"     svc/argocd-server -n argocd 8080:443

# Grafana → http://localhost:3001
start_pf "grafana"    svc/monitoring-grafana -n monitoring 3001:80

# Prometheus → http://localhost:9090
start_pf "prometheus" svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090

sleep 2  # give port-forwards a moment to bind

# ── Step 5: Fetch ArgoCD password ─────────────────────────────────────────────
info "Fetching ArgoCD admin password..."
ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" --context "kind-${CLUSTER_NAME}" | base64 -d)

# ── Done — print URL summary ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}  ✅  Demo is live! Open these in your browser:${RESET}"
echo ""
echo -e "  ${BOLD}Web App (Task Manager)${RESET}"
echo -e "    🌐  http://tasks.local"
echo ""
echo -e "  ${BOLD}ArgoCD (GitOps UI)${RESET}"
echo -e "    🔁  https://localhost:8080"
echo -e "    👤  admin / ${YELLOW}${ARGOCD_PWD}${RESET}"
echo ""
echo -e "  ${BOLD}Grafana (Platform Health Dashboard)${RESET}"
echo -e "    📊  http://localhost:3001"
echo -e "    👤  admin / admin"
echo ""
echo -e "  ${BOLD}Prometheus (Metrics + Alerts)${RESET}"
echo -e "    📈  http://localhost:9090"
echo -e "    🚨  http://localhost:9090/alerts"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "    ./scripts/demo.sh --status   # pod health check"
echo -e "    ./scripts/demo.sh --stop     # kill port-forwards"
echo -e "    ./scripts/load-test.sh --url http://localhost:8000 --requests 600"
echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo ""
