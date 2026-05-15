#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# bootstrap-kind.sh — Kind cluster lifecycle manager
#
# Usage:
#   ./scripts/bootstrap-kind.sh           # start (create cluster + install everything)
#   ./scripts/bootstrap-kind.sh stop      # delete the cluster completely
#   ./scripts/bootstrap-kind.sh status    # show pod status across all namespaces
#   ./scripts/bootstrap-kind.sh restart   # delete + recreate from scratch
#
# Prerequisites: docker, kind, kubectl, helm, kustomize
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLUSTER_NAME="dev-cluster"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

info()  { echo ""; echo "▶  $*"; }
check() { command -v "$1" &>/dev/null || { echo "ERROR: $1 not found. Install it first."; exit 1; }; }

# ── Argument handling ─────────────────────────────────────────────────────────
ACTION="${1:-start}"

case "$ACTION" in
  stop)
    info "Deleting Kind cluster '$CLUSTER_NAME'..."
    kind delete cluster --name "$CLUSTER_NAME" && echo "" && echo "✅  Cluster deleted." || echo "⚠️  Cluster not found (already stopped)."
    info "Killing any dangling port-forwards..."
    pkill -f "kubectl port-forward" 2>/dev/null && echo "   Port-forwards stopped." || echo "   No port-forwards running."
    exit 0
    ;;
  status)
    info "Cluster info..."
    kubectl cluster-info --context "kind-${CLUSTER_NAME}" 2>/dev/null || { echo "   Cluster not running."; exit 1; }
    echo ""
    echo "── apps namespace ──────────────────────────────────"
    kubectl get pods -n apps 2>/dev/null || echo "   (no apps namespace)"
    echo ""
    echo "── ingress-nginx ───────────────────────────────────"
    kubectl get pods -n ingress-nginx 2>/dev/null || echo "   (not installed)"
    echo ""
    echo "── monitoring ──────────────────────────────────────"
    kubectl get pods -n monitoring 2>/dev/null || echo "   (not installed)"
    echo ""
    echo "── argocd ──────────────────────────────────────────"
    kubectl get applications -n argocd 2>/dev/null || echo "   (not installed)"
    exit 0
    ;;
  restart)
    info "Restarting cluster (delete + recreate)..."
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
    pkill -f "kubectl port-forward" 2>/dev/null || true
    # Fall through to start
    ;;
  start)
    : # fall through to the main script below
    ;;
  *)
    echo "Usage: $0 [start|stop|status|restart]"
    exit 1
    ;;
esac

# ── Preflight ──────────────────────────────────────────────────────────────────
info "Checking prerequisites..."
check docker
check kind
check kubectl
check helm
check kustomize

# ── Cluster ───────────────────────────────────────────────────────────────────
info "Creating Kind cluster '$CLUSTER_NAME'..."
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "   Cluster already exists, skipping create."
else
  kind create cluster --name "$CLUSTER_NAME" \
    --config "$REPO_ROOT/kind-config.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ── Helm repos ────────────────────────────────────────────────────────────────
info "Adding Helm repos..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx          2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts                      2>/dev/null || true
helm repo add external-secrets https://charts.external-secrets.io                2>/dev/null || true
helm repo update

# ── ingress-nginx ─────────────────────────────────────────────────────────────
info "Installing ingress-nginx..."
helm dependency update "$REPO_ROOT/helm/charts/ingress-nginx"
# Pre-pull the controller image into the Kind node so the DaemonSet starts
# immediately without waiting for an image pull inside the cluster.
NGINX_IMAGE=$(helm show values "$REPO_ROOT/helm/charts/ingress-nginx/charts/ingress-nginx" \
  --jsonpath='{.controller.image.registry}/{.controller.image.image}:{.controller.image.tag}' \
  2>/dev/null || echo "registry.k8s.io/ingress-nginx/controller:v1.12.0")
