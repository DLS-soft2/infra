#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== DLS-2 Kubernetes Deployment ==="

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
kubectl apply -f "$SCRIPT_DIR/infrastructure/ollama.yaml"

echo "Waiting for infrastructure to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n dls --timeout=120s
kubectl wait --for=condition=ready pod -l app=mongodb -n dls --timeout=120s
kubectl wait --for=condition=ready pod -l app=redis -n dls --timeout=120s
kubectl wait --for=condition=ready pod -l app=kafka -n dls --timeout=120s
# First start pulls the qwen3:4b model (~2.5 GB) into the PVC
kubectl wait --for=condition=ready pod -l app=ollama -n dls --timeout=600s

# 3. Keycloak
echo "[3/7] Deploying Keycloak..."
kubectl apply -f "$SCRIPT_DIR/infrastructure/keycloak.yaml"
echo "Waiting for Keycloak to be ready (this may take a while)..."
kubectl wait --for=condition=ready pod -l app=keycloak -n dls --timeout=180s

# 4. Application services
echo "[4/7] Deploying application services..."
kubectl apply -f "$SCRIPT_DIR/services/"

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

# 7. Summary
echo "[7/7] Deployment complete!"
echo ""
MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "localhost")
echo "Access points:"
echo "  Frontend:     http://$MINIKUBE_IP:30010"
echo "  API Gateway:  http://$MINIKUBE_IP:30000"
echo "  Keycloak:     http://$MINIKUBE_IP:30080"
echo "  Grafana:      http://$MINIKUBE_IP:30030 (admin/admin)"
echo ""
echo "NOTE: Update api-gateway KEYCLOAK_ISSUER_URL if needed:"
echo "  kubectl set env deployment/api-gateway -n dls KEYCLOAK_ISSUER_URL=http://$MINIKUBE_IP:30080/realms/dls"
