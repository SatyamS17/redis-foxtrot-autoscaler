#!/bin/bash
set -ex

echo "=== Cleanup and Re-add New Standby Pods ==="
SERVICE_NAME="$SERVICE_NAME"
NAMESPACE="$NAMESPACE"
ENTRYPOINT_HOST="$ENTRYPOINT_HOST"
ENTRYPOINT="$ENTRYPOINT_WITH_PORT"
REPLICAS_PER_MASTER="$REPLICAS_PER_MASTER"
NEW_STANDBY_INDEX="$NEW_STANDBY_INDEX"
OLD_STANDBY_INDEX="$OLD_STANDBY_INDEX"
CLUSTER_NAME="$CLUSTER_NAME"

echo "New standby index: $NEW_STANDBY_INDEX (will be re-added)"
echo "Old standby index: $OLD_STANDBY_INDEX (will be deleted)"

# Get cluster nodes
cluster_nodes_output=$(redis-cli -h $ENTRYPOINT_HOST cluster nodes)

# ========== STEP 1: Delete new standby pods and their replicas ==========
echo "=== Step 1: Deleting new standby pods (index $NEW_STANDBY_INDEX + replicas) ==="

for i in $(seq 0 $REPLICAS_PER_MASTER); do
  pod_index=$((NEW_STANDBY_INDEX + i))
  POD_NAME="${CLUSTER_NAME}-${pod_index}"
  POD_FQDN="${POD_NAME}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
  POD_IP=$(getent hosts $POD_FQDN | awk '{print $1}')

  if [ -z "$POD_IP" ]; then
    echo "Pod $POD_NAME not found in DNS, skipping"
    continue
  fi

  NODE_ID=$(echo "$cluster_nodes_output" | grep "$POD_IP:6379" | awk '{print $1}')

  if [ -z "$NODE_ID" ]; then
    echo "Pod $POD_NAME ($POD_IP) not found in cluster, skipping"
    continue
  fi

  echo "Deleting pod $POD_NAME (ID: $NODE_ID, IP: $POD_IP)"
  redis-cli --cluster del-node $ENTRYPOINT $NODE_ID || \
    (sleep 5 && redis-cli --cluster del-node $ENTRYPOINT $NODE_ID)
  sleep 2
done

# ========== STEP 2: Delete old standby pods and their replicas ==========
echo "=== Step 2: Deleting old standby pods (index $OLD_STANDBY_INDEX + replicas) ==="

for i in $(seq 0 $REPLICAS_PER_MASTER); do
  pod_index=$((OLD_STANDBY_INDEX + i))
  POD_NAME="${CLUSTER_NAME}-${pod_index}"
  POD_FQDN="${POD_NAME}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
  POD_IP=$(getent hosts $POD_FQDN | awk '{print $1}')

  if [ -z "$POD_IP" ]; then
    echo "Pod $POD_NAME not found in DNS, skipping"
    continue
  fi

  NODE_ID=$(echo "$cluster_nodes_output" | grep "$POD_IP:6379" | awk '{print $1}')

  if [ -z "$NODE_ID" ]; then
    echo "Pod $POD_NAME ($POD_IP) not found in cluster, skipping"
    continue
  fi

  echo "Deleting pod $POD_NAME (ID: $NODE_ID, IP: $POD_IP)"
  redis-cli --cluster del-node $ENTRYPOINT $NODE_ID || \
    (sleep 5 && redis-cli --cluster del-node $ENTRYPOINT $NODE_ID)
  sleep 2
done

echo "Finished deleting old pods from cluster"
sleep 3

# ========== STEP 3: Reset new standby pods to clean state ==========
echo "=== Step 3: Resetting new standby pods to clean state ==="

# Reset the new standby master and replicas
for i in $(seq 0 $REPLICAS_PER_MASTER); do
  pod_index=$((NEW_STANDBY_INDEX + i))
  POD_NAME="${CLUSTER_NAME}-${pod_index}"
  POD_FQDN="${POD_NAME}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
  POD_IP=$(getent hosts $POD_FQDN | awk '{print $1}')

  if [ -z "$POD_IP" ]; then
    echo "WARNING: Pod $POD_NAME not found in DNS, skipping reset"
    continue
  fi

  echo "Resetting pod $POD_NAME ($POD_IP)..."

  # Reset the node - this clears cluster state and data
  redis-cli -h $POD_IP -p 6379 FLUSHALL
  redis-cli -h $POD_IP -p 6379 CLUSTER RESET HARD

  sleep 2
done

echo "Reset complete, nodes are now clean"
sleep 3

# ========== STEP 4: Add new standby pods fresh to cluster ==========
echo "=== Step 4: Adding new standby pods to cluster ==="

# Calculate new standby pod indices
NEW_STANDBY_POD="${CLUSTER_NAME}-${NEW_STANDBY_INDEX}"
NEW_STANDBY_FQDN="${NEW_STANDBY_POD}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
NEW_STANDBY_IP=$(getent hosts $NEW_STANDBY_FQDN | awk '{print $1}')

if [ -z "$NEW_STANDBY_IP" ]; then
  echo "ERROR: Could not resolve new standby pod $NEW_STANDBY_POD"
  exit 1
fi

echo "Adding new standby master: $NEW_STANDBY_POD ($NEW_STANDBY_IP:6379)"

# Add as fresh node (should work now after CLUSTER RESET)
redis-cli --cluster add-node ${NEW_STANDBY_IP}:6379 $ENTRYPOINT
sleep 5

cluster_nodes_output=$(redis-cli -h $ENTRYPOINT_HOST cluster nodes)
NEW_STANDBY_NODE_ID=$(echo "$cluster_nodes_output" | grep "$NEW_STANDBY_IP:6379" | awk '{print $1}')

if [ -z "$NEW_STANDBY_NODE_ID" ]; then
  echo "ERROR: Failed to get new standby node ID after adding"
  exit 1
fi
echo "New standby master added with ID: $NEW_STANDBY_NODE_ID"

# ========== STEP 5: Add replicas for new standby ==========
if [ "$REPLICAS_PER_MASTER" -gt 0 ]; then
  echo "=== Step 5: Adding replicas for new standby master ==="

  for i in $(seq 1 $REPLICAS_PER_MASTER); do
    REPLICA_INDEX=$((NEW_STANDBY_INDEX + i))
    REPLICA_POD="${CLUSTER_NAME}-${REPLICA_INDEX}"
    REPLICA_FQDN="${REPLICA_POD}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
    REPLICA_IP=$(getent hosts $REPLICA_FQDN | awk '{print $1}')

    if [ -z "$REPLICA_IP" ]; then
      echo "WARNING: Could not resolve replica pod $REPLICA_POD, skipping"
      continue
    fi

    echo "Adding replica: $REPLICA_POD ($REPLICA_IP:6379) as slave of $NEW_STANDBY_NODE_ID"

    # Check if replica is already in cluster
    if echo "$cluster_nodes_output" | grep -q "$REPLICA_IP:6379"; then
      echo "Replica $REPLICA_POD already in cluster"
    else
      redis-cli --cluster add-node ${REPLICA_IP}:6379 $ENTRYPOINT --cluster-slave --cluster-master-id $NEW_STANDBY_NODE_ID
      sleep 3
      echo "Replica $REPLICA_POD added"
    fi
  done
fi

echo "=== Cleanup and Re-add Complete ==="
redis-cli -h $ENTRYPOINT_HOST cluster nodes
