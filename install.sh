#!/usr/bin/env bash
set -e

echo "Installing Redis Foxtrot Autoscaler Operator"

kubectl apply -f https://raw.githubusercontent.com/SatyamS17/redis-foxtrot-autoscaler/main/operator.yaml

echo "Waiting for operator to become ready..."
kubectl rollout status deployment/redis-foxtrot-autoscaler-controller-manager \
  -n redis-operator-system --timeout=120s

echo "Installation complete"
