#!/bin/bash
set -e

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --create-namespace \
  --set deploymentMode=SingleBinary \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.limits_config.retention_period=24h \
  --set loki.compactor.retention_enabled=true \
  --set singleBinary.replicas=1 \
  --set read.replicas=0 \
  --set write.replicas=0 \
  --set backend.replicas=0 \
  --set chunksCache.enabled=false \
  --set resultsCache.enabled=false \
  --set gateway.enabled=false \
  --wait --timeout 5m

helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --set config.clients[0].url=http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push \
  --set config.snippets.scrapeConfigs='- job_name: dls-pods
  kubernetes_sd_configs:
    - role: pod
      namespaces:
        names:
          - dls
  relabel_configs:
    - source_labels: [__meta_kubernetes_namespace]
      target_label: namespace
    - source_labels: [__meta_kubernetes_pod_name]
      target_label: pod
    - source_labels: [__meta_kubernetes_pod_container_name]
      target_label: container' \
  --wait --timeout 5m