echo "   Pre-pulling $NGINX_IMAGE into Kind node..."
docker pull "$NGINX_IMAGE" -q 2>/dev/null || true
kind load docker-image "$NGINX_IMAGE" --name "$CLUSTER_NAME" 2>/dev/null || true

helm upgrade --install ingress-nginx "$REPO_ROOT/helm/charts/ingress-nginx" \
  --namespace ingress-nginx --create-namespace \
  --wait --timeout 180s


# ── external-secrets ──────────────────────────────────────────────────────────
# Installed without --wait: the cert-controller and webhook take 3-4 minutes
# to initialise TLS. We don't use it in this demo so we let it start in the
# background rather than block the rest of the bootstrap.
info "Installing external-secrets operator..."
helm dependency update "$REPO_ROOT/helm/charts/external-secrets"
helm upgrade --install external-secrets "$REPO_ROOT/helm/charts/external-secrets" \
  --namespace external-secrets --create-namespace

# ── kube-prometheus-stack ─────────────────────────────────────────────────────
info "Installing kube-prometheus-stack (Prometheus + Grafana + AlertManager)..."
helm dependency update "$REPO_ROOT/helm/charts/kube-prometheus-stack"
helm upgrade --install monitoring "$REPO_ROOT/helm/charts/kube-prometheus-stack" \
  --namespace monitoring --create-namespace \
  --wait --timeout 300s

# ── loki-stack ────────────────────────────────────────────────────────────────
info "Installing loki-stack (Loki + Promtail)..."
helm dependency update "$REPO_ROOT/helm/charts/loki-stack"
helm upgrade --install loki "$REPO_ROOT/helm/charts/loki-stack" \
  --namespace monitoring \
  --wait --timeout 180s

# ── ArgoCD ────────────────────────────────────────────────────────────────────
info "Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Use --server-side to avoid "annotation too long" error on large CRDs
# (applicationsets.argoproj.io exceeds the 262144-byte client-side annotation limit)
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s

info "Retrieving initial ArgoCD admin password..."
ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "   ArgoCD admin password: $ARGOCD_PWD"
echo "   Access ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"

# ── ArgoCD config ─────────────────────────────────────────────────────────────
info "Applying ArgoCD AppProject and ApplicationSets..."
kubectl apply -f "$REPO_ROOT/argocd/appproject.yaml"
kubectl apply -f "$REPO_ROOT/argocd/applicationsets/dev-appset.yaml"
kubectl apply -f "$REPO_ROOT/argocd/applicationsets/qat-appset.yaml"

# ── Build + load local images ─────────────────────────────────────────────────
# Kind clusters have their own image cache — images built locally aren't
# visible inside the cluster until explicitly loaded with 'kind load'.
info "Building and loading app images into Kind..."
docker build -t task-api:local "$REPO_ROOT/app/api" -q
docker build -t task-web:local "$REPO_ROOT/app/web" -q
kind load docker-image task-api:local --name "$CLUSTER_NAME"
kind load docker-image task-web:local --name "$CLUSTER_NAME"

# ── Dev overlay (direct apply for immediate testing) ──────────────────────────
info "Creating dev secret (if secret.env exists)..."
if [[ -f "$REPO_ROOT/k8s/overlays/dev/secret.env" ]]; then
  kubectl apply -k "$REPO_ROOT/k8s/overlays/dev"
else
  echo "   WARNING: k8s/overlays/dev/secret.env not found."
  echo "   Copy secret.env.example, fill it in, then run:"
  echo "     kubectl apply -k k8s/overlays/dev"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✅  Kind cluster is ready!"
echo ""
echo "  Add to /etc/hosts:"
echo "    127.0.0.1   tasks.local tasks.qat.local"
echo ""
echo "  Endpoints (after port-forwards):"
echo "    Web:      http://tasks.local"
echo "    ArgoCD:   kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    Grafana:  kubectl port-forward svc/monitoring-grafana -n monitoring 3001:80"
echo "    Prometheus: kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090"
echo "════════════════════════════════════════════════════════════"
