# Redis Operator Deployment Guide

This guide shows you how to deploy the Redis Cluster Autoscaler operator to your Kubernetes cluster.

## Prerequisites

- Kubernetes cluster (v1.19+)
- kubectl configured for your cluster
- Prometheus Operator installed (for autoscaling metrics)
- Docker (for building the operator image)

## Quick Start

### 1. Build and Deploy the Operator

Use the provided build script to build and deploy:

```bash
./build.sh
```

This script will:
- Build the Docker image
- Push it to Docker Hub (satyams17/redis-operator)
- Deploy the operator to your cluster
- Apply CRDs and RBAC

### 2. Deploy a Redis Cluster

Apply the example cluster configuration:

```bash
kubectl apply -f cluster.yaml
```

### 3. Verify Deployment

Check that the operator is running:

```bash
kubectl get pods -n redis-operator-system
```

Check your Redis cluster:

```bash
kubectl get rediscluster
kubectl get pods -l app=redis-cluster
```

## Building and Sharing the Operator

### Option 1: Push to Docker Hub (Public)

1. **Login to Docker Hub:**
   ```bash
   docker login
   ```

2. **Build and push:**
   ```bash
   ./build.sh
   ```

   This pushes to `docker.io/satyams17/redis-operator:TAG`

3. **Share with others:**
   Others can deploy using:
   ```bash
   kubectl apply -k config/default
   ```

### Option 2: Push to GitHub Container Registry (GHCR)

1. **Create a Personal Access Token (PAT):**
   - Go to GitHub Settings → Developer settings → Personal access tokens
   - Create token with `write:packages` permission

2. **Login to GHCR:**
   ```bash
   echo "YOUR_PAT" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
   ```

3. **Update build.sh to use GHCR:**
   Edit `build.sh` and change:
   ```bash
   REGISTRY="docker.io/satyams17"
   ```
   to:
   ```bash
   REGISTRY="ghcr.io/YOUR_GITHUB_USERNAME"
   ```

4. **Build and push:**
   ```bash
   ./build.sh
   ```

5. **Update kustomization.yaml:**
   Edit `config/manager/kustomization.yaml`:
   ```yaml
   images:
   - name: controller
     newName: ghcr.io/YOUR_GITHUB_USERNAME/redis-operator
     newTag: TAG
   ```

### Option 3: Export and Share Image Tarball

If you want to share without a registry:

1. **Build the image:**
   ```bash
   make docker-build IMG=redis-operator:v1.0.0
   ```

2. **Save image to tarball:**
   ```bash
   docker save redis-operator:v1.0.0 | gzip > redis-operator-v1.0.0.tar.gz
   ```

3. **Share the tarball** via file transfer (S3, Google Drive, etc.)

4. **Load on another machine:**
   ```bash
   docker load < redis-operator-v1.0.0.tar.gz
   ```

5. **Deploy:**
   ```bash
   # Update config/manager/kustomization.yaml to use local image
   images:
   - name: controller
     newName: redis-operator
     newTag: v1.0.0

   # Deploy
   kubectl apply -k config/default
   ```

### Option 4: Private Registry (AWS ECR Example)

1. **Create ECR repository:**
   ```bash
   aws ecr create-repository --repository-name redis-operator
   ```

2. **Login to ECR:**
   ```bash
   aws ecr get-login-password --region us-east-1 | \
     docker login --username AWS --password-stdin \
     ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
   ```

3. **Build and push:**
   ```bash
   # Update build.sh
   REGISTRY="ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com"
   IMAGE_NAME="redis-operator"

   # Build and push
   ./build.sh
   ```

4. **Create image pull secret:**
   ```bash
   kubectl create secret docker-registry ecr-secret \
     --docker-server=ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com \
     --docker-username=AWS \
     --docker-password=$(aws ecr get-login-password) \
     -n redis-operator-system
   ```

5. **Update deployment to use secret:**
   Add to `config/manager/manager.yaml`:
   ```yaml
   spec:
     template:
       spec:
         imagePullSecrets:
         - name: ecr-secret
   ```

## Configuration

