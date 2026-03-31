# Distributed Tracing — Deep Dive

## Table of Contents
1. [What is Distributed Tracing?](#what-is-distributed-tracing)
2. [Architecture Overview](#architecture-overview)
3. [Components Added](#components-added)
4. [CRDs Explained](#crds-explained)
5. [How the Pipeline Works End-to-End](#how-the-pipeline-works-end-to-end)
6. [Auto-Instrumentation — How the Magic Works](#auto-instrumentation--how-the-magic-works)
7. [Practical Use Cases](#practical-use-cases)
8. [Correlation: Traces + Metrics + Logs](#correlation-traces--metrics--logs)
9. [Glossary](#glossary)

---

## What is Distributed Tracing?

Metrics tell you **that** something is slow. Logs tell you **what happened**. Traces tell you **where in the chain** the time was spent.

A **trace** represents a single end-to-end request as it travels through your system. It is made up of **spans** — one span per operation (HTTP handler, database query, cache lookup, external API call). Each span records:

- **Operation name** — e.g. `GET /todos`, `SELECT todos`
- **Start time and duration**
- **Status** — OK or Error
- **Attributes** — key/value metadata (HTTP status code, DB query text, etc.)
- **Parent span ID** — what called this operation

A complete trace for a `GET /todos` request might look like:

```
Trace ID: 4bf92f3577b34da6
│
└── GET /todos  [12ms]  ← root span (FastAPI HTTP handler)
    ├── SELECT * FROM todos  [9ms]  ← child span (SQLAlchemy → PostgreSQL)
    └── serialize response   [1ms]  ← child span (Pydantic serialization)
```

Without tracing, if p99 latency spikes you know requests are slow but not *which* operation caused it. With tracing, you open the slow trace and see immediately: `SELECT * FROM todos` took 9ms because a full table scan was running without an index.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                            AKS Cluster                               │
│                                                                      │
│  namespace: default                                                  │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  todo-app pod                                               │    │
│  │                                                             │    │
│  │  ┌──────────────────────┐   ┌───────────────────────────┐  │    │
│  │  │ init container       │   │ todo-app container        │  │    │
│  │  │ (injected by OTel    │   │                           │  │    │
│  │  │  Operator)           │   │ FastAPI app               │  │    │
│  │  │                      │   │ + auto-instrumented       │  │    │
│  │  │ Installs Python OTel │   │   SQLAlchemy              │  │    │
│  │  │ SDK into shared vol  │   │   Redis                   │  │    │
│  │  └──────────────────────┘   └──────────┬────────────────┘  │    │
│  │                                        │ OTLP HTTP :4318   │    │
│  └────────────────────────────────────────│────────────────────┘   │
│                                           │                         │
│  namespace: tracing                       ▼                         │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                                                                │ │
│  │  ┌─────────────────────────┐     ┌────────────────────────┐   │ │
│  │  │   OTel Collector pod    │     │    Grafana Tempo pod    │   │ │
│  │  │   (otel-collector)      │     │    (tempo)             │   │ │
│  │  │                         │     │                        │   │ │
│  │  │  receivers:             │     │  Stores traces on      │   │ │
│  │  │    otlp (4317, 4318)   ├────►│  local disk            │   │ │
│  │  │  processors:            │OTLP │                        │   │ │
│  │  │    batch               │gRPC │  Query API: :3100       │   │ │
│  │  │    memory_limiter      │     │  OTLP gRPC: :4317       │   │ │
│  │  │  exporters:             │     │  OTLP HTTP: :4318       │   │ │
│  │  │    otlp → tempo:4317   │     └──────────┬─────────────┘   │ │
│  │  └─────────────────────────┘                │                 │ │
│  │                                             │ TraceQL query   │ │
│  └─────────────────────────────────────────────│─────────────────┘ │
│                                                │                    │
│  namespace: monitoring                         ▼                    │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Grafana                                                     │   │
│  │  - Tempo datasource (loaded from ConfigMap by sidecar)       │   │
│  │  - Explore tab → TraceQL queries                             │   │
│  │  - Click metric spike → jump to traces from that time window │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  namespace: opentelemetry-operator                                   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  OTel Operator pod                                           │   │
│  │  - Watches for pods with inject-python annotation            │   │
│  │  - Watches Instrumentation + OpenTelemetryCollector CRDs     │   │
│  │  - Manages the Collector Deployment lifecycle                │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Components Added

### 1. OpenTelemetry Operator
**File:** `k8s/projects/otel-operator.yaml`
**Namespace:** `opentelemetry-operator`
**Deployed via:** Helm chart `opentelemetry-operator` from `open-telemetry.github.io/opentelemetry-helm-charts`

The Operator is the brain of the tracing setup. It is a Kubernetes Operator — a controller that runs in the cluster and watches for custom resources (CRDs) that you define. When it sees them, it takes action.

It does two things:

**a) Manages the OTel Collector lifecycle**
When you create an `OpenTelemetryCollector` CRD, the Operator creates and manages the corresponding Deployment, Service, ConfigMap, and ServiceAccount. If you change the CR, the Operator reconciles the cluster state. If the Deployment crashes, the Operator restores it.

**b) Auto-injects the Python SDK into pods**
When a pod has the annotation `instrumentation.opentelemetry.io/inject-python: "true"`, the Operator's mutating admission webhook intercepts the pod creation request and modifies the pod spec before it is scheduled. It adds:
- An init container that installs the Python OTel SDK into a shared volume
- Environment variables (`PYTHONPATH`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, etc.) that activate the SDK when the app starts

**Key Helm values configured:**
```yaml
admissionWebhooks:
  certManager:
    enabled: false     # Don't require cert-manager
  autoGenerateCert:
    enabled: true      # Generate a self-signed cert for the webhook
manager:
  collectorImage:
    repository: otel/opentelemetry-collector-contrib  # Full feature set
```

---

### 2. Grafana Tempo
**File:** `k8s/projects/tempo.yaml`
**Namespace:** `tracing`
**Deployed via:** Helm chart `tempo` from `grafana.github.io/helm-charts`

Tempo is a trace storage backend built by Grafana Labs. It is designed to be:
- **Cost-efficient** — stores traces as objects (local disk or blob storage), not in an expensive database
- **Deeply integrated with Grafana** — first-class support in the Grafana UI
- **Index-free** — uses trace ID for lookup; relies on a metrics backend (Prometheus) for search by service/operation

Ports exposed:
| Port | Protocol | Purpose |
|------|----------|---------|
| 3100 | HTTP | Grafana query API (TraceQL), also used by Grafana datasource |
| 4317 | gRPC | OTLP gRPC — receives traces from the Collector |
| 4318 | HTTP | OTLP HTTP — alternative receive endpoint |

**Storage:** Configured for local disk (`/var/tempo/blocks`). For production use this should be pointed at Azure Blob Storage using the `azure` backend to survive pod restarts.

**Retention:** 24 hours (configurable via `compactor.compaction.block_retention`).

---

### 3. OpenTelemetry Collector
**File:** `k8s/tracing/collector.yaml` (OpenTelemetryCollector CR)
**Namespace:** `tracing`
**Managed by:** OTel Operator (creates a Deployment + Service named `otel-collector`)

The Collector is a vendor-agnostic proxy for telemetry data. Rather than having every app talk directly to Tempo, apps talk to the Collector which buffers, processes, and forwards traces. This decouples your app from the backend — you can change from Tempo to Jaeger or add a second backend (e.g. AWS X-Ray) with zero application changes.

**Pipeline configured:**
```
receivers: [otlp]  →  processors: [memory_limiter, batch]  →  exporters: [otlp → tempo]
```

- **otlp receiver** — listens on ports 4317 (gRPC) and 4318 (HTTP) for incoming traces
- **memory_limiter processor** — prevents the Collector from OOM-crashing under heavy load
- **batch processor** — buffers spans for 5 seconds before sending to reduce write pressure on Tempo
- **otlp exporter** — forwards to Tempo via OTLP gRPC on port 4317

---

### 4. Instrumentation CR
**File:** `k8s/tracing/instrumentation.yaml`
**Namespace:** `default` (must match where the app pods run)
**Kind:** `Instrumentation` (provided by OTel Operator CRD)

This resource defines *how* to auto-instrument Python pods. When the Operator injects the SDK, it reads this CR to know:
- Where to send traces (`exporter.endpoint` → the Collector's OTLP HTTP endpoint)
- How to propagate trace context between services (`propagators`)
- What sampling rate to use (`sampler`)
- Any extra environment variables to set

```yaml
spec:
  exporter:
    endpoint: http://otel-collector.tracing.svc.cluster.local:4318
  sampler:
    type: parentbased_traceidratio
    argument: "1.0"   # 100% sampling — reduce for high traffic
```

**Sampling explained:**
`parentbased_traceidratio` means: if an incoming request already has a trace context (i.e. was started by another service), honour its sampling decision. If it's a new root trace, sample at the given ratio (1.0 = 100%). In production with high traffic, setting this to `0.1` would sample 10% of traces, reducing storage cost significantly.

---

### 5. Tempo Datasource ConfigMap
**File:** `k8s/tracing/tempo-datasource.yaml`
**Namespace:** `monitoring`

A ConfigMap with label `grafana_datasource: "1"`. The `grafana-sc-datasources` sidecar container running inside the Grafana pod watches for these ConfigMaps and copies them into `/etc/grafana/provisioning/datasources/` at runtime. Grafana then loads the Tempo datasource without any manual UI configuration.

The datasource configures trace-to-metrics linking:
```yaml
tracesToMetrics:
  datasourceUid: prometheus
  tags:
    - key: service.name
      value: todo-app
```
This tells Grafana: when you're looking at a trace from `todo-app`, show a link to the Prometheus metrics for that service. You can click from a slow span directly to the `http_request_duration_seconds` graph for that time window.

---

## CRDs Explained

Kubernetes Custom Resource Definitions (CRDs) extend the Kubernetes API. The OTel Operator installs three CRDs:

### `Instrumentation`
```
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
```
Defines the auto-instrumentation configuration for a language runtime. The Operator reads this when injecting the SDK into a pod. One `Instrumentation` CR per namespace is typical — all pods in that namespace that have the inject annotation will use it.

**Key fields:**
| Field | Purpose |
|-------|---------|
| `spec.exporter.endpoint` | Where injected apps should send their traces |
| `spec.sampler` | Sampling strategy and rate |
| `spec.propagators` | How trace context is propagated in HTTP headers |
| `spec.python` | Python-specific config (env vars, image override) |

### `OpenTelemetryCollector`
```
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
```
Defines an OTel Collector deployment. The Operator watches for this CR and creates/updates a Deployment, Service, ConfigMap, and ServiceAccount to match the spec.

**Key fields:**
| Field | Purpose |
|-------|---------|
| `spec.mode` | `deployment` (single pod), `daemonset` (one per node), `statefulset` |
| `spec.config` | The full OpenTelemetry Collector YAML config (pipelines, receivers, exporters) |
| `spec.resources` | CPU/memory limits for the Collector pod |

### `OpAMPBridge` (not used, but installed)
Supports the OpAMP protocol for remote Collector management. Ignore for now.

---

## How the Pipeline Works End-to-End

Here is the exact journey of a single `POST /todos` request:

```
Step 1 — Request arrives at FastAPI
  The OTel Python SDK (injected by the init container) intercepts the
  ASGI middleware layer. Before your route handler runs, the SDK:
    - Reads trace context from incoming HTTP headers (W3C TraceContext format)
      If none, generates a new Trace ID (e.g. 4bf92f3577b34da6)
    - Creates a root span: "POST /todos" with start_time = now

Step 2 — SQLAlchemy query executes
  The SDK's SQLAlchemy instrumentation monkey-patches the engine.
  When db.add() + db.commit() runs:
    - A child span is created: "INSERT INTO todos"
    - Attributes recorded: db.system=postgresql, db.statement="INSERT INTO todos..."
    - Duration recorded when the query completes

Step 3 — Redis publish executes (if todo is completed)
  The SDK's Redis instrumentation wraps the redis client.
    - A child span is created: "XADD todo_events"
    - Attributes: db.system=redis, net.peer.name=redis-master

Step 4 — Response sent
  The root span ends. Duration = time from Step 1 to now.
  The complete trace (3 spans) is serialized to OTLP format.

Step 5 — Trace exported to Collector
  The SDK sends the serialized trace via HTTP POST to:
  http://otel-collector.tracing.svc.cluster.local:4318/v1/traces
  This is a fire-and-forget async call — it does not block the response.

Step 6 — Collector processes the trace
  The Collector's memory_limiter checks available memory.
  The batch processor adds the trace to a 5-second buffer.
  When the buffer flushes (or hits size limit), it sends all buffered
  traces to Tempo via OTLP gRPC: tempo.tracing.svc.cluster.local:4317

Step 7 — Tempo stores the trace
  Tempo writes the trace to the WAL (write-ahead log) immediately for
  durability, then moves it to the local block storage.
  The trace is queryable by Trace ID within seconds.

Step 8 — You query in Grafana
  Open Grafana → Explore → select Tempo datasource.
  Run: { .http.target = "/todos" && duration > 10ms }
  Grafana sends this TraceQL query to Tempo's HTTP API on port 3100.
  Tempo returns matching traces. You click a trace to see the waterfall.
```

---

## Auto-Instrumentation — How the Magic Works

The phrase "no code changes" works because of Kubernetes' **mutating admission webhook** mechanism.

When the `todo-app` pod is created (via the Argo Rollout), Kubernetes sends the pod spec to the OTel Operator's admission webhook **before scheduling it**. The webhook:

1. Checks if the pod has `instrumentation.opentelemetry.io/inject-python: "true"`
2. Looks up the `Instrumentation` CR named `python-instrumentation` in the pod's namespace (`default`)
3. Mutates the pod spec by adding:

```yaml
# Added by the webhook — you never write this yourself
initContainers:
- name: opentelemetry-auto-instrumentation-python
  image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:latest
  command: ["cp", "-r", "/autoinstrumentation/.", "/otel-auto-instrumentation-python"]
  volumeMounts:
  - name: opentelemetry-auto-instrumentation-python
    mountPath: /otel-auto-instrumentation-python

volumes:
- name: opentelemetry-auto-instrumentation-python
  emptyDir: {}

# Added to your existing container
env:
- name: PYTHONPATH
  value: /otel-auto-instrumentation-python/opentelemetry/instrumentation/auto_instrumentation:...
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: http://otel-collector.tracing.svc.cluster.local:4318
- name: OTEL_SERVICE_NAME
  value: todo-app
- name: OTEL_RESOURCE_ATTRIBUTES
  value: k8s.namespace.name=default,k8s.pod.name=$(POD_NAME),...
volumeMounts:
- name: opentelemetry-auto-instrumentation-python
  mountPath: /otel-auto-instrumentation-python
```

The init container copies the SDK files into a shared `emptyDir` volume. Your app container mounts that volume and the `PYTHONPATH` env var causes Python to auto-discover and activate the instrumentation at startup — no `import opentelemetry` needed in your code.

**What gets auto-instrumented:**
| Library | What is traced |
|---------|----------------|
| FastAPI | Every HTTP route — method, path, status code, duration |
| SQLAlchemy | Every query — SQL statement, db name, duration |
| Redis | Every command — command name, key, duration |
| urllib3 / requests | Outbound HTTP calls (if any) |

---

## Practical Use Cases

### 1. Debugging a latency spike
**Scenario:** You get a `TodoAppHighLatency` alert — p99 is 1.8s.

**Without tracing:** You look at `http_request_duration_seconds` in Grafana. The spike exists. You look at PostgreSQL CPU — it's high. You don't know if it's slow queries, connection pool exhaustion, or something else.

**With tracing:**
1. Open Grafana → Explore → Tempo
2. Query: `{ .http.route = "/todos" } | duration > 500ms`
3. Find a slow trace. Open the waterfall.
4. See: `SELECT * FROM todos` took 1.7s. Click it. See attribute `db.statement`.
5. The query is doing a full table scan. Root cause found in 2 minutes.

### 2. Finding the cause of 5xx errors
**Scenario:** `TodoAppHighErrorRate` fires — 8% error rate.

**With tracing:**
1. Query: `{ .http.status_code = 500 }`
2. Open an errored trace.
3. See the SQLAlchemy span has `status: ERROR` and attribute `exception.message: "too many connections"`.
4. PostgreSQL connection pool is exhausted. Fix: raise `pool_size` in the SQLAlchemy engine config.

### 3. Understanding normal request behaviour
**Scenario:** You want to know what the typical database query count is per API call.

1. Open any trace for `GET /todos`.
2. Count the spans under the root span — how many DB queries run per request?
3. If you see `SELECT * FROM todos` running 3 times for one request, you've found an N+1 query issue.

### 4. Canary deployment validation
**Scenario:** You've deployed a new version with Argo Rollouts (20% traffic).

1. In Grafana, filter traces by `k8s.pod.name` to separate stable vs canary pod.
2. Compare latency distributions between the two versions.
3. If the canary has a new slow span that the stable version doesn't — roll back before it reaches 100%.

### 5. Service dependency mapping
Grafana's Node Graph view (enabled in the datasource config) automatically renders a service map from your trace data showing which services call which, with error rates and latencies on each edge. This is your live architecture diagram, always up to date.

---

## Correlation: Traces + Metrics + Logs

The full observability picture comes from linking all three signals together in Grafana:

```
Grafana Dashboard — Request Latency panel spikes
    │
    │  Click "View traces for this time range"
    ▼
Tempo — shows traces from that 5-minute window
    │
    │  Open slow trace — find the SQLAlchemy span
    │  Click "View logs for this pod"
    ▼
Loki (Phase 5) — shows pod logs from that exact timestamp
    │
    │  See the log line: "ERROR: deadlock detected on table todos"
    ▼
Root cause identified
```

This correlation is configured via the `tracesToMetrics` and `tracesToLogs` fields in the Tempo datasource. The trace attributes (`k8s.pod.name`, `service.name`, `k8s.namespace.name`) are used as label matchers when jumping between signals.

---

## Glossary

| Term | Definition |
|------|-----------|
| **Trace** | The complete record of a single request's journey through the system |
| **Span** | A single timed operation within a trace (one HTTP call, one DB query) |
| **Trace ID** | A 128-bit ID shared by all spans in the same trace |
| **Span ID** | A 64-bit ID unique to each span |
| **Parent span** | The span that created this one (root span has no parent) |
| **OTLP** | OpenTelemetry Protocol — the standard wire format for sending telemetry data |
| **W3C TraceContext** | HTTP header standard (`traceparent`, `tracestate`) for propagating trace context between services |
| **Propagation** | The mechanism by which a trace ID is passed from one service to the next via HTTP headers |
| **Sampling** | Deciding which traces to keep — 100% sampling captures everything; lower rates reduce cost |
| **Head-based sampling** | Sampling decision made at the start of a trace (at the root span) |
| **Tail-based sampling** | Sampling decision made after the full trace is complete (keeps all errors, samples the rest) |
| **TraceQL** | Grafana Tempo's query language for searching traces (similar to PromQL for metrics) |
| **Admission webhook** | A Kubernetes hook that intercepts and can modify API requests before resources are created |
| **Auto-instrumentation** | SDK injection via init containers — no application code changes required |
| **OTel Collector** | A vendor-agnostic telemetry pipeline — receives, processes, and exports traces/metrics/logs |
