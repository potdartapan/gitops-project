# GitOps Portfolio Project — DevOps Workflow Guide

> A complete, production-style GitOps implementation on Azure Kubernetes Service (AKS).
> This guide is written for someone learning DevOps — every concept is explained from first principles.

---

## Table of Contents

1. [What is GitOps?](#what-is-gitops)
2. [Project Overview](#project-overview)
3. [Architecture Diagram](#architecture-diagram)
4. [The Full DevOps Workflow — Step by Step](#the-full-devops-workflow--step-by-step)
5. [Terraform — Infrastructure as Code](#terraform--infrastructure-as-code)
6. [Kubernetes — Container Orchestration](#kubernetes--container-orchestration)
   - [Core Objects](#core-kubernetes-objects-used-in-this-project)
   - [Networking](#kubernetes-networking)
   - [Databases & Storage](#databases--storage-in-kubernetes)
   - [Argo Rollouts — Progressive Delivery](#argo-rollouts--progressive-delivery-canary-deployments)
7. [Argo CD — GitOps Continuous Delivery](#argo-cd--gitops-continuous-delivery)
8. [GitHub Actions — CI/CD Pipelines](#github-actions--cicd-pipelines)
9. [Monitoring — Prometheus & Grafana](#monitoring--prometheus--grafana)
10. [Application Architecture](#application-architecture)
11. [Directory Structure Reference](#directory-structure-reference)
12. [How Everything Connects](#how-everything-connects)

---

## What is GitOps?

**GitOps** is a way of managing infrastructure and applications where **Git is the single source of truth**.

Instead of manually running `kubectl apply` or `terraform apply` from your laptop, you:
1. Describe the **desired state** of your system in YAML/HCL files
2. Commit those files to Git
3. Automated tools (Argo CD, Terraform) detect changes and **make the real system match the declared state**

**Key principle**: If it's not in Git, it doesn't exist in production.

```
Developer commits code
        │
        ▼
  GitHub Repository ◄──── Single source of truth
        │
        ├── GitHub Actions (CI) ──► Build, Test, Push Docker image
        │                               │
        │                               ▼
        │                    Update k8s/apps/.../values.yaml (image tag)
        │                               │
        │                               ▼
        └── Argo CD (CD) ──────────► Detect change, sync to Kubernetes cluster
```

---

## Project Overview

This project deploys a **Todo application** with a background analytics worker on Azure Kubernetes Service.

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Cloud Provider | Microsoft Azure | Hosts the Kubernetes cluster |
| Infrastructure | Terraform | Provisions AKS cluster, networking, load balancer |
| Container Registry | Docker Hub | Stores built Docker images |
| Container Orchestration | Kubernetes (AKS) | Runs all workloads |
| GitOps Engine | Argo CD | Syncs Git state to Kubernetes |
| Progressive Delivery | Argo Rollouts | Canary deployments with traffic splitting |
| CI/CD | GitHub Actions | Builds images, updates manifests |
| Ingress Controller | NGINX | Routes external HTTP traffic |
| Database | PostgreSQL (Bitnami Helm) | Persistent application data |
| Cache / Message Bus | Redis (Bitnami Helm) | Caching + event streaming |
| Monitoring | Prometheus + Grafana | Metrics collection and dashboards |
| Package Manager | Helm | Templates for complex K8s deployments |

**Live access URLs** (when cluster is running):
- App: `http://tapan-gitops-app.eastus2.cloudapp.azure.com/`
- Argo CD: `http://tapan-gitops-app.eastus2.cloudapp.azure.com/argocd`
- Grafana: `http://tapan-gitops-app.eastus2.cloudapp.azure.com/grafana`

---

## Architecture Diagram

```
                         ┌─────────────────────────────────────────────────────┐
                         │                  GitHub Repository                   │
                         │   ┌──────────┐  ┌──────────┐  ┌──────────────────┐ │
                         │   │app/code  │  │terraform/│  │k8s/ manifests    │ │
                         │   └────┬─────┘  └────┬─────┘  └────────┬─────────┘ │
                         └────────┼─────────────┼─────────────────┼───────────┘
                                  │             │                 │
                    Push to app/  │             │ Manual trigger  │ Argo CD watches
                                  ▼             ▼                 ▼
                         ┌────────────┐  ┌────────────┐  ┌───────────────┐
                         │  GitHub    │  │  GitHub    │  │   Argo CD     │
                         │  Actions  │  │  Actions  │  │  (in cluster) │
                         │  (CI/CD)  │  │  (infra)  │  └───────┬───────┘
                         └─────┬──────┘  └─────┬──────┘        │ sync
                               │               │               ▼
                        Build  │               │  ┌────────────────────────────┐
                        & Push │               │  │   Azure Kubernetes Service  │
                               ▼               │  │                            │
                         Docker Hub            │  │  ┌─────────────────────┐  │
                               │               └─►│  │  NGINX Ingress      │  │
                         Update│                  │  │  (Load Balancer)    │  │
                         image │                  │  └──────────┬──────────┘  │
                         tag   │                  │             │route         │
                               └──────────────────►  ┌─────────▼──────────┐  │
                                                  │  │   Todo App          │  │
                                                  │  │   (Argo Rollout)   │  │
                                                  │  └─────────┬──────────┘  │
                                                  │            │publish event │
                                                  │  ┌─────────▼──────────┐  │
                                                  │  │   Redis Stream      │  │
                                                  │  └─────────┬──────────┘  │
                                                  │            │consume       │
                                                  │  ┌─────────▼──────────┐  │
                                                  │  │  Analytics Worker   │  │
                                                  │  │   (Argo Rollout)   │  │
                                                  │  └─────────┬──────────┘  │
                                                  │            │write         │
                                                  │  ┌─────────▼──────────┐  │
                                                  │  │     PostgreSQL      │  │
                                                  │  │  (tododb +          │  │
                                                  │  │   analytics_db)     │  │
                                                  │  └────────────────────┘  │
                                                  │                            │
                                                  │  ┌────────────────────┐   │
                                                  │  │ Prometheus+Grafana │   │
                                                  │  │  (Monitoring ns)   │   │
                                                  │  └────────────────────┘   │
                                                  └────────────────────────────┘
                                                        Terraform provisions ──►
```

---

## The Full DevOps Workflow — Step by Step

Here is the **complete journey** from a developer writing code to it running in production:

### Step 1: Developer writes code
A developer edits `app/main.py` (the FastAPI todo application) and pushes to `main` branch.

### Step 2: GitHub Actions CI triggers
The push triggers the `.github/workflows/ci-cd.yaml` pipeline (path filter: `app/main.py`, `app/Dockerfile`, `app/requirements.txt`). It runs:
- **Pylint** — checks code quality (min score: 7.0/10)
- **Trivy** — scans for CRITICAL/HIGH security vulnerabilities
- **Docker Build & Push** — builds the image and pushes it to Docker Hub, tagged with the Git commit SHA

### Step 3: GitHub Actions updates the manifest (GitOps update)
After a successful push, the CI pipeline:
1. Uses `yq` to update `k8s/apps/todo-app/values.yaml` — sets `image.tag` to the new commit SHA
2. Commits and pushes the manifest change back to GitHub

### Step 4: Argo CD detects the manifest change
Argo CD continuously polls the GitHub repo. It detects that `values.yaml` has a new image tag and the cluster state no longer matches Git. It marks the app as **OutOfSync**.

### Step 5: Argo CD syncs the cluster
Argo CD applies the updated Helm chart to Kubernetes. Because the app uses **Argo Rollouts** (not a standard Deployment), the new version is deployed as a **canary**:
- 20% of traffic goes to the new version
- After 30 seconds, 50% goes to new version
- The old version is fully replaced

### Step 6: New version serves production traffic
The NGINX Ingress Controller routes `http://tapan-gitops-app.eastus2.cloudapp.azure.com/` to the stable pod. The canary becomes the new stable. Users never see downtime.

---

## Terraform — Infrastructure as Code

**Location**: `terraform/`

Terraform uses **HCL (HashiCorp Configuration Language)** to describe cloud infrastructure. Think of it as a blueprint for your cloud resources.

### How Terraform works

```
terraform init    # Download providers (Azure, Helm, etc.)
terraform plan    # Preview what will change (dry run)
terraform apply   # Create/update real infrastructure
terraform destroy # Tear down everything
```

**State file**: Terraform keeps a `.tfstate` file that tracks what it has already created. In this project, the state file is stored in **Azure Blob Storage** (remote backend) so it can be shared across machines and locked to prevent concurrent edits.

### What this project provisions

#### `terraform/providers.tf` — Cloud Provider Configuration
Configures the tools Terraform uses:
- `azurerm` — Azure Resource Manager (creates VMs, networks, AKS)
- `helm` — installs Helm charts into Kubernetes
- `kubernetes` + `kubectl` — applies raw Kubernetes manifests
- `random` — generates unique names (used for the storage account name)

**Remote backend** (state stored in Azure):
```hcl
backend "azurerm" {
  resource_group_name  = "devops-portfolio-rg"
  storage_account_name = "tfstate1769048995"
  container_name       = "tfstate"
  key                  = "terraform.tfstate"
}
```
> Why? If state is on your laptop and your laptop dies, you lose track of what Terraform created. Remote state fixes this.

#### `terraform/main.tf` — The AKS Cluster
```
Azure Resource Group
└── AKS Cluster (devops-portfolio-aks)
    └── Default Node Pool
        ├── 1 node (Standard_B2s — 2 vCPU, 4GB RAM)
        └── OS disk: 30GB
```
The cluster uses Azure's managed identity for authentication — no passwords to manage.

#### `terraform/addons.tf` — Helm Charts installed by Terraform
After the cluster is created, Terraform installs three foundational components via Helm:

| Helm Release | Chart | What it does |
|---|---|---|
| `ingress-nginx` | ingress-nginx/ingress-nginx v4.8.3 | Exposes services to the internet via a Load Balancer |
| `argocd` | argo/argo-cd v5.46.7 | GitOps engine that keeps K8s in sync with Git |
| `argo-rollouts` | argo/argo-rollouts v2.32.0 | Enables canary/blue-green deployments |

**Why install with Terraform and not Argo CD?**
These are the "bootstrapping" tools — you can't use Argo CD to install Argo CD (chicken-and-egg problem). Terraform installs the foundation; Argo CD manages everything else.

#### `terraform/variables.tf` and `terraform.tfvars`
Variables make the Terraform code reusable:
```hcl
# variables.tf defines the shape
variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus2"
}

# terraform.tfvars provides the actual values
location     = "eastus2"
cluster_name = "devops-portfolio-aks"
node_count   = 1
```

---

## Kubernetes — Container Orchestration

Kubernetes (K8s) is a platform for **running and managing containers at scale**. Instead of running `docker run` manually, you declare what you want and Kubernetes makes it happen.

### Mental model
```
Kubernetes Cluster
└── Nodes (Virtual Machines)
    └── Pods (one or more containers running together)
        └── Containers (your actual app code)
```

### Core Kubernetes Objects Used in This Project

#### Pod
The smallest deployable unit. A Pod wraps one or more containers and gives them a shared network namespace and storage.

```
Pod: todo-app-xxxx
├── Container: todo-app (FastAPI server on port 3000)
└── Environment Variables: DB_HOST, REDIS_HOST, DB_PASSWORD (from Secret)
```

#### Rollout (Argo Rollouts — replaces Deployment)
A standard Kubernetes `Deployment` replaces all pods at once (risky). An **Argo Rollout** lets you do a **canary deployment** — gradually shift traffic to the new version.

```yaml
# k8s/apps/todo-app/templates/rollout.yaml
strategy:
  canary:
    canaryService: todo-app-canary   # 20% of traffic goes here (new version)
    stableService: todo-app-stable   # 80% stays here (old version)
    steps:
      - setWeight: 20    # Route 20% to canary
      - pause: {duration: 30s}
      - setWeight: 50    # Route 50% to canary
      - pause: {duration: 10s}
      # After this, new version becomes stable
```

#### Service
A Service gives a stable DNS name and IP to a set of Pods. Pods are ephemeral (they get new IPs when restarted); Services are stable.

This project creates **two Services** for the todo app:
- `todo-app-stable` — always points to the running stable version
- `todo-app-canary` — points to the new version being tested

```
External traffic ──► NGINX Ingress ──► todo-app-stable Service ──► stable Pods
                                   └──► todo-app-canary Service ──► new Pods (20%)
```

#### Ingress
An Ingress object defines **HTTP routing rules** — which domain/path goes to which Service.

```yaml
# k8s/apps/todo-app/templates/ingress.yaml
rules:
  - host: tapan-gitops-app.eastus2.cloudapp.azure.com
    http:
      paths:
        - path: /
          backend:
            service:
              name: todo-app-stable
              port: 80
```
The **NGINX Ingress Controller** reads this and programs NGINX to route traffic accordingly.

#### ConfigMap and Secret
- **ConfigMap**: Non-sensitive configuration (environment variables, config files)
- **Secret**: Sensitive data (passwords, API keys) stored base64-encoded

```yaml
# postgres-postgresql secret (created by the PostgreSQL Helm chart)
# Referenced in rollout.yaml:
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-postgresql
        key: postgres-password
```

#### Namespace
Namespaces are virtual clusters within a cluster — a way to isolate workloads:

| Namespace | Contents |
|---|---|
| `default` | Todo app, Analytics worker |
| `argocd` | Argo CD components |
| `argo-rollouts` | Argo Rollouts controller |
| `ingress-nginx` | NGINX Ingress Controller |
| `monitoring` | Prometheus, Grafana |

#### Helm Application (Argo CD CRD)
Argo CD extends Kubernetes with custom resources. An `Application` tells Argo CD "watch this Git path and sync it to this namespace":

```yaml
# k8s/projects/todo.yaml (simplified)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: todo-app
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/potdartapan/gitops-project.git
    path: k8s/apps/todo-app        # Watch this folder
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true       # Delete resources removed from Git
      selfHeal: true    # Re-apply if someone manually changes the cluster
```

---

### Kubernetes Networking

```
Internet
   │
   ▼
Azure Load Balancer (Public IP: tapan-gitops-app.eastus2.cloudapp.azure.com)
   │  Created automatically when NGINX is installed
   ▼
NGINX Ingress Controller Pod (namespace: ingress-nginx)
   │  Reads Ingress objects and routes by path
   │
   ├── /          ──► todo-app-stable:80 ──► todo-app Pod:3000
   ├── /argocd    ──► argocd-server:80   ──► Argo CD UI
   └── /grafana   ──► grafana:80         ──► Grafana dashboard
```

**How DNS works:**
The Azure Load Balancer gets a public IP. A DNS label `tapan-gitops-app` is assigned to it in Azure, giving us `tapan-gitops-app.eastus2.cloudapp.azure.com`.

**How pods find each other (internal DNS):**
Kubernetes has a built-in DNS server (CoreDNS). Every Service gets a DNS name:
- `postgres-postgresql.default.svc.cluster.local` (or just `postgres-postgresql` within the same namespace)
- `redis-master.default.svc.cluster.local`

This is why the app's environment variables are:
```
DB_HOST=postgres-postgresql
REDIS_HOST=redis-master
```

---

### Databases & Storage in Kubernetes

#### PostgreSQL (Bitnami Helm Chart)
**Location**: `k8s/infra/postgres.yaml`

PostgreSQL is deployed using the Bitnami Helm chart, configured as an Argo CD `Application`:

```yaml
helm:
  chart: postgresql
  version: 18.2.0
  repoURL: https://charts.bitnami.com/bitnami
  parameters:
    - name: auth.postgresPassword
      value: mysecretpassword
    - name: primary.initdb.scripts.init\.sql
      value: |
        CREATE DATABASE tododb;
        CREATE DATABASE analytics_db;
```

Two databases are created on startup:
- `tododb` — stores todo items (used by `app/main.py`)
- `analytics_db` — stores analytics metrics (used by `analytics-worker/main.py`)

**Persistent storage**: PostgreSQL uses a **PersistentVolumeClaim (PVC)** — Kubernetes asks Azure to provision a managed disk so data survives pod restarts.

#### Redis (Bitnami Helm Chart)
**Location**: `k8s/infra/redis.yaml`

Redis serves two roles in this project:
1. **Cache** — fast in-memory data store
2. **Event Stream** — message bus between the todo app and analytics worker

```
Todo App ──► XADD todo_events ──► Redis Stream ──► XREADGROUP ──► Analytics Worker
             (publishes event)                      (consumes event)
```

Redis is configured in standalone mode (single node) with persistence disabled (data in memory only — acceptable for a stream).

---

### Argo Rollouts — Progressive Delivery (Canary Deployments)

**Why canary deployments?**
If you deploy a broken version to 100% of users, everyone is affected. With canary deployments, you first send only 20% of users to the new version. If metrics look good, promote to 100%. If something breaks, only 20% of users were impacted, and you roll back instantly.

**How it works in this project:**

```
                 ┌─── NGINX ───┐
                 │             │
                 │  80% traffic│  20% traffic
                 ▼             ▼
          todo-app-stable   todo-app-canary
          (old version)     (new version)
               │                │
               ▼                ▼
           old Pods          new Pods
```

The rollout progression:
```
Step 1: Deploy new version → send 20% traffic to it
Step 2: Wait 30 seconds (observe metrics / error rates)
Step 3: Increase to 50% traffic
Step 4: Wait 10 seconds
Step 5: Promote — new version becomes stable, old pods terminate
```

If anything goes wrong, run `kubectl argo rollouts abort <rollout-name>` to instantly route 100% back to the stable version.

---

## Argo CD — GitOps Continuous Delivery

Argo CD is the "sync engine" of this GitOps project. It watches the Git repository and ensures the Kubernetes cluster always matches what's declared in Git.

### The App-of-Apps Pattern

This project uses the **app-of-apps** pattern — a powerful Argo CD design:

```
root-app (Bootstrap)
└── Watches: k8s/projects/
    ├── todo.yaml      ──► deploys k8s/apps/todo-app/
    ├── infra.yaml     ──► deploys k8s/infra/ (postgres, redis)
    └── monitoring.yaml ──► deploys k8s/monitoring/
```

**How bootstrapping works:**
1. Terraform installs Argo CD into the cluster
2. Terraform also applies `k8s/bootstrap/root-app.yaml` using `kubectl`
3. `root-app` is an Argo CD Application that watches `k8s/projects/`
4. Argo CD sees the 3 Application YAMLs in `k8s/projects/` and creates them
5. Each Application then syncs its own folder — the entire cluster self-configures

### Auto-sync vs Manual Sync

```yaml
syncPolicy:
  automated:
    prune: true     # Remove K8s resources that no longer exist in Git
    selfHeal: true  # If someone manually edits the cluster, Argo CD reverts it
```

`selfHeal: true` is a key GitOps feature — it makes Git the authoritative truth. Any manual `kubectl edit` will be overwritten within minutes.

### Sync Ignore Rules

Some Kubernetes objects change dynamically at runtime (webhook CA certificates, etc.). Without ignore rules, Argo CD would constantly try to revert these.

```yaml
# k8s/monitoring/prometheus.yaml (Argo CD Application)
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jsonPointers:
      - /webhooks/0/clientConfig/caBundle
```
This tells Argo CD: "Don't consider this field when checking for drift."

---

## GitHub Actions — CI/CD Pipelines

**Location**: `.github/workflows/`

There are three pipelines, each with a specific responsibility:

### 1. Application CI/CD (`ci-cd.yaml`)

**Triggers**: Any push to `main` that changes `app/main.py`, `app/Dockerfile`, or `app/requirements.txt`

```
Push to main
     │
     ├── Job 1: lint
     │   └── pylint app/main.py (fails if score < 7.0)
     │
     ├── Job 2: security-scan
     │   └── Trivy scan for CRITICAL/HIGH CVEs in filesystem
     │
     └── Job 3: build-push-update (runs after jobs 1 & 2 pass)
         ├── docker build -t potdartapan/todo-app:${{ github.sha }} ./app
         ├── docker push potdartapan/todo-app:${{ github.sha }}
         └── yq e '.image.tag = "$SHA"' k8s/apps/todo-app/values.yaml
             └── git commit & push "Update image tag to $SHA"
                        │
                        ▼
                 Argo CD detects change, syncs cluster
```

**What is `github.sha`?**
Every Git commit has a unique SHA hash (e.g., `746beef66066f9f66282858b28c78ddb4faf8fbe`). Using this as the Docker image tag means:
- Every image is uniquely identifiable
- You can always tell exactly which code is running in production
- Rolling back = pointing the image tag to a previous SHA

### 2. Analytics Worker CI (`analytics-ci.yaml`)

Identical flow to the app pipeline, but:
- Triggers on changes to `app/analytics-worker/**`
- Builds `potdartapan/analytics-worker:${{ github.sha }}`
- Updates the image in `k8s/apps/analytics-worker/rollout.yaml` directly (not via Helm values)

### 3. Infrastructure Pipeline (`infra.yaml`)

**Triggers**: Manual only (`workflow_dispatch`) with a choice: `apply` or `destroy`

```
Manual trigger (apply or destroy)
         │
         ▼
   Configure Azure credentials
   (ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_SUBSCRIPTION_ID, ARM_TENANT_ID)
         │
         ├── if destroy: Pre-cleanup
         │   ├── az login
         │   ├── Remove Helm namespaces (ingress-nginx, argocd, argo-rollouts)
         │   ├── Remove Terraform state entries for those releases
         │   └── Wait 45s for Azure Load Balancer to be released
         │
         ├── terraform init
         │
         ├── terraform apply -auto-approve   (or destroy)
         │
         └── if apply: Post-setup
             ├── az aks get-credentials
             ├── Wait for NGINX LoadBalancer external IP
             ├── Extract ArgoCD admin password from K8s secret
             └── Print access URLs
```

**Why pre-cleanup before destroy?**
NGINX created an Azure Load Balancer as a side effect. Terraform doesn't own that Load Balancer — it was created by Kubernetes. If you run `terraform destroy` directly, it tries to delete the Resource Group while the Load Balancer is still attached, causing an error. The pre-cleanup deletes the K8s resources first, which causes Azure to release the Load Balancer, then Terraform can cleanly destroy everything.

### Secrets Management in GitHub Actions

All sensitive values are stored as **GitHub Actions Secrets** (Settings → Secrets and Variables → Actions):

| Secret | Used for |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub login |
| `DOCKERHUB_TOKEN` | Docker Hub login |
| `ARM_CLIENT_ID` | Azure Service Principal |
| `ARM_CLIENT_SECRET` | Azure Service Principal |
| `ARM_SUBSCRIPTION_ID` | Azure account identifier |
| `ARM_TENANT_ID` | Azure directory identifier |
| `GIT_TOKEN` | Push manifest changes back to repo |

---

## Monitoring — Prometheus & Grafana

**Location**: `k8s/monitoring/prometheus.yaml`

Monitoring is deployed via the **kube-prometheus-stack** Helm chart (v69.3.0), which bundles Prometheus + Grafana + many pre-built dashboards.

### Prometheus

Prometheus is a **metrics database**. It works by "scraping" (polling) HTTP endpoints at regular intervals. Kubernetes pods expose metrics at `/metrics`; Prometheus collects and stores them as time-series data.

```
Kubernetes Pods
(expose /metrics)
       │
       │ HTTP scrape every 15s
       ▼
   Prometheus
   (stores metrics)
       │
       │ query (PromQL)
       ▼
    Grafana
   (visualize)
```

**What Prometheus collects:**
- CPU and memory usage per pod
- HTTP request rates and latencies
- Pod restart counts
- Node resource usage

**Resource limits** (important for a single-node cluster):
```yaml
prometheus:
  prometheusSpec:
    retention: 2d          # Only keep 2 days of data (saves disk)
    resources:
      requests: { memory: 256Mi }
      limits:   { memory: 512Mi }
```

### Grafana

Grafana is the **visualization layer** — it connects to Prometheus and displays dashboards.

- **Access**: `http://tapan-gitops-app.eastus2.cloudapp.azure.com/grafana`
- **Credentials**: admin / admin
- Pre-built dashboards show cluster-wide metrics, node health, and pod performance

**Subpath configuration** (how `/grafana` routing works):
```yaml
grafana:
  env:
    GF_SERVER_ROOT_URL: "http://tapan-gitops-app.eastus2.cloudapp.azure.com/grafana"
    GF_SERVER_SERVE_FROM_SUB_PATH: "true"
```
Without this, Grafana would generate internal links assuming it's at `/`, breaking navigation when behind NGINX at `/grafana`.

### Disabled Components
To save memory on the single-node cluster:
- AlertManager (alert routing) — disabled
- kube-state-metrics (detailed K8s object metrics) — disabled
- node-exporter (OS-level metrics) — disabled

---

## Application Architecture

### Todo App (`app/main.py`)

A **FastAPI** (Python) REST API with a web UI.

```
Browser ──► GET / ──► serve index.html (static file)
Browser ──► GET /todos ──► query PostgreSQL → return JSON list
Browser ──► POST /todos ──► insert into PostgreSQL → return new item
Browser ──► PUT /todos/{id} ──► update PostgreSQL → publish to Redis Stream
Browser ──► DELETE /todos/{id} ──► delete from PostgreSQL
```

**PostgreSQL connection with retry logic:**
```python
# Retries 10 times with 3-second intervals
# Needed because on startup, the app pod may start before PostgreSQL is ready
for i in range(10):
    try:
        engine = create_engine(DATABASE_URL)
        break
    except Exception:
        time.sleep(3)
```

**Redis event publishing (on task completion):**
```python
# When a todo is marked complete, publish an event
redis_client.xadd("todo_events", {
    "event": "task_completed",
    "task_id": str(todo_id)
})
```

### Analytics Worker (`app/analytics-worker/main.py`)

A background Python worker that consumes events from the Redis Stream.

```
Redis Stream: "todo_events"
        │
        │ XREADGROUP (consumer group: analytics_group)
        ▼
   Analytics Worker
        │
        ▼
   PostgreSQL: analytics_db
   UPDATE metrics SET event_count = event_count + 1
        │
        │ XACK (acknowledge — mark as processed)
        ▼
   Next message
```

**Why a consumer group?**
Consumer groups allow multiple workers to process different messages in parallel (horizontal scaling). If one worker crashes, its unacknowledged messages are redelivered to another worker.

### Event-Driven Flow (End to End)

```
User marks todo "Complete"
         │
         ▼
  PUT /todos/42 API call
         │
         ├── UPDATE todos SET completed=true WHERE id=42
         │
         └── XADD todo_events {event: "task_completed", task_id: "42"}
                       │
                       │ (async, decoupled)
                       ▼
              Analytics Worker polls
                       │
                       ├── UPDATE metrics SET count = count + 1
                       └── XACK todo_events (mark processed)
```

---

## Directory Structure Reference

```
GitOps/
├── .github/
│   └── workflows/
│       ├── ci-cd.yaml           # App build pipeline
│       ├── analytics-ci.yaml    # Analytics worker build pipeline
│       └── infra.yaml           # Terraform apply/destroy (manual)
│
├── app/                         # Application source code
│   ├── Dockerfile               # App container image
│   ├── main.py                  # FastAPI todo app
│   ├── requirements.txt         # Python dependencies
│   ├── docker-compose.yaml      # Local dev (app + postgres)
│   ├── analytics-worker/
│   │   ├── Dockerfile           # Worker container image
│   │   ├── main.py              # Redis Stream consumer
│   │   └── requirements.txt
│   └── static/
│       ├── index.html           # Frontend UI
│       └── style.css
│
├── k8s/                         # All Kubernetes manifests
│   ├── bootstrap/
│   │   └── root-app.yaml        # Argo CD bootstrap: App-of-Apps entry point
│   │
│   ├── projects/                # Argo CD Application definitions
│   │   ├── todo.yaml            # Declares todo-app Argo CD Application
│   │   ├── infra.yaml           # Declares infra Argo CD Application (postgres, redis)
│   │   └── monitoring.yaml      # Declares monitoring Argo CD Application
│   │
│   ├── apps/
│   │   ├── todo-app/            # Helm chart for the todo app
│   │   │   ├── Chart.yaml       # Chart metadata
│   │   │   ├── values.yaml      # Default values (image tag updated by CI/CD)
│   │   │   └── templates/
│   │   │       ├── rollout.yaml # Argo Rollout (canary deployment)
│   │   │       ├── service.yaml # Stable + canary Services
│   │   │       └── ingress.yaml # NGINX Ingress routing
│   │   └── analytics-worker/
│   │       └── rollout.yaml     # Analytics worker canary rollout
│   │
│   ├── infra/
│   │   ├── postgres.yaml        # PostgreSQL Argo CD Application (Bitnami Helm)
│   │   ├── redis.yaml           # Redis Argo CD Application (Bitnami Helm)
│   │   └── argocd-ingress.yaml  # NGINX Ingress for Argo CD UI
│   │
│   └── monitoring/
│       └── prometheus.yaml      # kube-prometheus-stack Argo CD Application
│
├── terraform/                   # Infrastructure as Code
│   ├── providers.tf             # Azure, Helm, K8s providers + remote state backend
│   ├── main.tf                  # AKS cluster + resource group
│   ├── addons.tf                # NGINX, Argo CD, Argo Rollouts (Helm installs)
│   ├── variables.tf             # Input variable definitions
│   ├── outputs.tf               # Output values (cluster name, credential command)
│   └── terraform.tfvars         # Actual values for variables
│
└── sonar-project.properties     # SonarQube code quality scan config
```

---

## How Everything Connects

Here's the **complete relationship map** between all the tools:

```
PROVISION                    BOOTSTRAP                   OPERATE
─────────                    ─────────                   ───────

Terraform                    Argo CD                     GitHub Actions
    │                        (installed by Terraform)         │
    ├── Creates AKS              │                            ├── On code push:
    ├── Creates Node Pool        ├── Watches k8s/projects/    │   ├── Lint & scan
    ├── Installs NGINX ◄─────────┤── Manages NGINX Ingress   │   ├── Build Docker image
    ├── Installs Argo CD         ├── Deploys PostgreSQL       │   ├── Push to Docker Hub
    ├── Installs Argo Rollouts   ├── Deploys Redis            │   └── Update values.yaml
    └── Applies root-app.yaml   ├── Deploys todo-app ◄───────┘       (new image tag)
              │                 ├── Deploys analytics-worker              │
              │                 └── Deploys Prometheus+Grafana            │
              ▼                              │                            │
    Argo CD root-app                         │ detects change             │
    (App-of-Apps)                            ◄────────────────────────────┘
         │
         ▼
    Self-configures
    entire cluster
    from Git state
```

**The GitOps feedback loop:**

```
1. Developer pushes code
         │
2. GitHub Actions builds & pushes image
         │
3. GitHub Actions updates manifest (image tag)
         │
4. Argo CD detects manifest drift
         │
5. Argo CD syncs cluster state
         │
6. Argo Rollouts gradually shifts traffic
         │
7. Prometheus scrapes new pod metrics
         │
8. Grafana displays health dashboards
         │
9. All state is in Git ──► back to step 1
```

---

## Key DevOps Concepts Demonstrated

| Concept | Implementation |
|---|---|
| **Infrastructure as Code** | Terraform provisions AKS, Helm installs |
| **GitOps** | Argo CD syncs Git state to cluster |
| **CI/CD** | GitHub Actions builds, tests, deploys |
| **Progressive Delivery** | Argo Rollouts canary deployments |
| **Container Orchestration** | Kubernetes manages all workloads |
| **Service Discovery** | Kubernetes internal DNS (CoreDNS) |
| **Ingress Routing** | NGINX routes traffic by path |
| **Event-Driven Architecture** | Redis Streams for async communication |
| **Observability** | Prometheus metrics + Grafana dashboards |
| **Secret Management** | Kubernetes Secrets + GitHub Actions Secrets |
| **Immutable Deployments** | Image tags pinned to Git SHA |
| **Self-Healing** | Argo CD selfHeal reverts manual changes |
| **Package Management** | Helm charts for complex K8s apps |
| **Remote State** | Terraform state in Azure Blob Storage |

---

*Built as a DevOps learning portfolio. Stack: Azure AKS · Terraform · Argo CD · Argo Rollouts · GitHub Actions · Helm · Prometheus · Grafana · FastAPI · PostgreSQL · Redis*
