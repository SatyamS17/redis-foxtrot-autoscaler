# Prometheus Setup Guide

The Redis Cluster Autoscaler requires Prometheus to collect CPU and memory metrics from Redis pods. This guide shows you how to install and configure Prometheus.

## Table of Contents

- [Quick Install](#quick-install)
- [Detailed Installation](#detailed-installation)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Alternative: Using Existing Prometheus](#alternative-using-existing-prometheus)

## Quick Install

If you don't have Prometheus installed, use the kube-prometheus-stack (recommended):

```bash
# Add Helm repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install Prometheus Operator stack
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false

# Wait for Prometheus to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=300s
```

**That's it!** Prometheus is now installed and ready to monitor your Redis cluster.

## Detailed Installation

### What Gets Installed

The `kube-prometheus-stack` includes:

- **Prometheus Operator**: Manages Prometheus instances
- **Prometheus**: Metrics collection and storage
- **Alertmanager**: Alert management
- **Grafana**: Visualization dashboards
- **Node Exporter**: Node-level metrics
- **Kube-State-Metrics**: Kubernetes object metrics
- **ServiceMonitors**: Auto-discovery of services to monitor

### Step-by-Step Installation

#### 1. Install Helm (if not installed)

```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Windows
choco install kubernetes-helm
```

#### 2. Add Prometheus Helm Repository

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

#### 3. Create Custom Values (Optional)

Create `prometheus-values.yaml` for custom configuration:

```yaml
# prometheus-values.yaml
prometheus:
  prometheusSpec:
    # Allow monitoring of all ServiceMonitors regardless of labels
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false

    # Retention settings
    retention: 7d
    retentionSize: "10GB"

    # Resource limits
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 1000m
        memory: 4Gi

    # Storage (optional - for persistent metrics)
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

grafana:
  adminPassword: "admin"  # Change this!
  persistence:
    enabled: true
    size: 10Gi

alertmanager:
  enabled: true
```

#### 4. Install with Custom Values

```bash
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f prometheus-values.yaml
```

Or install with minimal configuration:

```bash
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
```

#### 5. Wait for Installation to Complete

```bash
# Watch pods come up
kubectl get pods -n monitoring -w

# Wait for Prometheus to be ready
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=prometheus \
  -n monitoring \
  --timeout=300s
```

## Verification

### 1. Check Prometheus Pods

```bash
kubectl get pods -n monitoring
```

Expected output:
```
NAME                                                   READY   STATUS    RESTARTS   AGE
prometheus-kube-prometheus-operator-xxx                1/1     Running   0          2m
prometheus-prometheus-kube-prometheus-prometheus-0     2/2     Running   0          2m
prometheus-kube-state-metrics-xxx                      1/1     Running   0          2m
prometheus-prometheus-node-exporter-xxx                1/1     Running   0          2m
alertmanager-prometheus-kube-prometheus-alertmanager-0 2/2     Running   0          2m
prometheus-grafana-xxx                                 3/3     Running   0          2m
```

### 2. Check Prometheus Service

```bash
kubectl get svc -n monitoring | grep prometheus
```

You should see:
```
prometheus-operated                       ClusterIP   None           <none>        9090/TCP
```

The Redis Autoscaler uses this service: `http://prometheus-operated.monitoring.svc:9090`

### 3. Test Prometheus Access

Port-forward to access Prometheus UI:

```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
```

Open browser to: http://localhost:9090

### 4. Verify Metrics Collection

In Prometheus UI, run these queries to verify metrics are being collected:

```promql
# Check container CPU metrics
rate(container_cpu_usage_seconds_total[1m])

# Check container memory metrics
container_memory_usage_bytes

# Check if Redis pods are being scraped (after deploying Redis)
container_cpu_usage_seconds_total{pod=~"redis-cluster-.*"}
```

## Configure Redis Autoscaler

After Prometheus is installed, configure your RedisCluster to use it:

```yaml
apiVersion: cache.example.com/v1
kind: RedisCluster
metadata:
  name: redis-cluster
spec:
  # ... other config ...

  # Point to your Prometheus installation
  prometheusURL: "http://prometheus-operated.monitoring.svc:9090"
  metricsQueryInterval: 15
```

## Access Grafana (Optional)

The kube-prometheus-stack includes Grafana for visualization:

### Get Grafana Password

```bash
kubectl get secret -n monitoring prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d
```

### Access Grafana UI

```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

Open: http://localhost:3000
- Username: `admin`
- Password: (from command above)

### Import Redis Dashboard

1. In Grafana, go to Dashboards → Import
2. Use dashboard ID: `763` (Redis Dashboard)
3. Select Prometheus data source
4. Click Import

## Troubleshooting

### Prometheus Pods Not Starting

```bash
# Check pod details
kubectl describe pod -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0

# Check logs
kubectl logs -n monitoring prometheus-prometheus-kube-prometheus-prometheus-0 -c prometheus

# Check events
kubectl get events -n monitoring --sort-by='.lastTimestamp'
```

### No Metrics for Redis Pods

**Problem**: Prometheus isn't scraping Redis pods

**Solution**: The Redis Operator automatically creates a ServiceMonitor. Verify it exists:

```bash
kubectl get servicemonitor redis-cluster -n default
```

If missing, check operator logs:

```bash
kubectl logs -n redis-operator-system deployment/redis-operator-controller-manager | grep ServiceMonitor
```

### Autoscaler Can't Reach Prometheus

**Problem**: Error in operator logs: "Failed to connect to Prometheus"

**Check 1**: Verify Prometheus service exists

```bash
kubectl get svc prometheus-operated -n monitoring
```

**Check 2**: Test connectivity from operator pod

```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://prometheus-operated.monitoring.svc:9090/-/healthy
```

Expected: `Prometheus is Healthy.`

**Check 3**: Verify RedisCluster configuration

```bash
kubectl get rediscluster redis-cluster -o yaml | grep prometheusURL
```

Should show: `prometheusURL: http://prometheus-operated.monitoring.svc:9090`

### Metrics Queries Return No Data

**Problem**: Prometheus queries return empty results

**Check 1**: Verify cAdvisor metrics are available

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090

# Open browser to http://localhost:9090
# Run query:
container_cpu_usage_seconds_total{namespace="default"}
```

**Check 2**: Verify kube-state-metrics is running

```bash
kubectl get pods -n monitoring | grep kube-state-metrics
```

**Check 3**: Check ServiceMonitor is being picked up

```bash
kubectl get servicemonitor -A
```

## Alternative: Using Existing Prometheus

If you already have Prometheus installed (not via Operator):

### 1. Find Your Prometheus Service

```bash
kubectl get svc -A | grep prometheus
```

### 2. Update RedisCluster Configuration

```yaml
spec:
  prometheusURL: "http://YOUR-PROMETHEUS-SERVICE.YOUR-NAMESPACE.svc:9090"
```

### 3. Ensure Prometheus Scrapes cAdvisor

Add this to your Prometheus configuration:

```yaml
scrape_configs:
- job_name: 'kubernetes-cadvisor'
  kubernetes_sd_configs:
  - role: node
  scheme: https
  tls_config:
    ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
  relabel_configs:
  - action: labelmap
    regex: __meta_kubernetes_node_label_(.+)
  - target_label: __metrics_path__
    replacement: /metrics/cadvisor
```

## Uninstalling Prometheus

To remove Prometheus:

```bash
# Uninstall Helm release
helm uninstall prometheus -n monitoring

# Remove namespace
kubectl delete namespace monitoring

# Remove CRDs (if desired)
kubectl delete crd prometheuses.monitoring.coreos.com
kubectl delete crd prometheusrules.monitoring.coreos.com
kubectl delete crd servicemonitors.monitoring.coreos.com
kubectl delete crd podmonitors.monitoring.coreos.com
kubectl delete crd alertmanagers.monitoring.coreos.com
kubectl delete crd thanosrulers.monitoring.coreos.com
```

## Production Considerations

### 1. Persistent Storage

For production, enable persistent storage:

```yaml
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          storageClassName: "standard"  # Use your storage class
          resources:
            requests:
              storage: 100Gi
```

### 2. High Availability

Enable multiple Prometheus replicas:

```yaml
prometheus:
  prometheusSpec:
    replicas: 2
```

### 3. Resource Limits

Set appropriate limits based on your cluster size:

```yaml
prometheus:
  prometheusSpec:
    resources:
      requests:
        cpu: 2000m
        memory: 8Gi
      limits:
        cpu: 4000m
        memory: 16Gi
```

### 4. Retention

Configure retention based on your needs:

```yaml
prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: "100GB"
```

## Next Steps

- [Deploy Redis Cluster](../README.md#deploying-a-redis-cluster-required)
- [Configure Autoscaling](CONFIGURATION.md)
- [Monitoring and Observability](MONITORING.md)
- [Production Best Practices](PRODUCTION.md)

## References

- [Prometheus Operator Documentation](https://prometheus-operator.dev/)
- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Query Language](https://prometheus.io/docs/prometheus/latest/querying/basics/)
