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
  --set loki.useTestSchema=true \
  --set loki.limits_config.retention_period=24h \
  --set loki.compactor.retention_enabled=true \
  --set loki.compactor.delete_request_store=filesystem \
  --set singleBinary.replicas=1 \
  --set read.replicas=0 \
  --set write.replicas=0 \
  --set backend.replicas=0 \
  --set chunksCache.enabled=false \
  --set resultsCache.enabled=false \
  --set gateway.enabled=false \
  --wait --timeout 5m

ALLOY_VALUES=$(mktemp)
cat > "$ALLOY_VALUES" <<'EOF'
alloy:
  configMap:
    content: |
      discovery.kubernetes "pods" {
        role = "pod"
        namespaces {
          names = ["dls"]
        }
      }

      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app"]
          target_label  = "app"
        }
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
        endpoint {
          url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
        }
      }
EOF

helm upgrade --install alloy grafana/alloy \
  --namespace monitoring \
  --values "$ALLOY_VALUES" \
  --wait --timeout 5m

rm -f "$ALLOY_VALUES"
