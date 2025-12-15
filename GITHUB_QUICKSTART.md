# GitHub Quick Start - Step by Step

Follow these exact steps to publish your Redis Operator to GitHub and enable one-command installation for users.

## Step 1: Create GitHub Repository (5 minutes)

1. Go to https://github.com/new
2. Fill in:
   - **Repository name**: `redis-operator`
   - **Description**: `Kubernetes operator for Redis cluster autoscaling with zero-downtime operations`
   - **Public** ✅ (so users can access it)
   - **Do NOT** initialize with README (we have one)
3. Click **Create repository**
4. Copy the repository URL (e.g., `https://github.com/YOUR_USERNAME/redis-operator.git`)

## Step 2: Push Code to GitHub (2 minutes)

```bash
cd /home/satyam/redis-autoscaler/redis-operator

# Initialize git (if not already done)
git init

# Add all files
git add .

# Create initial commit
git commit -m "Initial release: Redis Cluster Autoscaler

- Zero-downtime autoscaling with hot standby
- Automatic resharding on scale-up/down
- Prometheus-based monitoring
- Production-ready operator
"

# Add GitHub remote (replace YOUR_USERNAME with your GitHub username)
git remote add origin https://github.com/SatyamS17/redis-foxtrot-autoscaler.git

# Push to GitHub
git branch -M main
git push -u origin main
```

## Step 3: Create install.yaml (1 minute)

```bash
# Generate the unified install manifest
./create-install-manifest.sh

# Add it to git
git add install.yaml
git commit -m "Add unified install manifest for easy deployment"
git push
```

## Step 4: Create First Release (3 minutes)

### 4a. Tag the version

```bash
git tag -a v1.0.0 -m "Release v1.0.0

First stable release with:
- Zero-downtime autoscaling
- Hot standby strategy
- Automatic resharding
- Prometheus integration
"

git push origin v1.0.0
```

### 4b. Create GitHub Release

1. Go to your repository: `https://github.com/YOUR_USERNAME/redis-operator`
2. Click **Releases** (on the right sidebar)
3. Click **Create a new release**
4. Fill in:
   - **Choose a tag**: Select `v1.0.0`
   - **Release title**: `v1.0.0 - Initial Release`
   - **Description**: Copy the template below

```markdown
## 🚀 Redis Cluster Autoscaler v1.0.0

First stable release!

### ✨ Features
- ⚡ **Zero-downtime autoscaling** with hot standby strategy
- 🔄 **Automatic resharding** on scale-up and scale-down
- 📊 **Prometheus integration** for CPU and memory monitoring
- 🚀 **Instant scale-up** (~5-10 seconds using standby pod)
- 🛡️ **Production-ready** with comprehensive testing

### 📦 Quick Install

Install the operator:
```bash
kubectl apply -f https://raw.githubusercontent.com/SatyamS17/redis-operator/v1.0.0/install.yaml
```

Create a Redis cluster:
```bash
kubectl apply -f https://raw.githubusercontent.com/SatyamS17/redis-operator/v1.0.0/examples/basic.yaml
```

Verify:
```bash
kubectl get pods -n redis-operator-system
kubectl get rediscluster
```

### 📖 Documentation
- [Quick Start Guide](QUICKSTART.md)
- [Deployment Guide](DEPLOYMENT.md)
- [GitHub Setup Guide](GITHUB_SETUP.md)
- [Architecture Overview](README.md)

### 🐳 Container Images
- **Docker Hub**: `docker.io/satyams17/redis-operator:v1.0.0`
- **GHCR**: `ghcr.io/YOUR_USERNAME/redis-operator:v1.0.0`

### 📝 Examples
- [Basic](examples/basic.yaml) - Minimal configuration
- [Development](examples/development.yaml) - Fast iteration
- [Production](examples/production.yaml) - High availability

---
Built with ❤️ using [Kubebuilder](https://book.kubebuilder.io/)
```

