# Redis Cluster Autoscaler

A Kubernetes operator that provides intelligent, zero-downtime autoscaling for Redis clusters.

---

## How Installation Works (Important)

The autoscaler is installed by applying **pre-built Kubernetes manifests** hosted in this GitHub repository.
The operator image is already built and publicly available.

---

## Prerequisites

Before installing, ensure you have:

* Kubernetes v1.19+
* `kubectl` configured for your cluster
* **A running Prometheus stack** (Prometheus Operator recommended)
* Cluster-admin permissions (required to install CRDs)

### Check if Prometheus is Installed

```bash
kubectl cluster-info
kubectl get servicemonitors -A
kubectl get pods -n monitoring  # or wherever Prometheus is installed
```

### Don't Have Prometheus? Install It First

If you don't have Prometheus, install the kube-prometheus-stack:

```bash
# Add Prometheus Helm repo
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

Verify Prometheus is running:

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring | grep prometheus-operated
```

You should see `prometheus-operated` service at `prometheus-operated.monitoring.svc:9090`

---

## Installation 

Install the Redis Cluster Autoscaler operator directly from GitHub:

```bash
kubectl apply -f https://raw.githubusercontent.com/SatyamS17/redis-foxtrot-autoscaler/main/operator.yaml
```

This installs:

* The `RedisCluster` CustomResourceDefinition (CRD)
* Required RBAC permissions
* The autoscaler controller deployment

> This step is required **once per Kubernetes cluster**.

---

## Verify Operator Installation

```bash
kubectl get pods -n redis-operator-system
```

Expected output:

```text
redis-operator-controller-manager   Running
```

Verify the CRD exists:

```bash
kubectl get crd redisclusters.cache.example.com
```

---

## Deploying a Redis Cluster (Required)

After the operator is installed, you must create a **RedisCluster** resource.
This tells the autoscaler **what Redis cluster to manage**.

---

### Create `redis-cluster.yaml`

```yaml
apiVersion: cache.example.com/v1
kind: RedisCluster
metadata:
  name: redis-cluster
  namespace: default
spec:
  masters: 3
  minMasters: 3
  replicasPerMaster: 1
  redisVersion: "7.2"

  autoScaleEnabled: true

  cpuThreshold: 70
  cpuThresholdLow: 20
  memoryThreshold: 70
  memoryThresholdLow: 30

  reshardTimeoutSeconds: 600
  scaleCooldownSeconds: 60

  prometheusURL: "http://prometheus-operated.monitoring.svc:9090"
  metricsQueryInterval: 15
```

### Configuration Options Explained

#### Cluster Size

| Field | Description | Example | Notes |
|-------|-------------|---------|-------|
| `masters` | Number of active master nodes | `3` | Total active masters serving traffic |
| `minMasters` | Minimum masters (scale-down limit) | `3` | Prevents scaling below this number |
| `replicasPerMaster` | Replicas per master for HA | `1` | `1` = each master has 1 replica (recommended) |
| `redisVersion` | Redis version to deploy | `"7.2"` | Use quotes for version numbers |

** Total Pods Deployed:**
- **Active pods**: `masters × (1 + replicasPerMaster)`
  - Example: `3 masters × 2 = 6 pods` (3 masters + 3 replicas)
- **Standby pods**: `1 + replicasPerMaster`
  - Example: `2 pods` (1 standby master + 1 standby replica)
- **Total**: `8 pods` for default config (3+3+1+1)

#### Autoscaling Thresholds

| Field | Description | Default | When It Triggers |
|-------|-------------|---------|------------------|
| `autoScaleEnabled` | Enable/disable autoscaling | `true` | Set to `false` to disable autoscaling |
| `cpuThreshold` | CPU % to trigger scale-up | `70` | When **ANY** pod exceeds this CPU % |
| `cpuThresholdLow` | CPU % to trigger scale-down | `20` | When **2+** pods are below this CPU % |
| `memoryThreshold` | Memory % to trigger scale-up | `70` | When **ANY** pod exceeds this memory % |
| `memoryThresholdLow` | Memory % to trigger scale-down | `30` | When **2+** pods are below this memory % |

