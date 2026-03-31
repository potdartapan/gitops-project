# Kubernetes Structure — Analysis & Improvement Proposals

## Table of Contents
1. [Current Structure](#current-structure)
2. [What is Working Well](#what-is-working-well)
3. [Issues Identified](#issues-identified)
4. [Proposed Structure](#proposed-structure)
5. [Change-by-Change Rationale](#change-by-change-rationale)
6. [Namespace Strategy](#namespace-strategy)
7. [Security Issues to Address](#security-issues-to-address)
8. [Migration Path](#migration-path)

---

## Current Structure

```
k8s/
├── bootstrap/
│   └── root-app.yaml
├── projects/
│   ├── infra.yaml
│   ├── monitoring.yaml
│   ├── otel-operator.yaml          ← Helm-based (lives here)
│   ├── tempo.yaml                  ← Helm-based (lives here)
│   ├── todo.yaml
│   └── tracing.yaml
├── apps/
│   ├── todo-app/                   ← Full Helm chart
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── rollout.yaml
│   │       ├── service.yaml
│   │       ├── ingress.yaml
│   │       └── servicemonitor.yaml
│   └── analytics-worker/           ← Just a raw rollout.yaml
│       └── rollout.yaml
├── infra/
│   ├── argocd-ingress.yaml         ← Raw K8s manifest
│   ├── postgres.yaml               ← ArgoCD App (Helm)
│   └── redis.yaml                  ← ArgoCD App (Helm)
├── monitoring/
│   ├── prometheus.yaml             ← ArgoCD App (Helm) — mixed with raw manifests
│   ├── todo-app-alerts.yaml        ← PrometheusRule CR
│   └── todo-app-dashboard.yaml     ← ConfigMap
└── tracing/
    ├── collector.yaml              ← OpenTelemetryCollector CR
    ├── instrumentation.yaml        ← Instrumentation CR
    └── tempo-datasource.yaml       ← ConfigMap
```

---

## What is Working Well

### App-of-Apps Pattern
The root-app → projects → workloads hierarchy is solid GitOps design. ArgoCD watches `k8s/projects/` and each file there creates a child Application. Changes to any layer are automatically reconciled. This is the correct pattern and should be kept.

### Helm Chart for todo-app
Using a Helm chart for todo-app (with `values.yaml`, templates, `Chart.yaml`) is the right approach. It provides templating, value overrides, and a clean separation between configuration and structure.

### Monitoring Separation
The `k8s/monitoring/` directory correctly isolates the monitoring concern. PrometheusRules and dashboards living alongside the stack config is reasonable at the current scale.

### Tracing Namespace Isolation
The `tracing` namespace for Tempo and the OTel Collector is correct — tracing infrastructure is isolated from application workloads.

### ServiceMonitor Inside App Chart
Keeping the `ServiceMonitor` inside the `todo-app` Helm chart (in `templates/`) is the right call. The ServiceMonitor is the app's contract with Prometheus — if the app is removed, its scrape config should go with it.

---

## Issues Identified

### Issue 1 — Inconsistent ArgoCD Application Placement

**Problem:**
`otel-operator.yaml` and `tempo.yaml` are ArgoCD Applications that deploy Helm charts, but they live in `k8s/projects/` — the same directory as the root app's App-of-Apps definitions. Meanwhile `postgres.yaml` and `redis.yaml`, which are also Helm-based ArgoCD Applications, live inside `k8s/infra/` and are managed by the `infra` child Application.

This creates two different patterns for the same thing:

```
Pattern A:  root-app → k8s/projects/otel-operator.yaml  (Helm ArgoCD App deployed directly)
Pattern B:  root-app → k8s/projects/infra.yaml → k8s/infra/postgres.yaml  (Helm ArgoCD App deployed via child)
```

**Impact:** When someone asks "where is the Tempo configuration?", they have to look in two places: `k8s/projects/tempo.yaml` (Helm values) and `k8s/tracing/` (CRs). When they ask "where is the PostgreSQL configuration?" — also two places: `k8s/infra/postgres.yaml` (Helm values) and... nowhere else. But the pattern is still different from Tempo.

**Fix:** Standardise. `k8s/projects/` should only contain the App-of-Apps child definitions. All Helm releases and their configs should live in their domain directories.

---

### Issue 2 — `k8s/projects/` Mixes Two Responsibilities

**Problem:**
`k8s/projects/` currently contains two types of files:
- **Type A:** App-of-Apps pointers (source = local path in this repo) — `infra.yaml`, `monitoring.yaml`, `todo.yaml`, `tracing.yaml`
- **Type B:** Directly deployed Helm releases (source = external Helm chart repo) — `otel-operator.yaml`, `tempo.yaml`

Type A files are navigation — they tell ArgoCD "go watch this directory". Type B files are configuration — they embed Helm values and deploy directly. Mixing them makes `k8s/projects/` ambiguous.

**Fix:** Move all Helm releases out of `k8s/projects/` and into their domain directories.

---

### Issue 3 — `analytics-worker` is Inconsistent with `todo-app`

**Problem:**
`todo-app` has a proper Helm chart with `Chart.yaml`, `values.yaml`, and `templates/`. `analytics-worker` is just a single raw `rollout.yaml` with hardcoded values:
- Image tag is hardcoded (`94795ad66211e16a0510a96ca6be4da9d6b6cfca`)
- Database password is hardcoded (`mysecretpassword`) directly in the manifest
- No `values.yaml` — you have to edit the rollout itself to change any config
- No ArgoCD Application pointing to it — it is deployed via the `infra` Application which deploys to `default` namespace... actually looking more closely, there is no ArgoCD Application that deploys `analytics-worker` at all. It is orphaned.

**Fix:** Give `analytics-worker` a Helm chart matching the `todo-app` pattern. Add an ArgoCD Application for it in `k8s/projects/`.

---

### Issue 4 — `prometheus.yaml` Filename is Misleading

**Problem:**
`k8s/monitoring/prometheus.yaml` actually deploys `kube-prometheus-stack`, which includes Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics. Naming it `prometheus.yaml` undersells what it is and makes it harder to find configuration for Grafana or Alertmanager (a developer looking for Alertmanager config would not naturally look in `prometheus.yaml`).

**Fix:** Rename to `kube-prometheus-stack.yaml`.

---

### Issue 5 — `k8s/monitoring/` Mixes a Helm Release with CRD Instances

**Problem:**
`k8s/monitoring/` contains three conceptually different things:
1. `prometheus.yaml` — An ArgoCD Application that deploys a Helm chart (the stack itself)
2. `todo-app-alerts.yaml` — A `PrometheusRule` CR (alert definitions)
3. `todo-app-dashboard.yaml` — A ConfigMap (dashboard JSON)

As the project grows, this directory will accumulate more rules, dashboards, and recording rules from multiple applications. There is no sub-structure to organise them.

**Fix:** Add subdirectories within `k8s/monitoring/`:
```
monitoring/
├── kube-prometheus-stack.yaml   ← Helm release ArgoCD App
├── rules/                       ← PrometheusRule CRs
│   └── todo-app.yaml
└── dashboards/                  ← Grafana ConfigMaps
    └── todo-app.yaml
```

---

### Issue 6 — `k8s/infra/argocd-ingress.yaml` is Misplaced

**Problem:**
`argocd-ingress.yaml` is an Ingress for the ArgoCD UI. It lives in `k8s/infra/` alongside PostgreSQL and Redis — mixing application infrastructure (databases) with platform infrastructure (access to tooling). If someone is looking for "how do I access ArgoCD", they would not look in the infra directory.

**Fix:** Move platform-level ingress/access config to a `platform/` directory.

---

### Issue 7 — Everything Runs in the `default` Namespace

**Problem:**
The todo-app, analytics-worker, PostgreSQL, Redis, and the `Instrumentation` CR all run in `default`. This means:
- No isolation between application workloads and data stores
- No RBAC boundary — a pod can theoretically talk to any other pod's service
- Difficult to apply different resource quotas to apps vs databases
- Kubernetes audit logs show all events under `default`, making them noisy

**Fix:** See [Namespace Strategy](#namespace-strategy) section.

---

### Issue 8 — Tracing CRDs Have No Logical Grouping

**Problem:**
`k8s/tracing/` contains three files with different concerns:
- `collector.yaml` — The Collector deployment (tracing infrastructure)
- `instrumentation.yaml` — How to auto-instrument Python apps (app concern)
- `tempo-datasource.yaml` — A Grafana datasource (monitoring concern — it is deployed to the `monitoring` namespace)

The `tempo-datasource.yaml` conceptually belongs to the monitoring layer (it configures Grafana), not the tracing layer. And `instrumentation.yaml` is an app-level concern (it defines how apps in `default` namespace get instrumented).

**Fix:** Move `tempo-datasource.yaml` to `k8s/monitoring/` and give `k8s/tracing/` a clearer scope.

---

## Proposed Structure

```
k8s/
│
├── bootstrap/                          # UNCHANGED — entry point
│   └── root-app.yaml
│
├── projects/                           # ONLY App-of-Apps pointers (no Helm values)
│   ├── apps.yaml                       # → k8s/apps/
│   ├── platform.yaml                   # → k8s/platform/
│   ├── monitoring.yaml                 # → k8s/monitoring/
│   └── tracing.yaml                    # → k8s/tracing/
│
├── apps/                               # Application workloads
│   ├── todo-app/                       # Helm chart (unchanged)
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── rollout.yaml
│   │       ├── service.yaml
│   │       ├── ingress.yaml
│   │       └── servicemonitor.yaml
│   └── analytics-worker/              # Helm chart (upgrade from raw manifest)
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           └── rollout.yaml
│
├── platform/                           # Infrastructure, operators, access
│   ├── databases/
│   │   ├── postgres.yaml              # ArgoCD App (Bitnami Helm chart)
│   │   └── redis.yaml                 # ArgoCD App (Bitnami Helm chart)
│   ├── ingress/
│   │   └── argocd-ingress.yaml        # Ingress for ArgoCD UI
│   └── operators/
│       └── otel-operator.yaml         # ArgoCD App (OTel Operator Helm chart)
│
├── monitoring/                         # Monitoring stack
│   ├── kube-prometheus-stack.yaml     # ArgoCD App (Helm) — renamed from prometheus.yaml
│   ├── rules/                         # PrometheusRule CRs
│   │   └── todo-app.yaml
│   └── dashboards/                    # Grafana dashboard ConfigMaps + datasource ConfigMaps
│       ├── todo-app.yaml
│       └── tempo-datasource.yaml      # Moved from k8s/tracing/
│
└── tracing/                            # Tracing stack
    ├── tempo.yaml                      # ArgoCD App (Grafana Tempo Helm chart)
    ├── collector.yaml                  # OpenTelemetryCollector CR
    └── instrumentation.yaml           # Instrumentation CR
```

### How ArgoCD Applications Map to Directories

```
bootstrap/root-app.yaml
    │
    └── watches: k8s/projects/
            │
            ├── apps.yaml ──────────────────► k8s/apps/
            │                                   todo-app/    (Helm chart)
            │                                   analytics-worker/ (Helm chart)
            │
            ├── platform.yaml ──────────────► k8s/platform/
            │                                   databases/postgres.yaml  (ArgoCD App)
            │                                   databases/redis.yaml     (ArgoCD App)
            │                                   ingress/argocd-ingress.yaml
            │                                   operators/otel-operator.yaml (ArgoCD App)
            │
            ├── monitoring.yaml ────────────► k8s/monitoring/
            │                                   kube-prometheus-stack.yaml (ArgoCD App)
            │                                   rules/todo-app.yaml
            │                                   dashboards/todo-app.yaml
            │                                   dashboards/tempo-datasource.yaml
            │
            └── tracing.yaml ───────────────► k8s/tracing/
                                                tempo.yaml         (ArgoCD App)
                                                collector.yaml     (OTel CR)
                                                instrumentation.yaml (OTel CR)
```

---

## Change-by-Change Rationale

### 1. Collapse `projects/` to Four Files

**Before:** 6 files mixing App-of-Apps pointers and direct Helm releases
**After:** 4 files, all App-of-Apps pointers only

The four files map cleanly to the four domains of the system:
| File | Domain | What it manages |
|------|--------|----------------|
| `apps.yaml` | Workloads | todo-app, analytics-worker |
| `platform.yaml` | Infrastructure | databases, operators, ingress |
| `monitoring.yaml` | Observability/Metrics | Prometheus, Grafana, Alertmanager, rules, dashboards |
| `tracing.yaml` | Observability/Traces | Tempo, OTel Collector, Instrumentation |

When someone joins the project, they read `k8s/projects/` first. Four files with clear names tell the full story immediately.

---

### 2. Introduce `k8s/platform/`

**Before:** `k8s/infra/` with mixed concerns — Helm-based ArgoCD Apps (postgres, redis) alongside a raw K8s manifest (argocd-ingress), and operators living in `k8s/projects/`

**After:** `k8s/platform/` with three subdirectories:

```
platform/
├── databases/    — stateful services the apps depend on
├── ingress/      — how tooling (ArgoCD, Rollouts) is exposed externally
└── operators/    — Kubernetes operators that extend the API
```

**Why `platform/` instead of `infra/`?**
"Infrastructure" is vague. "Platform" more accurately describes what this layer is — the services and operators that your applications run *on top of*, managed by the platform/ops team rather than the app team.

The `operators/` subdirectory is particularly important: as you add more operators (cert-manager, Sealed Secrets, etc.) they have a clear home.

---

### 3. Rename `prometheus.yaml` → `kube-prometheus-stack.yaml`

The file deploys the full `kube-prometheus-stack` Helm chart which includes:
- Prometheus
- Grafana
- Alertmanager
- kube-state-metrics
- node-exporter
- Prometheus Operator

The name `prometheus.yaml` implies it only configures Prometheus. If someone needs to find the Alertmanager Discord config, they search for `alertmanager` — not `prometheus`. The accurate filename avoids this confusion.

---

### 4. Subdirectories in `monitoring/`

**Before:** Three files flat in `monitoring/` — mixing the Helm release, alert rules, and dashboards

**After:**
```
monitoring/
├── kube-prometheus-stack.yaml    ← The stack itself
├── rules/                        ← Alert definitions (PrometheusRule CRs)
│   └── todo-app.yaml
└── dashboards/                   ← Grafana config (ConfigMaps)
    ├── todo-app.yaml
    └── tempo-datasource.yaml
```

**Why subdirectories here but not in tracing?**
Monitoring will grow. Every new service you add will get its own `rules/` entry and `dashboards/` entry. Without subdirectories, `k8s/monitoring/` becomes a flat list of 20 files with no clear grouping. Tracing grows more slowly (one collector, one stack) so subdirectories are not needed there yet.

**Why move `tempo-datasource.yaml` from tracing to monitoring?**
The Tempo datasource is a Grafana configuration. It lives in the `monitoring` namespace and is consumed by Grafana. When a new developer looks for "what datasources does Grafana have?", they look in `k8s/monitoring/dashboards/` — not `k8s/tracing/`. The tracing directory is for tracing *infrastructure* (Tempo itself, the Collector, Instrumentation). Grafana's view of that infrastructure belongs to monitoring.

---

### 5. Move Tempo to `k8s/tracing/`

**Before:** `k8s/projects/tempo.yaml` — the Helm values for Tempo sit in the projects directory alongside App-of-Apps pointers

**After:** `k8s/tracing/tempo.yaml` — all Tempo-related config in one place

When someone works on the tracing stack, they open `k8s/tracing/` and see:
```
tempo.yaml            ← the backend (Helm release config)
collector.yaml        ← the collector pipeline
instrumentation.yaml  ← how apps get instrumented
```
This is the complete tracing story in one directory.

---

### 6. Give `analytics-worker` a Helm Chart

**Before:** Single raw `rollout.yaml` with hardcoded values and a hardcoded password

**After:** Helm chart matching the `todo-app` pattern:
```
analytics-worker/
├── Chart.yaml
├── values.yaml         ← image tag, resource limits, env config
└── templates/
    └── rollout.yaml    ← templated, no hardcoded values
```

Benefits:
- Image tag managed in `values.yaml`, updated by CI the same way as `todo-app`
- Password referenced from a Secret, not hardcoded
- Consistent pattern — a developer who understands `todo-app` immediately understands `analytics-worker`
- Can be independently synced by ArgoCD

Also: `analytics-worker` currently has **no ArgoCD Application pointing to it**. It is effectively unmanaged by GitOps. A new `apps.yaml` project pointing to `k8s/apps/` would fix this.

---

## Namespace Strategy

### Current State
| Workload | Namespace |
|----------|-----------|
| todo-app | `default` |
| analytics-worker | `default` |
| PostgreSQL | `default` |
| Redis | `default` |
| Instrumentation CR | `default` |
| Prometheus, Grafana, Alertmanager | `monitoring` |
| Tempo, OTel Collector | `tracing` |
| OTel Operator | `opentelemetry-operator` |
| ArgoCD | `argocd` |

Everything in `default` creates a single flat namespace with no isolation.

### Proposed Namespace Model

```
apps         → todo-app, analytics-worker
data         → PostgreSQL, Redis
monitoring   → Prometheus, Grafana, Alertmanager (unchanged)
tracing      → Tempo, OTel Collector (unchanged)
```

`default` is only used for the `Instrumentation` CR, which must be in the same namespace as the app pods. If apps move to `apps` namespace, the Instrumentation CR moves with them.

### Why Separate `apps` from `data`?

1. **RBAC boundary** — app pods should not need access to the database's Kubernetes secrets or service account tokens. Separate namespaces allow separate RBAC policies.
2. **Resource quotas** — you can put a tighter CPU quota on `apps` and a looser one on `data` (databases legitimately need burst CPU; apps generally should not).
3. **Network policies** — you can write a NetworkPolicy that says "only pods in `apps` namespace can talk to services in `data` namespace" — zero-trust networking within the cluster.
4. **Easier debugging** — `kubectl get pods -n apps` shows only your application pods, not interleaved with database pods.

### Migration Note
Moving apps from `default` to a new namespace requires updating:
- `destination.namespace` in the ArgoCD Application for todo-app
- The `Instrumentation` CR namespace
- Any hardcoded namespace references in alert rules (`todo-app-alerts.yaml`)
- The ServiceMonitor's `namespaceSelector`

---

## Security Issues to Address

These are separate from structure but were identified during the review. Listed here for completeness.

### Critical
| Issue | Location | Fix |
|-------|----------|-----|
| PostgreSQL password hardcoded | `k8s/infra/postgres.yaml`, `k8s/apps/analytics-worker/rollout.yaml` | Use a Kubernetes Secret or Sealed Secret |
| Discord webhook URL in plaintext | `k8s/monitoring/kube-prometheus-stack.yaml` | Sealed Secret or external secret operator |
| Grafana admin password is `"admin"` | `k8s/monitoring/kube-prometheus-stack.yaml` | Change and store in a Secret |

### Minor
| Issue | Location | Fix |
|-------|----------|-----|
| Redis using `latest` image tag | `k8s/platform/databases/redis.yaml` | Pin to a specific version e.g. `7.2.4` |
| Redis has no resource limits | `k8s/platform/databases/redis.yaml` | Add `resources.requests` and `resources.limits` |
| Tempo on local disk storage | `k8s/tracing/tempo.yaml` | Point to Azure Blob Storage for durability |
| 100% trace sampling | `k8s/tracing/instrumentation.yaml` | Reduce to 10-20% when traffic increases |

---

## Migration Path

The proposed changes are mostly renames and moves — no change to what gets deployed, only to how the repository is organised. Here is a safe order of operations:

### Step 1 — Rename `prometheus.yaml`
Lowest risk. Rename the file and update the `source.path` in `k8s/projects/monitoring.yaml`.

### Step 2 — Add subdirectories to `monitoring/`
Move `todo-app-alerts.yaml` → `rules/todo-app.yaml` and `todo-app-dashboard.yaml` → `dashboards/todo-app.yaml`. ArgoCD watches the whole directory recursively so the move is transparent.

### Step 3 — Move `tempo-datasource.yaml` to `monitoring/dashboards/`
Update any namespace references if needed.

### Step 4 — Move Tempo to `k8s/tracing/`
Move `k8s/projects/tempo.yaml` to `k8s/tracing/tempo.yaml`. Remove the direct ArgoCD Application for Tempo from `projects/` — it becomes managed by the `tracing` ArgoCD Application instead. Update `k8s/projects/tracing.yaml` to source from `k8s/tracing/`. ArgoCD will prune the old Application and create the Tempo resources under the new one. Verify Tempo pod stays running during the transition.

### Step 5 — Introduce `k8s/platform/`
Create the directory. Move `k8s/infra/postgres.yaml` → `k8s/platform/databases/postgres.yaml`, `redis.yaml` similarly, `argocd-ingress.yaml` → `k8s/platform/ingress/argocd-ingress.yaml`, and `otel-operator.yaml` from `k8s/projects/` → `k8s/platform/operators/`. Update `k8s/projects/infra.yaml` to become `platform.yaml` pointing at `k8s/platform/`.

### Step 6 — Give `analytics-worker` a Helm chart
Create `k8s/apps/analytics-worker/` as a Helm chart. Update `k8s/projects/` so `apps.yaml` points at `k8s/apps/` (both `todo-app` and `analytics-worker`). Remove the current `todo.yaml` from projects.

### Step 7 — Namespace migration (optional, highest impact)
Move `todo-app` and `analytics-worker` to `apps` namespace. Move PostgreSQL and Redis to `data` namespace. This requires updating connection strings, ArgoCD destinations, and alert rules. Do this in a maintenance window and test connectivity after each move.

---

## Summary of Changes

| Change | Type | Risk | Value |
|--------|------|------|-------|
| Rename `prometheus.yaml` | Rename | Low | Medium — clarity |
| Add `monitoring/rules/` and `monitoring/dashboards/` subdirs | Restructure | Low | High — scalability |
| Move `tempo-datasource.yaml` to `monitoring/` | Move | Low | Medium — logical grouping |
| Move Tempo config to `k8s/tracing/` | Move + ArgoCD app update | Medium | High — consistency |
| Introduce `k8s/platform/` | Restructure | Medium | High — clarity |
| Collapse `projects/` to 4 files | Restructure | Medium | High — navigation |
| Give `analytics-worker` a Helm chart | New work | Medium | High — consistency, fixes orphaned deployment |
| Namespace segregation | New work | High | High — security, isolation |