5. Click **Publish release**

## Step 5: Update Documentation URLs (2 minutes)

Update all placeholder URLs in the documentation:

```bash
# Replace YOUR_USERNAME with your actual GitHub username
find . -type f -name "*.md" -exec sed -i 's/YOUR_USERNAME/your-actual-username/g' {} +

# Commit the changes
git add .
git commit -m "Update GitHub URLs with actual username"
git push
```

## Step 6: Test the Installation (3 minutes)

Test that users can install it:

```bash
# From a different directory, test the installation
cd /tmp

# Install operator
kubectl apply -f https://raw.githubusercontent.com/YOUR_USERNAME/redis-operator/main/install.yaml

# Wait for operator to be ready
kubectl wait --for=condition=available --timeout=60s deployment/redis-operator-controller-manager -n redis-operator-system

# Create a cluster
kubectl apply -f https://raw.githubusercontent.com/YOUR_USERNAME/redis-operator/main/examples/basic.yaml

# Check status
kubectl get rediscluster
kubectl get pods -l app=redis-cluster
```

## Step 7: Share Your Operator! 🎉

Your operator is now published! Share it:

### Installation command for users:

```bash
kubectl apply -f https://raw.githubusercontent.com/YOUR_USERNAME/redis-operator/v1.0.0/install.yaml
```

### Repository URL:

```
https://github.com/YOUR_USERNAME/redis-operator
```

### Share on:
- Twitter/X with hashtag #kubernetes #redis #k8soperator
- LinkedIn
- Reddit (r/kubernetes, r/redis)
- Dev.to article
- Kubernetes Slack channels
- CNCF Slack

## Optional: GitHub Container Registry (10 minutes)

To host images on GitHub instead of Docker Hub:

### 1. Create Personal Access Token

1. GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token (classic)
3. Name: `redis-operator-packages`
4. Scopes: ✅ `write:packages`, ✅ `read:packages`
5. Generate token and **copy it**

### 2. Login and push

```bash
# Login to GHCR
echo "YOUR_TOKEN" | docker login ghcr.io -u YOUR_USERNAME --password-stdin

# Edit build.sh - change REGISTRY line to:
# REGISTRY="ghcr.io/YOUR_USERNAME"

# Build and push
./build.sh

# The image is now at: ghcr.io/YOUR_USERNAME/redis-operator:TAG
```

### 3. Make package public

1. Go to `https://github.com/YOUR_USERNAME?tab=packages`
2. Click `redis-operator`
3. Package settings → Change visibility → Public

## What Users See

When someone visits your repository, they'll see:

1. **README.md** with clear installation instructions
2. **Releases** with downloadable versions
3. **Examples** directory with ready-to-use configs
4. **Docs** with comprehensive guides
5. **install.yaml** for one-command deployment

Users can install with just:
```bash
kubectl apply -f https://github.com/YOUR_USERNAME/redis-operator/releases/download/v1.0.0/install.yaml
```

## Next Steps

- ⭐ Add badges to README (build status, version, license)
- 📝 Write a blog post about your operator
- 🎥 Create a demo video
- 📊 Set up GitHub Actions for automated builds
- 🐛 Enable GitHub Issues for user feedback
- 💬 Enable GitHub Discussions for community support

## Troubleshooting

**"Permission denied" when pushing:**
- Make sure you're authenticated: `gh auth login` or use SSH keys

**"install.yaml not found":**
- Make sure you ran `./create-install-manifest.sh` first

**Users can't pull image:**
- Make sure the image is public on Docker Hub or GHCR
- Check the image name in `config/manager/kustomization.yaml`

**Installation fails:**
- Check that `install.yaml` is valid: `kubectl apply -f install.yaml --dry-run=client`
- Verify CRDs are included: `grep CustomResourceDefinition install.yaml`

---

**You're done!** 🎉 Your operator is now publicly available and users can install it with a single command!