### Basic Cluster Configuration (cluster.yaml)

```yaml
apiVersion: cache.example.com/v1
kind: RedisCluster
metadata:
  name: redis-cluster
  namespace: default
spec:
  # Cluster size
  masters: 3                    # Number of master nodes
  minMasters: 3                 # Minimum masters (scale-down limit)
  replicasPerMaster: 1          # Replicas per master

  # Redis version
  redisVersion: "7.2"

  # Autoscaling thresholds
  autoScaleEnabled: true
  cpuThreshold: 70              # Scale up when CPU > 70%
  cpuThresholdLow: 20           # Scale down when CPU < 20%
  memoryThreshold: 70           # Scale up when Memory > 70%
  memoryThresholdLow: 30        # Scale down when Memory < 30%

  # Timing
  reshardTimeoutSeconds: 600    # Max time for resharding operations
  scaleCooldownSeconds: 60      # Wait time between scaling operations

  # Prometheus
  prometheusURL: "http://prometheus-operated.monitoring.svc:9090"
  metricsQueryInterval: 15      # How often to query metrics (seconds)
```

### Production Configuration Example

```yaml
apiVersion: cache.example.com/v1
kind: RedisCluster
metadata:
  name: prod-redis
  namespace: production
spec:
  masters: 10
  minMasters: 5
  replicasPerMaster: 2          # High availability with 2 replicas
  redisVersion: "7.2"

  autoScaleEnabled: true
  cpuThreshold: 80
  cpuThresholdLow: 25
  memoryThreshold: 85
  memoryThresholdLow: 35

  reshardTimeoutSeconds: 900    # Longer timeout for large clusters
  scaleCooldownSeconds: 300     # 5 min cooldown for stability

  prometheusURL: "http://prometheus-operated.monitoring.svc:9090"
  metricsQueryInterval: 30
```

## Monitoring

### View Operator Logs

```bash
kubectl logs -n redis-operator-system deployment/redis-operator-controller-manager -f
```

### Check Cluster Status

```bash
kubectl describe rediscluster redis-cluster
```

### View Scaling Events

```bash
kubectl get events --field-selector involvedObject.name=redis-cluster
```

### Connect to Redis Cluster

```bash
# Get a pod
kubectl exec -it redis-cluster-0 -- redis-cli

# Check cluster info
127.0.0.1:6379> CLUSTER INFO
127.0.0.1:6379> CLUSTER NODES
```

## Troubleshooting

### Operator Not Starting

```bash
# Check operator logs
kubectl logs -n redis-operator-system deployment/redis-operator-controller-manager

# Check RBAC permissions
kubectl get clusterrole redis-operator-manager-role
kubectl get clusterrolebinding redis-operator-manager-rolebinding
```

### Pods Not Bootstrapping

```bash
# Check bootstrap job
kubectl get jobs
kubectl logs job/redis-cluster-bootstrap

# Check pod status
kubectl describe pod redis-cluster-0
```

### Autoscaling Not Working

```bash
# Verify Prometheus is reachable
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://prometheus-operated.monitoring.svc:9090/-/healthy

# Check operator logs for metric queries
kubectl logs -n redis-operator-system deployment/redis-operator-controller-manager | grep "query"
```

### Scale-Up/Scale-Down Failures

```bash
# Check reshard/drain job logs
kubectl get jobs
kubectl logs job/redis-cluster-reshard
kubectl logs job/redis-cluster-drain

# Check cluster status
kubectl describe rediscluster redis-cluster
```

## Uninstalling

### Remove Redis Cluster

```bash
kubectl delete rediscluster redis-cluster
```

### Uninstall Operator

```bash
kubectl delete -k config/default
```

### Remove CRDs

```bash
kubectl delete crd redisclusters.cache.example.com
```

## Next Steps

- See [README.md](README.md) for architecture overview
- See [docs/](docs/) for detailed documentation
- Test autoscaling by generating load on your cluster
- Configure Grafana dashboards for monitoring

## Support

- GitHub Issues: https://github.com/yourorg/redis-operator/issues
- Documentation: [docs/](docs/)
