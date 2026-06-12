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
      grafana-nodeport.yaml      Exposes Grafana on NodePort 30030
      service-monitor.yaml       Scrapes /metrics and /actuator/prometheus
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
6. Monitoring (Prometheus + Grafana via Helm)
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
