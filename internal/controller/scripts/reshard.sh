#!/bin/bash
set -ex

echo "=== Smart Scale-Up: Standby Activation (use existing standby) ==="
ENTRYPOINT="$ANY_POD_ENTRYPOINT"
OVERLOADED_POD="$OVERLOADED_POD"
STANDBY_POD="$STANDBY_POD"
ANY_POD_HOST="$ANY_POD_HOST"
ANY_POD_PORT="$ANY_POD_PORT"
CLUSTER_NAME="$CLUSTER_NAME"
SERVICE_NAME="$SERVICE_NAME"
NAMESPACE="$NAMESPACE"

wait_until=$(($(date +%s) + 600))

echo "Standby to activate: $STANDBY_POD"
echo "Overloaded pod to relieve: $OVERLOADED_POD"

# Step 0: Try to fix cluster inconsistencies first (best-effort)
echo "=== Step 0: Running cluster fix to ensure consistency ==="
timeout 300 redis-cli --cluster fix $ENTRYPOINT --cluster-fix-with-unreachable-masters || {
  echo "WARNING: Cluster fix encountered issues, but continuing..."
}

# Verify cluster state after fix
CLUSTER_STATE=$(redis-cli -h $ANY_POD_HOST -p $ANY_POD_PORT cluster info | grep cluster_state | cut -d: -f2 | tr -d '\r')
if [ "$CLUSTER_STATE" != "ok" ]; then
  echo "ERROR: Cluster state is '$CLUSTER_STATE' after fix (expected: ok)"
  redis-cli -h $ANY_POD_HOST -p $ANY_POD_PORT cluster info || true
  redis-cli -h $ANY_POD_HOST -p $ANY_POD_PORT cluster nodes || true
  exit 1
fi
echo "Cluster state: $CLUSTER_STATE"

# Resolve standby pod
STANDBY_FQDN="${STANDBY_POD}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
STANDBY_IP=$(getent hosts $STANDBY_FQDN | awk '{print $1}')
if [ -z "$STANDBY_IP" ]; then
  echo "ERROR: Could not resolve standby pod $STANDBY_POD"
  exit 1
fi

cluster_nodes_output=$(redis-cli -h $ANY_POD_HOST -p $ANY_POD_PORT cluster nodes)
STANDBY_NODE_ID=$(echo "$cluster_nodes_output" | grep "$STANDBY_IP:6379" | grep master | awk '{print $1}')
if [ -z "$STANDBY_NODE_ID" ]; then
  echo "ERROR: Standby node not found in cluster nodes output"
  echo "$cluster_nodes_output"
  exit 1
fi

# Verify standby has zero slots
STANDBY_SLOTS=$(echo "$cluster_nodes_output" | grep "^$STANDBY_NODE_ID" | awk '{
  slots=0
  for(i=9;i<=NF;i++){
    if($i ~ /^[0-9]+-[0-9]+$/){
      split($i,range,"-")
      slots += (range[2]-range[1]+1)
    } else if($i ~ /^[0-9]+$/){
      slots += 1
    }
  }
  print slots
}')
if [ "$STANDBY_SLOTS" -ne 0 ]; then
  echo "ERROR: Standby node has $STANDBY_SLOTS slots (expected 0)"
  exit 1
fi
echo "Standby verified: $STANDBY_POD (ID: $STANDBY_NODE_ID, IP: $STANDBY_IP, Slots: 0)"

# Find overloaded master
OVERLOADED_FQDN="${OVERLOADED_POD}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
OVERLOADED_IP=$(getent hosts $OVERLOADED_FQDN | awk '{print $1}')
if [ -z "$OVERLOADED_IP" ]; then
  echo "ERROR: Could not resolve overloaded pod $OVERLOADED_POD"
  exit 1
fi
OVERLOADED_MASTER_ID=$(echo "$cluster_nodes_output" | grep "$OVERLOADED_IP:6379" | grep master | awk '{print $1}')
if [ -z "$OVERLOADED_MASTER_ID" ]; then
  echo "ERROR: Overloaded master not found in cluster nodes output"
  exit 1
fi
echo "Overloaded master: $OVERLOADED_POD (ID: $OVERLOADED_MASTER_ID)"

# Calculate slots to move (half)
TOTAL_SLOTS=$(echo "$cluster_nodes_output" | grep "^$OVERLOADED_MASTER_ID " | awk '{
  slots=0
  for(i=9;i<=NF;i++){
    if($i ~ /^[0-9]+-[0-9]+$/){
      split($i,range,"-")
      slots += (range[2]-range[1]+1)
    } else if($i ~ /^[0-9]+$/){
      slots += 1
    }
  }
  print slots
}')
SLOTS_TO_MOVE=$((TOTAL_SLOTS / 2))
if [ "$SLOTS_TO_MOVE" -le 0 ]; then
  echo "Nothing to move (TOTAL_SLOTS=$TOTAL_SLOTS)"
  exit 0
fi
echo "Will move $SLOTS_TO_MOVE out of $TOTAL_SLOTS slots from overloaded master to standby"

# Disable full coverage temporarily on all nodes
echo "=== Disabling full coverage check on all nodes ==="
node_ips=$(echo "$cluster_nodes_output" | awk '{print $2}' | cut -d'@' -f1 | cut -d':' -f1 | sort -u)
for ip in $node_ips; do
  timeout 5 redis-cli -h $ip -p 6379 CONFIG SET cluster-require-full-coverage no || true
done
sleep 2

# Reshard using the standby node (use smaller pipeline for smoother migration)
echo "=== Resharding $SLOTS_TO_MOVE slots ==="
redis-cli --cluster reshard $ENTRYPOINT \
  --cluster-from $OVERLOADED_MASTER_ID \
  --cluster-to $STANDBY_NODE_ID \
  --cluster-slots $SLOTS_TO_MOVE \
  --cluster-yes \
  --cluster-timeout 10000 \
  --cluster-pipeline 10

# Re-enable full coverage
echo "=== Re-enabling full coverage ==="
for ip in $node_ips; do
  timeout 5 redis-cli -h $ip -p 6379 CONFIG SET cluster-require-full-coverage yes || true
done
sleep 2

echo "=== Smart Scale-Up Complete: Standby Activated ==="
