#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# bootstrap-argocd.sh — Install ArgoCD and apply its config into an existing
# Kind cluster. Run AFTER bootstrap-kind.sh if you want to install ArgoCD
# separately, or use this as a reference for the steps involved.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARGOCD_NS="argocd"
ARGOCD_VERSION="v2.11.2"  # Pin for reproducibility

info() { echo ""; echo "▶  $*"; }

# ── Install ArgoCD ────────────────────────────────────────────────────────────
info "Creating argocd namespace..."
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -

info "Installing ArgoCD ${ARGOCD_VERSION}..."
kubectl apply -n "$ARGOCD_NS" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

info "Waiting for ArgoCD server to be ready..."
kubectl rollout status deployment/argocd-server -n "$ARGOCD_NS" --timeout=180s

# ── Retrieve admin password ───────────────────────────────────────────────────
ARGOCD_PWD=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  ArgoCD installed successfully                      │"
echo "│                                                     │"
echo "│  Access UI:                                         │"
echo "│    kubectl port-forward svc/argocd-server \\        │"
echo "│      -n argocd 8080:443                             │"
echo "│    Open: https://localhost:8080                     │"
echo "│    User: admin                                      │"
echo "│    Pass: ${ARGOCD_PWD}                              │"
echo "└─────────────────────────────────────────────────────┘"

# ── Apply AppProject and ApplicationSets ─────────────────────────────────────
info "Applying AppProject..."
kubectl apply -f "$REPO_ROOT/argocd/appproject.yaml"

info "Applying dev ApplicationSet..."
kubectl apply -f "$REPO_ROOT/argocd/applicationsets/dev-appset.yaml"

info "Applying qat ApplicationSet..."
kubectl apply -f "$REPO_ROOT/argocd/applicationsets/qat-appset.yaml"

echo ""
echo "✅ ArgoCD is configured. Apps will sync once the repo URL is set correctly."
echo "   Edit repoURL in argocd/applicationsets/*.yaml, then re-apply."
