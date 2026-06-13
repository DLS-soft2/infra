#!/bin/bash
set -e

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30030 \
  --set grafana.adminPassword=admin \
  --set grafana.defaultDashboardsEnabled=false \
  --wait --timeout 5m
