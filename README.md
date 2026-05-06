# Task Manager — DevOps Demo

A full-stack Task Manager app (React + FastAPI + PostgreSQL) with a production-grade DevOps setup covering containerization, orchestration, GitOps, observability, and network security.

---

## Table of Contents
1. [Architecture](#architecture)
2. [Repository Structure](#repository-structure)
3. [Prerequisites](#prerequisites)
4. [Part 1 — Docker Compose (local dev)](#part-1--docker-compose-local-dev)
5. [Part 2 — Kind Cluster + Helm + Kustomize](#part-2--kind-cluster--helm--kustomize)
6. [Part 3 — GitOps with ArgoCD](#part-3--gitops-with-argocd)
7. [Part 4 — Observability](#part-4--observability)
8. [Part 5 — Zero-Trust NetworkPolicies](#part-5--zero-trust-networkpolicies)
9. [CI Pipeline](#ci-pipeline)
10. [What I Would Add Next](#what-i-would-add-next)

---

## Architecture

```
                          +-------------+
                          | GitHub Repo |
                          +------+------+
                                 |
                          push to main
                                 |
                                 v
                    +------------------------+
                    |    GitHub Actions CI    |
                    | lint > build > scan >  |
                    | deploy to Kind cluster |
                    +------------------------+
                                 |
                    ArgoCD watches repo
                                 |
                                 v
    +------------------------------------------------------------+
    |                     Kind Cluster                           |
    |                                                            |
    |   argocd ns         monitoring ns           apps ns        |
    |  +----------+     +----------------+     +-----------+     |
    |  | ArgoCD   |     | Prometheus     |     | web (fe)  |     |
    |  | Server   |     | Grafana        |     | api (be)  |     |
    |  +----------+     | Loki+Promtail  |     | postgres  |     |
    |                   | AlertManager   |     +-----------+     |
    |                   +----------------+                       |
    |                                                            |
    |   ingress-nginx ns                                         |
    |  +------------------+                                      |
    |  | ingress-nginx    | --> routes localhost to web/api       |
    |  +------------------+                                      |
    +------------------------------------------------------------+

    Network Policies (zero-trust):
    - default-deny-all (blocks everything by default)
    - ingress-nginx --> web, api  (allowed)
    - api --> postgres            (allowed)
    - monitoring --> api          (scrape /metrics)
```

---

## Repository Structure

```
.
├── app/
│   ├── api/                  # FastAPI backend (Dockerfile, main.py, init.sql)
│   └── web/                  # React frontend  (Dockerfile, nginx.conf)
├── argocd/
│   ├── appproject.yaml       # ArgoCD project definition
│   └── applicationsets/      # dev-appset.yaml, qat-appset.yaml
├── environments/
│   └── local/.env.example    # Docker Compose env vars
├── helm/charts/
│   ├── ingress-nginx/        # Helm wrapper for ingress controller
│   ├── kube-prometheus-stack/ # Helm wrapper for Prometheus + Grafana
│   ├── loki-stack/           # Helm wrapper for Loki + Promtail
│   └── external-secrets/     # Helm wrapper for ESO
├── k8s/
│   ├── base/                 # Shared manifests (deployments, services, netpols)
│   └── overlays/
│       ├── dev/              # Dev overlay (1 replica, tasks.local)
│       └── qat/              # QAT overlay (2 replicas, tasks.qat.local)
├── monitoring/
│   ├── prometheus.yml        # Prometheus config (Docker Compose)
│   ├── rules/api-alerts.yaml # Custom alert rules
│   ├── loki-config.yaml      # Loki storage config
│   ├── promtail-config.yaml  # Promtail scrape config
│   ├── dashboards/           # Grafana dashboard JSON
│   └── grafana/provisioning/ # Datasource + dashboard provisioning
├── scripts/
│   ├── deploy.sh             # Docker Compose lifecycle manager
│   ├── bootstrap-kind.sh     # One-command Kind cluster setup
│   └── load-test.sh          # Generate traffic for alert demos
├── docker-compose.yml        # Multi-profile local dev stack
├── kind-config.yaml          # Kind cluster config (port mappings)
└── .github/workflows/ci.yml  # CI pipeline
```

---

## Prerequisites

### macOS

```bash
brew install kubectl kind helm kustomize mkcert
brew install aquasecurity/trivy/trivy
brew install argocd   # optional, for CLI demos
```

Docker Desktop: https://www.docker.com/products/docker-desktop

### Windows

```powershell
choco install kubernetes-cli kind kubernetes-helm kustomize mkcert trivy
# or use winget:
# winget install Kubernetes.kubectl Helm.Helm
```

Docker Desktop: https://www.docker.com/products/docker-desktop

> **Windows users:** Run all shell scripts (`.sh`) using **Git Bash** or **WSL2**.

### Version requirements

| Tool | Minimum version |
|------|-----------------|
| Docker Desktop | latest |
| kubectl | 1.29+ |
| kind | 0.22+ |
| helm | 3.13+ |
| kustomize | 5.0+ |

---

## Part 1 — Docker Compose (local dev)

This section brings up the full stack locally using Docker Compose with multi-profile support.

### Step 1: Clone and configure

```bash
git clone https://github.com/VaranasiRahul/mini-project-secureyes.git
cd mini-project-secureyes

# Create the environment file from the example
cp environments/local/.env.example environments/local/.env
```

Open `environments/local/.env` and change `POSTGRES_PASSWORD` to something secure. The default values work out of the box for local dev.

### Step 2: Start the stack

```bash
./scripts/deploy.sh start --profile monitoring
```

This starts **7 services** across 3 profiles:
- **core:** postgres
- **app:** api, web
- **monitoring:** prometheus, grafana, loki, promtail

Wait ~60 seconds for all health checks to pass.

### Step 3: Verify everything is healthy

```bash
./scripts/deploy.sh status
```

You should see all 7 services with status `healthy`:

```
NAME        STATUS
postgres    healthy
api         healthy
web         healthy
prometheus  healthy
grafana     healthy
loki        healthy
promtail    healthy
```

### Step 4: Access the services

| Service | URL | Credentials |
|---------|-----|-------------|
| Web UI | http://localhost:3000 | — |
| API docs (Swagger) | http://localhost:8000/docs | — |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3001 | admin / admin |

### Other deploy.sh commands

```bash
./scripts/deploy.sh stop       # stop all containers
./scripts/deploy.sh pause      # pause (freeze) containers
./scripts/deploy.sh resume     # unpause containers
./scripts/deploy.sh logs api   # tail logs for a specific service
./scripts/deploy.sh rebuild    # full teardown + rebuild from scratch
```

### Stop the Compose stack before Part 2

```bash
./scripts/deploy.sh stop
```

> **Important:** Docker Compose binds to ports 80 and 443. Stop it before starting the Kind cluster, which needs the same ports.

---

## Part 2 — Kind Cluster + Helm + Kustomize

This section creates a single-node Kubernetes cluster using Kind and installs all infrastructure via Helm wrappers and Kustomize overlays.

### Step 1: Create the secret file

```bash
cp k8s/overlays/dev/secret.env.example k8s/overlays/dev/secret.env
```

Open `k8s/overlays/dev/secret.env` and change the password. The file has working defaults, but you should customize `POSTGRES_PASSWORD` for any real use.

### Step 2: Bootstrap the cluster (one command)

```bash
./scripts/bootstrap-kind.sh
```

This script does everything:
1. Creates a Kind cluster named `dev-cluster` with port mappings (80, 443)
2. Adds Helm repos (ingress-nginx, prometheus-community, grafana, external-secrets)
3. Installs **ingress-nginx** (routes localhost traffic into the cluster)
4. Installs **external-secrets** operator
5. Installs **kube-prometheus-stack** (Prometheus + Grafana + AlertManager)
6. Installs **loki-stack** (Loki + Promtail for log aggregation)
7. Installs **ArgoCD** and configures the AppProject + ApplicationSets
8. Applies the dev Kustomize overlay (creates api, web, postgres in the `apps` namespace)

The whole process takes about 3–5 minutes.

### Step 3: Add hosts file entries

**macOS / Linux:**
```bash
sudo sh -c 'echo "127.0.0.1 tasks.local tasks.qat.local" >> /etc/hosts'
```

**Windows** (run Notepad as Administrator):
```
# Add to C:\Windows\System32\drivers\etc\hosts
127.0.0.1   tasks.local tasks.qat.local
```

### Step 4: Verify the cluster

```bash
# Check all pods are running
kubectl get pods -A

# Check app pods specifically
kubectl get pods -n apps

# Expected output:
# NAME                        READY   STATUS    RESTARTS   AGE
# api-xxxxx                   1/1     Running   0          2m
# web-xxxxx                   1/1     Running   0          2m
# postgres-xxxxx              1/1     Running   0          2m
```

### Kustomize overlays

The project uses a **base + overlay** structure:

| Overlay | Host | Replicas | Path |
|---------|------|----------|------|
| dev | tasks.local | 1 | `k8s/overlays/dev/` |
| qat | tasks.qat.local | 2 | `k8s/overlays/qat/` |

Both overlays share `k8s/base/` which contains deployments, services, NetworkPolicies, ServiceMonitors, and PrometheusRules. Overlays customize replica counts, hostnames, and secrets.

### Manual alternative (step-by-step)

If you prefer to run each step individually instead of using `bootstrap-kind.sh`:

```bash
# 1. Create cluster
kind create cluster --config kind-config.yaml

# 2. Install ingress-nginx
helm dependency update helm/charts/ingress-nginx
helm upgrade --install ingress-nginx helm/charts/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait

# 3. Install monitoring
helm dependency update helm/charts/kube-prometheus-stack
helm upgrade --install monitoring helm/charts/kube-prometheus-stack \
  --namespace monitoring --create-namespace --wait --timeout 300s

# 4. Install loki
helm dependency update helm/charts/loki-stack
helm upgrade --install loki helm/charts/loki-stack \
  --namespace monitoring --wait

# 5. Apply dev overlay
kubectl apply -k k8s/overlays/dev

# 6. Verify
kubectl get pods -n apps
```

---

## Part 3 — GitOps with ArgoCD

ArgoCD is installed by `bootstrap-kind.sh` and configured with an ApplicationSet that manages all environments from Git.

### Access the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open https://localhost:8080 in your browser and accept the self-signed certificate.

```bash
# Username: admin
# Password:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### Sync waves (deploy ordering)

ArgoCD uses sync-wave annotations to deploy resources in the correct order:

| Wave | Component | Why this order |
|------|-----------|----------------|
| 0 | ingress-nginx, external-secrets | Networking infra must exist first |
| 1 | kube-prometheus-stack | Monitoring needs to be ready to scrape |
| 2 | loki-stack | Log aggregation depends on monitoring namespace |
| 10 | postgres | Database must be healthy before the app connects |
| 20 | api, web | Application services start last |

Waves 0–2 are controlled by the ApplicationSet. Waves 10 and 20 are controlled by `argocd.argoproj.io/sync-wave` annotations directly on the Deployment manifests in `k8s/base/`.

### Demo: auto-deploy on Git push

```bash
# 1. Build a new version of the API image
docker build -t task-api:v2 ./app/api
kind load docker-image task-api:v2 --name dev-cluster

# 2. Update the image tag in the deployment
#    Edit k8s/base/api/deployment.yaml → change image to task-api:v2

# 3. Commit and push
git add k8s/base/api/deployment.yaml
git commit -m "chore: bump api to v2"
git push

# 4. Watch ArgoCD auto-sync in the UI (takes ~3 minutes by default)
#    The app tile will show "Syncing" → "Healthy"
```

### Demo: rollback

```bash
# Option 1: CLI
argocd login localhost:8080 --username admin --insecure
argocd app history dev-apps
argocd app rollback dev-apps <REVISION_ID>

# Option 2: ArgoCD UI
# Click on the app → History & Rollback → select a previous revision → Rollback
```

---

## Part 4 — Observability

### Prometheus + Grafana (Kubernetes)

```bash
# Port-forward Grafana
kubectl port-forward svc/monitoring-grafana -n monitoring 3001:80

# Port-forward Prometheus
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090
```

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://localhost:3001 | admin / admin |
| Prometheus | http://localhost:9090 | — |

### Auto-provisioned dashboard

The **Platform Health** dashboard is automatically loaded into Grafana via a ConfigMap. It shows:
- Node CPU and memory utilization
- Pod restart counts across the cluster
- API HTTP request rate (scraped from the `/metrics` endpoint via a ServiceMonitor)
- Live API logs from Loki

### Custom alert: APINoTraffic

A `PrometheusRule` CRD fires an alert when the API receives zero HTTP requests for 5 minutes. It includes a startup guard (`sum > 0`) to prevent false positives on a fresh cluster where no traffic has been generated yet.

View active alerts: http://localhost:9090/alerts

### Trigger an alert with load testing

```bash
# Generate 600 requests to the API
./scripts/load-test.sh --url http://localhost:8000 --requests 600

# Then check:
# - Prometheus alerts: http://localhost:9090/alerts
# - Grafana dashboard: http://localhost:3001
```

### RabbitMQ note

This application does not use a message queue, so the RabbitMQ exporter is intentionally omitted. If RabbitMQ were added, the `kube-prometheus-stack` Helm wrapper's `values.yaml` would enable the built-in RabbitMQ ServiceMonitor under `additionalServiceMonitors`.

---

## Part 5 — Zero-Trust NetworkPolicies

The `apps` namespace uses a **default-deny-all** NetworkPolicy that blocks all ingress and egress traffic by default. Individual services get explicit allow rules:

| Policy file | What it allows |
|-------------|---------------|
| `k8s/base/default-deny.yaml` | Blocks ALL traffic in the `apps` namespace (ingress + egress) |
| `k8s/base/api/networkpolicy.yaml` | Allows ingress from ingress-nginx → api on port 8000 |
| `k8s/base/web/networkpolicy.yaml` | Allows ingress from ingress-nginx → web on port 80 |
| `k8s/base/postgres/networkpolicy.yaml` | Allows ingress from api → postgres on port 5432 |
| `k8s/base/api/allow-prometheus-scrape.yaml` | Allows ingress from monitoring namespace → api on port 8000 (Prometheus scrape) |

### Verify NetworkPolicies

```bash
kubectl get networkpolicies -n apps

# Expected output:
# NAME                      POD-SELECTOR    AGE
# default-deny-all          <none>          5m
# allow-ingress-to-api      app=api         5m
# allow-ingress-to-web      app=web         5m
# allow-api-to-postgres     app=postgres    5m
# allow-prometheus-scrape   app=api         5m
```

---

## CI Pipeline

Every push to `main` runs a 3-job GitHub Actions pipeline (`.github/workflows/ci.yml`):

### Job 1: Lint
- Python linting with **ruff** (`app/api/`)
- **Helm lint** on all 4 chart wrappers (ingress-nginx, kube-prometheus-stack, loki-stack, external-secrets)
- **Kustomize validation** — builds both dev and qat overlays to verify they produce valid YAML

### Job 2: Build & Scan
- Builds Docker images for `api` and `web`
- Runs **Trivy** vulnerability scanner on both images (CRITICAL + HIGH severity)

### Job 3: Deploy to Kind
- Spins up an ephemeral Kind cluster
- Installs Prometheus Operator CRDs (needed for ServiceMonitor/PrometheusRule)
- Applies the full dev Kustomize overlay
- Verifies all resources are created: Deployments, Services, NetworkPolicies, ServiceMonitors, PrometheusRules

---

## What I Would Add Next

If I had more time, the next 3 things I would build:

1. **mTLS between api and postgres** using cert-manager + SPIFFE/SPIRE. Currently NetworkPolicies enforce L3/L4 separation, but mTLS would give cryptographic identity verification — the foundation for true zero-trust at L7.

2. **SLO burn-rate alerts** on the API. Instead of just alerting on zero-traffic, I'd define an error budget (e.g. 99.5% success rate over 30 days) and use multi-window burn-rate alerts (1h + 6h windows) so the team gets paged when the error budget is burning too fast — not just when things are completely broken.

3. **Distributed tracing with OpenTelemetry + Tempo**. Instrument the FastAPI app with the `opentelemetry-fastapi` SDK, ship traces to Grafana Tempo, and build a Grafana panel that correlates trace IDs with the Loki log lines — closing the full observability loop (metrics → logs → traces).
