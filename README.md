# Redis Cluster Autoscaler

A Kubernetes operator that provides intelligent autoscaling for Redis clusters with zero-downtime operations.

## Overview

The Redis Cluster Autoscaler automatically scales your Redis cluster up and down based on CPU and memory metrics. It uses a hot standby strategy to enable instant scale-up operations without waiting for pod startup times.

### Key Features

- **Zero-Downtime Scaling**: Hot standby master node enables instant scale-up (~5-10 seconds)
- **Intelligent Monitoring**: Automatically scales based on CPU and memory usage via Prometheus
- **Automatic Resharding**: Manages Redis cluster slot distribution during scaling operations
- **Pre-seeded Scale-Down**: Uses Redis replication to speed up slot migration
- **Flexible Deployment**: Supports both operator-managed and existing Redis clusters
- **Cooldown Protection**: Prevents rapid scaling oscillations

# User Guide

This guide walks you through installing, configuring, and using the Redis Cluster Autoscaler.

## Table of Contents

- Prerequisites
- Installation
- Quick Start
- Basic Configuration
- Common Use Cases
- Monitoring Your Cluster
- Next Steps

## Prerequisites

Before installing the Redis Cluster Autoscaler, ensure you have the following prerequisites ready.

### Required Infrastructure

1. **Kubernetes Cluster** (v1.19 or later)

```bash
kubectl version --short
````

2. **kubectl** configured to access your cluster

```bash
kubectl cluster-info
```

3. **Prometheus Operator Installed and Ready**

The Redis Cluster Autoscaler requires a functioning Prometheus stack to gather metrics.

```bash
kubectl get servicemonitors -A
```

4. **Cluster Admin Access** (to install CRDs)

### Recommended Tools

* Helm (v3+)
* Storage Class (for Redis PVCs)
* Metrics Server (optional)

### Resource Requirements

| Component     | CPU (minimum) | Memory (minimum) |
| ------------- | ------------- | ---------------- |
| Per Redis Pod | 100m          | 256Mi            |
| Operator Pod  | 100m          | 50Mi             |

Minimum cluster size:
A 3-master cluster with 1 replica each requires **8 pods total**
(3 masters + 3 replicas + 1 standby master + 1 standby replica)

## Installation

### Install from GitHub

```bash
git clone https://github.com/SatyamS17/redis-foxtrot-autoscaler.git
```
Edit the cluster.yaml config file to configure autoscaler

### Build and deploy autoscaler
```bash
./build.sh
```
### Verify Installation

```bash
kubectl get crd redisclusters.cache.example.com
kubectl get pods -n redis-operator-system
```

Expected output:

```text
redis-operator-controller-manager   2/2   Running
```

### Verify Cluster Health

```bash
kubectl exec -it my-redis-0 -- redis-cli cluster info
```

Expected:

```text
cluster_state:ok
cluster_slots_assigned:16384
cluster_known_nodes:8
```

## Monitoring

```bash
kubectl get rediscluster my-redis -w
kubectl logs -n redis-operator-system deployment/redis-operator-controller-manager -f
```

## Appendix

### Useful Commands

```bash
kubectl delete rediscluster my-redis

kubectl patch rediscluster my-redis -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete rediscluster my-redis --force --grace-period=0

kubectl get redisclusters -A
kubectl describe rediscluster my-redis

kubectl exec -it redis-cluster-0 -- redis-cli CLUSTER SLOTS
kubectl exec -it redis-cluster-0 -- redis-cli CLUSTER NODES
```

### Default Values

| Field                 | Default |
| --------------------- | ------- |
| redisVersion          | "7.2"   |
| minMasters            | 3       |
| replicasPerMaster     | 1       |
| cpuThresholdLow       | 20      |
| memoryThreshold       | 70      |
| memoryThresholdLow    | 30      |
| reshardTimeoutSeconds | 600     |
| scaleCooldownSeconds  | 60      |
| metricsQueryInterval  | 15      |
| manageStatefulSet     | true    |

```
