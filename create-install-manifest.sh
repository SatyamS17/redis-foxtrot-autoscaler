#!/bin/bash
set -e

echo "Creating unified install.yaml manifest..."

# Create install.yaml with all resources
cat > install.yaml <<'EOF'
# Redis Operator Installation Manifest
# This file contains all resources needed to install the Redis Operator
#
# Install with:
#   kubectl apply -f install.yaml
#
# Then create a Redis cluster:
#   kubectl apply -f examples/cluster.yaml

---
EOF

# Add namespace
echo "Adding namespace..."
cat >> install.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: redis-operator-system
  labels:
    app.kubernetes.io/name: redis-operator
    app.kubernetes.io/component: operator

---
EOF

# Add CRDs
echo "Adding CRDs..."
kubectl kustomize config/crd >> install.yaml
echo "---" >> install.yaml

# Add RBAC
echo "Adding RBAC..."
kubectl kustomize config/rbac >> install.yaml
echo "---" >> install.yaml

# Add Manager deployment
echo "Adding Manager deployment..."
kubectl kustomize config/manager >> install.yaml

echo ""
echo "✅ Created install.yaml"
echo ""
echo "Users can install with:"
echo "  kubectl apply -f install.yaml"
echo ""
echo "To test locally:"
echo "  kubectl apply -f install.yaml"
echo "  kubectl apply -f examples/cluster.yaml"
