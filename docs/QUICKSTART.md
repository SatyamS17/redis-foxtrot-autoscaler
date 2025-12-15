# Quick Start Guide

Get your Redis Cluster Autoscaler running in 5 minutes!

## 1. Deploy the Operator

```bash
./build.sh
```

This will:
- Build the operator Docker image
- Push to `docker.io/satyams17/redis-operator`
- Deploy to your Kubernetes cluster

## 2. Create a Redis Cluster

```bash
kubectl apply -f cluster.yaml
```

## 3. Verify It's Working

```bash
# Check operator is running
kubectl get pods -n redis-operator-system

# Check Redis cluster
kubectl get rediscluster
kubectl get pods -l app=redis-cluster

# View operator logs
kubectl logs -n redis-operator-system deployment/redis-operator-controller-manager -f
```

## 4. Test Autoscaling

The cluster will automatically scale based on CPU and memory metrics from Prometheus.

**Scale-up** triggers when any pod exceeds:
- CPU > 70%
- Memory > 70%

**Scale-down** triggers when 2+ pods are below:
- CPU < 20%
- Memory < 30%

## Next Steps

### Share Your Operator

**Option 1: Docker Hub (already configured)**
```bash
./build.sh
# Image pushed to docker.io/satyams17/redis-operator:TAG
```

**Option 2: Export as tarball**
```bash
# After build.sh completes
TAG=$(grep "newTag:" config/manager/kustomization.yaml | awk '{print $2}')
docker save docker.io/satyams17/redis-operator:$TAG | gzip > redis-operator.tar.gz

# Share redis-operator.tar.gz
# Others load it with:
docker load < redis-operator.tar.gz
```

**Option 3: GitHub Container Registry**
See [DEPLOYMENT.md](DEPLOYMENT.md#option-2-push-to-github-container-registry-ghcr)

### Monitor Your Cluster

```bash
# Check cluster status
kubectl describe rediscluster redis-cluster

# View scaling events
kubectl get events --field-selector involvedObject.name=redis-cluster

# Connect to Redis
kubectl exec -it redis-cluster-0 -- redis-cli
> CLUSTER INFO
> CLUSTER NODES
```

### Customize Configuration

Edit `cluster.yaml` to adjust:
- Number of masters
- Autoscaling thresholds
- Cooldown periods
- Redis version

See [DEPLOYMENT.md](DEPLOYMENT.md#configuration) for all options.

## Troubleshooting

**Operator not starting?**
```bash
kubectl logs -n redis-operator-system deployment/redis-operator-controller-manager
```

**Pods not coming up?**
```bash
kubectl get jobs
kubectl logs job/redis-cluster-bootstrap
```

**Autoscaling not working?**
```bash
# Check Prometheus is reachable from operator
kubectl logs -n redis-operator-system deployment/redis-operator-controller-manager | grep Prometheus
```

## Documentation

- **[DEPLOYMENT.md](DEPLOYMENT.md)** - Detailed deployment guide with all registry options
- **[README.md](README.md)** - Architecture and overview
- **[docs/](docs/)** - Complete documentation

## Support

Report issues at: https://github.com/yourorg/redis-operator/issues
