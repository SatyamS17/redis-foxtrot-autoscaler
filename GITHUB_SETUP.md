# Setting Up Redis Operator as a GitHub Repository

This guide shows you how to publish the Redis Operator to GitHub and enable users to install it directly.

## Step 1: Create GitHub Repository

1. **Go to GitHub** and create a new repository:
   - Name: `redis-operator`
   - Description: "Kubernetes operator for Redis cluster autoscaling with zero-downtime operations"
   - Public or Private (your choice)
   - Don't initialize with README (we already have one)

2. **Note your repository URL:**
   ```
   https://github.com/YOUR_USERNAME/redis-operator.git
   ```

## Step 2: Initialize Git in Your Operator Directory

```bash
cd /home/satyam/redis-autoscaler/redis-operator

# Initialize git if not already done
git init

# Add all files
git add .

# Create initial commit
git commit -m "Initial commit: Redis Cluster Autoscaler Operator

- Zero-downtime autoscaling with hot standby strategy
- Automatic resharding on scale-up/down
- Prometheus-based metrics monitoring
- Kubernetes operator using controller-runtime
"

# Add GitHub as remote
git remote add origin https://github.com/YOUR_USERNAME/redis-operator.git

# Push to GitHub
git branch -M main
git push -u origin main
```

## Step 3: Configure GitHub Container Registry (GHCR)

This allows users to pull pre-built images without Docker Hub.

### 3a. Create GitHub Personal Access Token

1. Go to GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Click "Generate new token (classic)"
3. Name it: `redis-operator-packages`
4. Select scopes:
   - ✅ `write:packages` (Upload packages)
   - ✅ `read:packages` (Download packages)
   - ✅ `delete:packages` (Delete packages)
5. Generate and **save the token securely**

### 3b. Login to GHCR

```bash
echo "YOUR_GITHUB_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

### 3c. Update build.sh to use GHCR

Edit `build.sh` and change the registry:

```bash
# Change from:
REGISTRY="docker.io/satyams17"

# To:
REGISTRY="ghcr.io/YOUR_GITHUB_USERNAME"
```

### 3d. Build and push to GHCR

```bash
./build.sh
```

This will push the image to `ghcr.io/YOUR_GITHUB_USERNAME/redis-operator:TAG`

### 3e. Make the package public (optional)

1. Go to your GitHub profile → Packages
2. Find `redis-operator`
3. Click Package settings
4. Scroll down to "Danger Zone"
5. Click "Change visibility" → Make Public

## Step 4: Create GitHub Releases

### 4a. Tag your version

```bash
git tag -a v1.0.0 -m "Release v1.0.0: Initial stable release

Features:
- Zero-downtime autoscaling
- Hot standby strategy for instant scale-up
- Automatic resharding
- Prometheus integration
- Production-ready with comprehensive testing
"

git push origin v1.0.0
```

### 4b. Create GitHub Release

1. Go to your repository on GitHub
2. Click "Releases" → "Create a new release"
3. Choose tag: `v1.0.0`
4. Release title: `v1.0.0 - Initial Release`
5. Description:
   ```markdown
   ## Redis Cluster Autoscaler v1.0.0

   First stable release of the Redis Cluster Autoscaler operator!

   ### Features
   - ⚡ Zero-downtime autoscaling with hot standby strategy
   - 🔄 Automatic resharding on scale-up and scale-down
   - 📊 Prometheus-based CPU and memory monitoring
   - 🚀 Instant scale-up (~5-10 seconds using standby pod)
   - 🛡️ Production-ready with comprehensive testing

   ### Quick Start
   ```bash
   # Install the operator
   kubectl apply -f https://raw.githubusercontent.com/YOUR_USERNAME/redis-operator/v1.0.0/install.yaml

   # Create a Redis cluster
   kubectl apply -f https://raw.githubusercontent.com/YOUR_USERNAME/redis-operator/v1.0.0/examples/cluster.yaml
   ```

   ### Documentation
   - [Quick Start Guide](QUICKSTART.md)
   - [Deployment Guide](DEPLOYMENT.md)
   - [Architecture Overview](README.md)

   ### Container Images
   - Docker Hub: `docker.io/satyams17/redis-operator:v1.0.0`
   - GHCR: `ghcr.io/YOUR_USERNAME/redis-operator:v1.0.0`
   ```

6. Attach binaries (optional):
   - You can attach the exported docker image tarball here
   - Users can download and load it offline

## Step 5: Create One-Command Installation

Create `install.yaml` that bundles everything:

```bash
# Run this from the redis-operator directory
./create-install-manifest.sh
```

This creates a single `install.yaml` file containing:
- Namespace
- CRDs
- RBAC (ServiceAccount, Roles, RoleBindings)
- Operator Deployment

Users can install with:
```bash
kubectl apply -f https://raw.githubusercontent.com/YOUR_USERNAME/redis-operator/main/install.yaml
```

## Step 6: Update Documentation

Update all docs to reference your GitHub repository:

1. **README.md** - Change installation section
2. **DEPLOYMENT.md** - Update image references
3. **QUICKSTART.md** - Use GitHub-based installation

## Step 7: Set Up GitHub Actions (Optional)

Create `.github/workflows/build-and-push.yaml` for automated builds:

```yaml
name: Build and Push Operator

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
    - uses: actions/checkout@v3

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v2

    - name: Log in to GHCR
      uses: docker/login-action@v2
      with:
        registry: ghcr.io
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - name: Extract metadata
      id: meta
      uses: docker/metadata-action@v4
      with:
        images: ghcr.io/${{ github.repository }}

    - name: Build and push
      uses: docker/build-push-action@v4
      with:
        context: .
        push: true
        tags: ${{ steps.meta.outputs.tags }}
        labels: ${{ steps.meta.outputs.labels }}
