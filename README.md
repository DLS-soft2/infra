# DLS-2 Infrastructure

Infrastructure-as-code for the DLS-2 food delivery platform. Contains Docker Compose for local development and Kubernetes manifests for production-like deployment.

## Directory Structure

```
infra/
  docker/
    docker-compose.yaml          Full-stack compose (includes Kafka compose)
    docker-compose.kafka.yaml    Kafka + Kafka UI
    keycloak/
      dls-realm.json             Pre-configured realm with roles and OAuth
    postgres/
      init-databases.sh          Creates per-service databases on first start
  k8s/
    namespace.yaml               dls namespace
    secrets.yaml                 Shared secrets (Postgres, Keycloak passwords)
    deploy.sh                    One-command full deployment
    teardown.sh                  Complete teardown (namespace + Helm releases)
    validate.sh                  Health check for all pods and endpoints
    infrastructure/              StatefulSets/Deployments for backing services
      postgres.yaml, mongodb.yaml, redis.yaml, kafka.yaml, keycloak.yaml
    services/                    Deployments + Services for all application pods
      api-gateway, order-service, payment-service, restaurant-service,
      courier-service, notification-service, user-service, ai-service, frontend
    keda/
      keda-install.sh            Installs KEDA via Helm
      notification-dispatch.yaml ScaledJob for notification processing
    monitoring/
      monitoring-install.sh      Installs Prometheus + Grafana via Helm
      loki-install.sh            Installs Loki + Alloy via Helm
      grafana-nodeport.yaml      Exposes Grafana on NodePort 30030
      service-monitor.yaml       Scrapes /metrics and /actuator/prometheus
      loki-datasource.yaml       Auto-provisions Loki datasource in Grafana
      dashboards/
        platform-overview.yaml   Platform health, errors, resource usage
        saga-flow.yaml           Saga service health and endpoint activity
        per-service.yaml         Per-service drilldown (dropdown selector)
        service-logs.yaml        Cross-service log viewer (Loki)
```

## Docker Compose (Development)

### Start Everything

```bash
docker compose -f infra/docker/docker-compose.yaml up -d
```

### Services and Ports

| Service | Image | Port |
|---------|-------|------|
| Keycloak | `keycloak:24.0` | 8080 |
| PostgreSQL | `postgres:16` | 5432 |
| MongoDB | `mongo:7` | 27017 |
| Redis | `redis:7-alpine` | 6379 |
| Kafka | `cp-kafka:7.6.0` (KRaft) | 9092 |
| Kafka UI | `kafka-ui:latest` | 9080 |
| API Gateway | Built from `api-gateway/` | 8000 |
| Order Service | Built from `order-service/` | 8001 |
| Payment Service | Built from `payment-service/` | 8002 |
| Restaurant Service | Built from `restaurant-service/` | 8003 |
| Courier Service | Built from `courier-service/` | 8004 |
| Notification Service | Built from `notification-service/` | 8005 |
| AI Service | Built from `ai-service/` | 8006 |
| User Service | Built from `user-service/` | 8007 |
| Frontend | Built from `frontend/` | 3000 |

### PostgreSQL Init Script

`postgres/init-databases.sh` runs on first container start and creates four databases:

- `order_db` (Order Service)
- `payment_db` (Payment Service)
- `courier_db` (Courier Service)
- `user_db` (User Service)

### Keycloak Realm

`keycloak/dls-realm.json` is auto-imported on startup via `--import-realm`. Contains the `dls` realm with:

- Client: `dls-gateway`
- Roles for RBAC (customer, courier, restaurant, admin)
- Google OAuth identity provider (third-party login)

### Kafka

Runs in KRaft mode (no ZooKeeper). Single broker with `PLAINTEXT://kafka:9092`. Services connect via:

```
KAFKA_BOOTSTRAP_SERVERS=kafka:9092
```

### AI Service

Requires Ollama running on the host. The compose file maps `host.docker.internal` so the container can reach `http://host.docker.internal:11434`.

## Kubernetes (Production Simulation)

Targets Minikube. All resources deploy to the `dls` namespace.

### Prerequisites

