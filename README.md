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
* A running Prometheus stack (Prometheus Operator recommended)
* Cluster-admin permissions (required to install CRDs)

Verify:

```bash
kubectl cluster-info
kubectl get servicemonitors -A
```

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
