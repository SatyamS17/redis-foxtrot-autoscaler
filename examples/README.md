# Redis Operator Examples

Example configurations for different use cases.

## Basic Example

Minimal configuration for getting started:

```bash
kubectl apply -f basic.yaml
```

**Use case:** Testing, small deployments, learning the operator

## Development Example

Fast iteration and testing:

```bash
kubectl apply -f development.yaml
```

**Features:**
- Aggressive autoscaling thresholds for quick testing
- Short cooldown periods
- Minimal resource requirements

**Use case:** Development, CI/CD testing, experimentation

## Production Example

High-availability production cluster:

```bash
kubectl apply -f production.yaml
```

**Features:**
- 10 masters with 2 replicas each (HA)
- Conservative autoscaling thresholds
- Longer cooldown for stability
- Suitable for production workloads

**Use case:** Production deployments, critical applications

## Customization

All examples can be customized by editing the YAML files. Key parameters:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `masters` | Number of master nodes | 3 |
| `minMasters` | Minimum masters (scale-down limit) | 3 |
| `replicasPerMaster` | Replicas per master | 1 |
| `cpuThreshold` | CPU % to trigger scale-up | 70 |
| `cpuThresholdLow` | CPU % to trigger scale-down | 20 |
| `memoryThreshold` | Memory % to trigger scale-up | 70 |
| `memoryThresholdLow` | Memory % to trigger scale-down | 30 |
| `scaleCooldownSeconds` | Wait time between scaling operations | 60 |

See [DEPLOYMENT.md](../DEPLOYMENT.md) for complete configuration reference.

## Monitoring

After deploying, monitor your cluster:

```bash
# Check cluster status
kubectl get rediscluster

# View pods
kubectl get pods -l app=redis-cluster

# View operator logs
kubectl logs -n redis-operator-system deployment/redis-operator-controller-manager -f

# Check scaling events
kubectl get events --field-selector involvedObject.kind=RedisCluster
```