- [Minikube](https://minikube.sigs.k8s.io/docs/start/) (`minikube version`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (`kubectl version --client`)
- [Helm](https://helm.sh/docs/intro/install/) (`helm version`)
- [Docker](https://docs.docker.com/get-docker/) (`docker --version`)

### Start Cluster

```bash
minikube start --cpus=8 --memory=16384 --driver=docker --disk-size=40g
minikube ssh -- sudo sysctl fs.inotify.max_user_instances=1024
```

Minimum recommended: 8 CPUs, 16 GB RAM, 40 GB disk. The stack runs 6 infrastructure pods + 9 application pods + monitoring + KEDA. The `sysctl` command raises the inotify watcher limit inside minikube — without it, the monitoring stack (Alloy, Grafana sidecars) hits "too many open files" errors. This resets on `minikube stop/start` so run it each time.

### Build Images Locally

GHCR packages are private, so images must be built inside minikube's Docker daemon:

```bash
# Point your shell's Docker CLI at minikube's Docker daemon
eval $(minikube docker-env)

# Build all services (from the repo root)
MINIKUBE_IP=$(minikube ip)

docker build -t ghcr.io/dls-soft2/api-gateway:latest        api-gateway/
docker build -t ghcr.io/dls-soft2/order-service:latest       order-service/
docker build -t ghcr.io/dls-soft2/payment-service:latest     payment-service/
docker build -t ghcr.io/dls-soft2/restaurant-service:latest  restaurant-service/
docker build -t ghcr.io/dls-soft2/courier-service:latest     courier-service/
docker build -t ghcr.io/dls-soft2/notification-service:latest notification-service/
docker build -t ghcr.io/dls-soft2/user-service:latest        user-service/
docker build -t ghcr.io/dls-soft2/ai-service:latest          ai-service/
docker build -t ghcr.io/dls-soft2/frontend:latest \
  --build-arg VITE_KEYCLOAK_URL=http://${MINIKUBE_IP}:30080  frontend/

# Return to host Docker (optional)
eval $(minikube docker-env -u)
```

The frontend needs `VITE_KEYCLOAK_URL` at build time because the browser talks directly to Keycloak for OAuth. The other `VITE_*` vars default to empty (nginx proxies `/api/` and `/api/v1/ws/` to the gateway and notification-service respectively).

### Deploy

```bash
./infra/k8s/deploy.sh
```

Runs 7 steps in order:
1. Namespace + secrets
2. Infrastructure (Postgres, MongoDB, Redis, Kafka)
3. Keycloak (with readiness wait)
4. Application services (all 9 services + frontend)
5. KEDA (installs via Helm if not present)
6. Monitoring (Prometheus + Grafana via Helm, Loki + Promtail for log aggregation)
7. Prints access URLs

### Access Points (Minikube)

| Service | URL |
|---------|-----|
| Frontend | `http://<minikube-ip>:30010` |
| API Gateway | `http://<minikube-ip>:30000` |
| Keycloak | `http://<minikube-ip>:30080` |
| Grafana | `http://<minikube-ip>:30030` (admin/admin) |

### Validate

```bash
./infra/k8s/validate.sh
```

Checks all pods are Running and tests HTTP connectivity to the API Gateway and Frontend.

### Teardown

```bash
./infra/k8s/teardown.sh
```

Removes the `dls` namespace, KEDA Helm release, and monitoring stack.

## KEDA Serverless

`keda/notification-dispatch.yaml` defines a `ScaledJob` that generates **delivery receipts** — structured summaries stored in Redis when an order is delivered. This is distinct from the regular notification-service (which handles real-time WebSocket push notifications).

- Monitors the `deliveries` Kafka topic for consumer lag
- Spawns notification-service containers (max 3 replicas) in `DISPATCH_MODE=true`
- Each job pod consumes pending `DeliveryCompleted` events, generates a receipt per order, stores it in Redis (`delivery_receipt:{order_id}`, 7-day TTL), then exits
- Polls every 15 seconds, triggers on lag >= 1 message, scales to zero when idle
- Receipts are queryable via `GET /api/v1/receipts/{order_id}` on the notification-service and displayed in the frontend order detail page

This feature is **Kubernetes-only** — KEDA does not run in Docker Compose, so receipts are not generated in the dev environment.

Installed via `keda/keda-install.sh` (Helm chart).

## Monitoring

Prometheus + Grafana stack installed via `monitoring/monitoring-install.sh`.

- **ServiceMonitor** (`monitoring/service-monitor.yaml`) scrapes:
  - `/metrics` on Python services (FastAPI)
  - `/actuator/prometheus` on Java services (Spring Boot)
  - 15-second scrape interval, targets pods with label `monitoring: enabled`
- **Grafana** exposed on NodePort 30030, default credentials `admin/admin`

### Log Aggregation (Loki + Alloy)

Installed via `monitoring/loki-install.sh`. Grafana Alloy runs as a DaemonSet that collects stdout logs from all pods in the `dls` namespace and pushes them to Loki (single-binary mode, filesystem storage, 24-hour retention). No application-side changes were needed — all services already log to stdout.

Loki is auto-provisioned as a Grafana datasource via `monitoring/loki-datasource.yaml` (ConfigMap with `grafana_datasource: "1"` label, picked up by the Grafana sidecar).

### Dashboards

Four dashboards are deployed as ConfigMaps in `monitoring/dashboards/` and auto-discovered by the Grafana sidecar:

| Dashboard | Datasource | What it shows |
|-----------|------------|---------------|
| DLS-2 Platform Overview | Prometheus | Service up/down, 5xx/4xx errors, pod restarts, CPU/memory |
| DLS-2 Saga Flow | Prometheus | Saga service health, error rates, endpoint activity |
| DLS-2 Per-Service Detail | Prometheus | Dropdown per service — health, errors, endpoints, resources |
| DLS-2 Service Logs | Loki | Dropdown per service — live log stream from any pod |