**Scale-Up Example:**
```
Pod CPU: [75%, 68%, 82%]  ← Pod 3 at 82% > cpuThreshold (70%)
Action: Scale up immediately (activate standby)
Result: [60%, 55%, 62%, 58%] ← Load distributed across 4 masters
```

**Scale-Down Example:**
```
Pod CPU: [15%, 18%, 72%]  ← 2 pods below cpuThresholdLow (20%)
Action: Scale down (remove highest-index master)
Result: [25%, 28%, 90%] ← Back to 3 masters
```

#### Operational Settings

| Field | Description | Default | Notes |
|-------|-------------|---------|-------|
| `reshardTimeoutSeconds` | Max time for reshard operations | `600` | 10 minutes - increase for large datasets |
| `scaleCooldownSeconds` | Wait time between scaling operations | `60` | Prevents rapid scale-up/down oscillations |

**Cooldown Protection:**
```
Scale-up at 10:00 AM → Cooldown until 10:01 AM
During cooldown: No scaling operations allowed
After cooldown: Resume normal monitoring
```

#### Prometheus Integration

| Field | Description | Example |
|-------|-------------|---------|
| `prometheusURL` | Prometheus service URL | `"http://prometheus-operated.monitoring.svc:9090"` |
| `metricsQueryInterval` | How often to query metrics (seconds) | `15` |

**Finding Your Prometheus URL:**
```bash
# List Prometheus services
kubectl get svc -n monitoring | grep prometheus

# Common URLs:
# - kube-prometheus-stack: http://prometheus-operated.monitoring.svc:9090
# - prometheus-operator: http://prometheus-operated.monitoring.svc:9090
# - custom install: http://YOUR-PROMETHEUS-SERVICE.NAMESPACE.svc:PORT
```

### Quick Configuration Templates

**Development (Fast Testing):**
```yaml
spec:
  masters: 3
  minMasters: 3
  replicasPerMaster: 1
  cpuThreshold: 60          # Scale up quickly
  cpuThresholdLow: 15       # Scale down quickly
  scaleCooldownSeconds: 30  # Short cooldown for testing
```

**Production (Stable):**
```yaml
spec:
  masters: 10
  minMasters: 5
  replicasPerMaster: 2       # High availability
  cpuThreshold: 80           # Conservative scale-up
  cpuThresholdLow: 25        # Conservative scale-down
  scaleCooldownSeconds: 300  # 5-minute cooldown
  reshardTimeoutSeconds: 900 # 15 minutes for large data
```

**Cost-Optimized (Small Workloads):**
```yaml
spec:
  masters: 3
  minMasters: 3
  replicasPerMaster: 1
  cpuThreshold: 85           # High threshold before scaling
  memoryThreshold: 85
  scaleCooldownSeconds: 120  # Longer cooldown
```

---

### Apply the RedisCluster

```bash
kubectl apply -f redis-cluster.yaml
```

Once applied, the operator will:

* Create and bootstrap the Redis cluster
* Monitor CPU and memory usage via Prometheus
* Automatically scale up or down when thresholds are crossed
* Safely reshard Redis slots with zero downtime

---

## Verify Redis Cluster Health

```bash
kubectl exec -it redis-cluster-0 -- redis-cli cluster info
```

Expected:

```text
cluster_state:ok
cluster_slots_assigned:16384
cluster_known_nodes:8
```

(3 masters, 3 replicas, 1 standby master, 1 standby replica)

---

## Monitoring and Debugging

Watch autoscaler status:

```bash
kubectl get rediscluster redis-cluster -w
```

View operator logs:

```bash
kubectl logs -n redis-operator-system \
  deployment/redis-operator-controller-manager -f
```
