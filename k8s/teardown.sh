#!/bin/bash
set -e

echo "=== DLS-2 Kubernetes Teardown ==="

echo "Removing DLS namespace and all resources..."
kubectl delete namespace dls --ignore-not-found

echo "Removing KEDA..."
helm uninstall keda -n keda 2>/dev/null || true
kubectl delete namespace keda --ignore-not-found

echo "Removing monitoring stack..."
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
kubectl delete namespace monitoring --ignore-not-found

echo "Teardown complete."
