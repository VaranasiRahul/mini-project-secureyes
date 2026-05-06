# Task Manager — DevOps Demo

> **Interview demo project** showcasing Docker Compose, Kind, Helm, Kustomize, ArgoCD, NetworkPolicies, and Prometheus/Grafana/Loki.
>
> **AI tools used:** Antigravity (Google DeepMind) — generated the full implementation plan, Helm chart values, Kustomize structure, CI pipeline, and README skeleton. All generated code was reviewed, understood, and adapted by the author.

---

## Table of Contents
1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Part 1 — Docker Compose (local)](#part-1--docker-compose-local)
4. [Part 2 — Kind Cluster + Helm + Kustomize](#part-2--kind-cluster--helm--kustomize)
5. [Part 3 — GitOps with ArgoCD](#part-3--gitops-with-argocd)
6. [Part 4 — Observability](#part-4--observability)
7. [CI Pipeline](#ci-pipeline)
8. [What I Would Add Next](#what-i-would-add-next)

---

## Architecture

```
GitHub ──push──▶ GitHub Actions (lint → build → trivy → deploy-kind)
                        │
                        ▼
                  Kind cluster
                  ┌─────────────────────────────────────────┐
                  │  argocd ns      monitoring ns    apps ns │
                  │  ──────────     ──────────────   ─────── │
                  │  ArgoCD    ◀──  Prometheus       api     │
                  │  (syncs    ──▶  Grafana          web     │
                  │  from Git)      Loki/Promtail    postgres│
                  │                 AlertManager             │
                  │  ingress-nginx (routes localhost:80/443)  │
                  └─────────────────────────────────────────┘
```

**Zero-trust networking:** `default-deny-all` NetworkPolicy blocks all traffic by default. Explicit policies allow only: ingress-nginx → web/api, api → postgres, monitoring → api (scrape).

---

## Prerequisites

Install on your machine before starting:

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | latest | https://www.docker.com/products/docker-desktop |
| kubectl | ≥ 1.29 | `brew install kubectl` |
| kind | ≥ 0.22 | `brew install kind` |
| helm | ≥ 3.13 | `brew install helm` |
| kustomize | ≥ 5.0 | `brew install kustomize` |
| trivy | latest | `brew install aquasecurity/trivy/trivy` |
| argocd CLI | latest | `brew install argocd` (optional) |

---

## Part 1 — Docker Compose (local)

### Setup

```bash
# 1. Clone the repo
git clone https://github.com/VaranasiRahul/mini-project-secureyes.git
cd mini-project

# 2. Copy and edit env file
cp environments/local/.env.example environments/local/.env
# Edit POSTGRES_PASSWORD and GF_ADMIN_PASSWORD

# 3. Start full stack (all profiles)
./scripts/deploy.sh start --profile monitoring

# 4. Verify all services healthy (~60s)
docker compose ps
```

### Endpoints

| Service | URL |
|---------|-----|
| Web UI | http://localhost:3000 |
| API docs | http://localhost:8000/docs |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3001 (admin/admin) |
| Loki (internal) | http://localhost:3100 |

### Other deploy.sh commands

```bash
./scripts/deploy.sh stop
./scripts/deploy.sh pause
./scripts/deploy.sh resume
./scripts/deploy.sh status
./scripts/deploy.sh logs api       # tail logs for a specific service
./scripts/deploy.sh rebuild        # full teardown + rebuild
```

---

## Part 2 — Kind Cluster + Helm + Kustomize

### Bootstrap (one command)

```bash
# Create secret env file first
cp k8s/overlays/dev/secret.env.example k8s/overlays/dev/secret.env
# Edit secret.env with your values

# Run bootstrap (creates cluster, installs everything)
./scripts/bootstrap-kind.sh
```

### Add to /etc/hosts

```
127.0.0.1   tasks.local tasks.qat.local
```

### Manual steps (if you prefer)

```bash
# 1. Create cluster
kind create cluster --config kind-config.yaml

# 2. Install ingress-nginx
helm dependency update helm/charts/ingress-nginx
helm upgrade --install ingress-nginx helm/charts/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait

# 3. Apply dev overlay
kubectl apply -k k8s/overlays/dev

# 4. Verify
kubectl get pods -n apps
```

### Kustomize overlays

| Overlay | Host | Replicas |
|---------|------|----------|
| dev | tasks.local | 1 |
| qat | tasks.qat.local | 2 |

---

## Part 3 — GitOps with ArgoCD

### Access ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open: https://localhost:8080
# Username: admin
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Demonstrating auto-deploy

```bash
# 1. Build and tag a new image
docker build -t task-api:v2 ./app/api
kind load docker-image task-api:v2 --name dev-cluster

# 2. Update the image tag in k8s/base/api/deployment.yaml
#    image: task-api:v2

# 3. Push to Git
git add k8s/base/api/deployment.yaml
git commit -m "chore: bump api to v2"
git push

# 4. Watch ArgoCD sync automatically in the UI
```

### Demonstrating rollback

```bash
# Via CLI
argocd login localhost:8080 --username admin --insecure
argocd app history dev-apps
argocd app rollback dev-apps <REVISION_ID>

# Or in the ArgoCD UI: History & Rollback → select revision → Rollback
```

---

## Part 4 — Observability

### Access Grafana

```bash
kubectl port-forward svc/monitoring-grafana -n monitoring 3001:80
# Open: http://localhost:3001  (admin/admin)
```

The **Platform Health** dashboard is auto-provisioned and shows:
- Node CPU and memory usage
- Pod restart counts
- API request rate (from `/metrics`)
- API logs from Loki

### Trigger an alert

```bash
# Run load test to spike traffic
./scripts/load-test.sh --url http://localhost:8000 --requests 600

# Check alerts firing
open http://localhost:9090/alerts
```

---

## CI Pipeline

Every push to `main`:
1. **Lint** — ruff (Python), helm lint (charts), kustomize build (overlays)
2. **Build** — Docker images for `api` and `web`
3. **Scan** — Trivy scans both images; fails on CRITICAL CVEs
4. **Deploy** — Applies dev overlay to an ephemeral Kind cluster and smoke-tests the API

See `.github/workflows/ci.yml`.

---

## What I Would Add Next

If I had another week, the next 3 things I would build:

1. **mTLS between api and postgres** using cert-manager + SPIFFE/SPIRE. Currently NetworkPolicies enforce L3/L4 separation, but mTLS would give cryptographic identity verification — the foundation for true zero-trust at L7.

2. **SLO burn-rate alerts** on the API. Instead of just alerting on zero-traffic, I'd define an error budget (e.g. 99.5% success rate over 30 days) and use multi-window burn-rate alerts (1h + 6h windows) so the team gets paged when the error budget is burning too fast — not just when things are completely broken.

3. **Distributed tracing with OpenTelemetry + Tempo**. Instrument the FastAPI app with the `opentelemetry-fastapi` SDK, ship traces to Grafana Tempo, and build a Grafana panel that correlates trace IDs with the Loki log lines — closing the full observability loop (metrics → logs → traces).
