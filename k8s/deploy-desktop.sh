#!/bin/bash
set -e

# Docker Desktop Kubernetes variant of deploy.sh
# Requires: Kubernetes enabled in Docker Desktop settings

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== DLS-2 Kubernetes Deployment (Docker Desktop) ==="

# Prerequisites check
echo "Checking prerequisites..."
for cmd in kubectl helm docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed. See infra/README.md for prerequisites."
    exit 1
  fi
done

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: No Kubernetes cluster reachable. Enable Kubernetes in Docker Desktop settings."
  exit 1
fi

CLUSTER_IP="localhost"
echo "Kubernetes cluster is reachable (Docker Desktop uses $CLUSTER_IP)"

# 0. Build frontend with correct Keycloak URL
echo "[0/7] Building frontend image with VITE_KEYCLOAK_URL=http://$CLUSTER_IP:30080..."
docker build -t ghcr.io/dls-soft2/frontend:latest \
  --build-arg VITE_KEYCLOAK_URL="http://$CLUSTER_IP:30080" \
  "$REPO_ROOT/frontend/"
echo "Frontend image built successfully."

# 1. Namespace + secrets
echo "[1/7] Creating namespace and secrets..."
kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/secrets.yaml"

# Google OAuth creds come from the same gitignored .env that docker compose uses
if [ -f "$SCRIPT_DIR/../docker/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/../docker/.env"
  set +a
fi
if [ -n "${GOOGLE_CLIENT_ID:-}" ] && [ -n "${GOOGLE_CLIENT_SECRET:-}" ]; then
  echo "Injecting Google OAuth credentials into dls-secrets..."
  kubectl -n dls patch secret dls-secrets -p \
    "{\"stringData\":{\"google-client-id\":\"$GOOGLE_CLIENT_ID\",\"google-client-secret\":\"$GOOGLE_CLIENT_SECRET\"}}"
else
  echo "WARNING: GOOGLE_CLIENT_ID/SECRET not set (no docker/.env) - Google login will be disabled."
fi

# 2. Infrastructure (databases, kafka)
echo "[2/7] Deploying infrastructure..."
kubectl apply -f "$SCRIPT_DIR/infrastructure/postgres.yaml"
kubectl apply -f "$SCRIPT_DIR/infrastructure/mongodb.yaml"
kubectl apply -f "$SCRIPT_DIR/infrastructure/redis.yaml"
kubectl apply -f "$SCRIPT_DIR/infrastructure/kafka.yaml"
# Ollama skipped — ai-service uses its deterministic fallback scorer.
# To enable Ollama, uncomment and deploy infrastructure/ollama.yaml manually.

echo "Waiting for infrastructure to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n dls --timeout=120s
kubectl wait --for=condition=ready pod -l app=mongodb -n dls --timeout=120s
kubectl wait --for=condition=ready pod -l app=redis -n dls --timeout=120s
kubectl wait --for=condition=ready pod -l app=kafka -n dls --timeout=120s

# 3. Keycloak
echo "[3/7] Deploying Keycloak..."
kubectl apply -f "$SCRIPT_DIR/infrastructure/keycloak.yaml"
echo "Waiting for Keycloak to be ready (this may take a while)..."
kubectl wait --for=condition=ready pod -l app=keycloak -n dls --timeout=180s

# 4. Application services
echo "[4/7] Deploying application services..."
kubectl apply -f "$SCRIPT_DIR/services/"

echo "Patching api-gateway KEYCLOAK_ISSUER_URL with CLUSTER_IP=$CLUSTER_IP..."
kubectl set env deployment/api-gateway -n dls \
  KEYCLOAK_ISSUER_URL="http://$CLUSTER_IP:30080/realms/dls"

echo "Waiting for services to be ready..."
for svc in api-gateway order-service payment-service restaurant-service courier-service notification-service user-service ai-service frontend; do
  kubectl wait --for=condition=ready pod -l app=$svc -n dls --timeout=120s
done

# 5. KEDA
echo "[5/7] Installing KEDA..."
if ! kubectl get namespace keda &>/dev/null; then
  bash "$SCRIPT_DIR/keda/keda-install.sh"
fi
kubectl apply -f "$SCRIPT_DIR/keda/notification-dispatch.yaml"

# 6. Monitoring
echo "[6/7] Installing monitoring stack..."
if ! kubectl get namespace monitoring &>/dev/null; then
  bash "$SCRIPT_DIR/monitoring/monitoring-install.sh"
fi
kubectl apply -f "$SCRIPT_DIR/monitoring/service-monitor.yaml"
kubectl apply -f "$SCRIPT_DIR/monitoring/dashboards/"

# 7. Port-forward + summary
# Kill any existing port-forward on port 3000
lsof -ti:3000 2>/dev/null | xargs kill 2>/dev/null || true
echo "[7/7] Starting port-forward for frontend..."
kubectl port-forward svc/frontend -n dls 3000:80 &>/dev/null &
PF_PID=$!
sleep 1

echo ""
echo "=== Deployment complete! ==="
echo ""
echo "  Frontend:     http://localhost:3000  (port-forward, PID $PF_PID)"
echo "  Keycloak:     http://$CLUSTER_IP:30080"
echo "  API Gateway:  http://$CLUSTER_IP:30000"
echo "  Grafana:      http://$CLUSTER_IP:30030 (admin/admin)"
echo ""
echo "Port-forward is required: Keycloak JS needs Web Crypto API (only available on https or localhost)."
echo "To stop port-forward: kill $PF_PID"
echo "api-gateway KEYCLOAK_ISSUER_URL has been auto-patched to http://$CLUSTER_IP:30080/realms/dls"
