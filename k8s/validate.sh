#!/bin/bash
set -e

echo "=== DLS-2 Kubernetes Validation ==="
PASS=0
FAIL=0

check_pod() {
  local name=$1
  local phase
  phase=$(kubectl get pod -n dls -l app="$name" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  if [ "$phase" = "Running" ]; then
    echo "$name: Running"
    PASS=$((PASS + 1))
  else
    echo "X $name: $phase (expected Running)"
    FAIL=$((FAIL + 1))
  fi
}

echo "Infrastructure:"
for svc in postgres mongodb redis kafka keycloak; do
  check_pod $svc
done

echo ""
echo "Application services:"
for svc in api-gateway order-service payment-service restaurant-service courier-service notification-service user-service ai-service; do
  check_pod $svc
done

echo ""
echo "API Gateway connectivity:"
MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "localhost")
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://$MINIKUBE_IP:30000/healthy" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  echo "API Gateway responding on :30000 (HTTP $HTTP_CODE)"
  PASS=$((PASS + 1))
else
  echo "API Gateway not responding on :30000 (HTTP $HTTP_CODE)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && echo "All checks passed!" || echo "Some checks failed."
exit $FAIL