```

This automatically builds and pushes images when you create a new tag!

## Step 8: Add Examples Directory

```bash
mkdir -p examples
cp cluster.yaml examples/
cp cluster-existing.yaml examples/

# Add more examples
cat > examples/production.yaml <<'EOF'
apiVersion: cache.example.com/v1
kind: RedisCluster
metadata:
  name: prod-redis
  namespace: production
spec:
  masters: 10
  minMasters: 5
  replicasPerMaster: 2
  redisVersion: "7.2"
  autoScaleEnabled: true
  cpuThreshold: 80
  memoryThreshold: 85
  scaleCooldownSeconds: 300
  prometheusURL: "http://prometheus-operated.monitoring.svc:9090"
EOF

git add examples/
git commit -m "Add example configurations"
git push
```

## User Installation Flow

After setup, users can install your operator like this:

```bash
# Method 1: One command install (easiest)
kubectl apply -f https://raw.githubusercontent.com/YOUR_USERNAME/redis-operator/v1.0.0/install.yaml

# Method 2: Clone and install
git clone https://github.com/YOUR_USERNAME/redis-operator.git
cd redis-operator
kubectl apply -k config/default

# Method 3: Install specific version
kubectl apply -f https://github.com/YOUR_USERNAME/redis-operator/releases/download/v1.0.0/install.yaml
```

Then create a cluster:
```bash
kubectl apply -f https://raw.githubusercontent.com/YOUR_USERNAME/redis-operator/main/examples/cluster.yaml
```

## Next Steps

1. ✅ Create GitHub repository
2. ✅ Push code to GitHub
3. ✅ Set up GHCR (optional but recommended)
4. ✅ Create install.yaml manifest
5. ✅ Tag version and create GitHub release
6. ✅ Update documentation with GitHub URLs
7. ✅ Add GitHub Actions for CI/CD (optional)
8. ✅ Add examples directory
9. Share your repository!

## Tips

- **README.md badges**: Add status badges for build, version, license
- **CHANGELOG.md**: Keep a changelog of releases
- **CONTRIBUTING.md**: Guidelines for contributors
- **.gitignore**: Make sure sensitive files aren't committed
- **LICENSE**: Add an open-source license (Apache 2.0 recommended for K8s operators)

## Example Repository Structure

```
redis-operator/
├── .github/
│   └── workflows/
│       └── build-and-push.yaml
├── api/
├── cmd/
├── config/
├── docs/
├── examples/
│   ├── cluster.yaml
│   ├── production.yaml
│   └── development.yaml
├── internal/
├── .gitignore
├── CHANGELOG.md
├── CONTRIBUTING.md
├── DEPLOYMENT.md
├── Dockerfile
├── go.mod
├── go.sum
├── install.yaml
├── LICENSE
├── Makefile
├── QUICKSTART.md
└── README.md
```
