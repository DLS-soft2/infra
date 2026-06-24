#!/bin/bash
set -e

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30030 \
  --set grafana.adminPassword=admin \
  --set grafana.defaultDashboardsEnabled=false \
  --set kubelet.enabled=true \
  --set kubelet.serviceMonitor.cAdvisor=true \
  --set prometheus.prometheusSpec.kubeletScrapeTimeout=30s \
  --wait --timeout 5m
