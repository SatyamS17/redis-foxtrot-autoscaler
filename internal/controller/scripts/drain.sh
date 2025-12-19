#!/bin/sh
set -ex

echo "=== Smart Scale-Down with Standby Preservation ==="
POD_TO_DRAIN="$POD_TO_DRAIN"
DEST_POD_1="$DEST_POD_1"
DEST_POD_2="$DEST_POD_2"
STANDBY_POD="$STANDBY_POD"
SERVICE_NAME="$SERVICE_NAME"
NAMESPACE="$NAMESPACE"
ENTRYPOINT_HOST="$ENTRYPOINT_HOST"
ENTRYPOINT="$ENTRYPOINT_WITH_PORT"

echo "Pod to drain: $POD_TO_DRAIN (will become new standby)"
echo "Current standby: $STANDBY_POD (will become active master)"
echo "Destinations: $DEST_POD_1, $DEST_POD_2"

# ========== CLUSTER FIX ==========
echo "=== Step 0: Quick cluster health check ==="
CLUSTER_STATE=$(redis-cli -h $ENTRYPOINT_HOST cluster info | grep cluster_state | cut -d: -f2 | tr -d '\r')

if [ "$CLUSTER_STATE" = "ok" ]; then
  echo "Cluster state is OK, skipping cluster fix"
else
  echo "Cluster state is '$CLUSTER_STATE', running fix..."
  timeout 300 redis-cli --cluster fix $ENTRYPOINT --cluster-fix-with-unreachable-masters || {
    echo "WARNING: Cluster fix failed or timed out, continuing anyway..."
  }
fi

CLUSTER_STATE=$(redis-cli -h $ENTRYPOINT_HOST cluster info | grep cluster_state | cut -d: -f2 | tr -d '\r')
if [ "$CLUSTER_STATE" != "ok" ]; then
  echo "ERROR: Cluster state is '$CLUSTER_STATE' after fix (expected: ok)"
  redis-cli -h $ENTRYPOINT_HOST cluster info
  redis-cli -h $ENTRYPOINT_HOST cluster nodes
  exit 1
fi

echo "Cluster fix complete. State: $CLUSTER_STATE"

# ========== GHOST NODE CLEANUP ==========
echo "=== Step 0.5: Cleanup failed/disconnected nodes ==="
FAILED_NODES=$(redis-cli -h $ENTRYPOINT_HOST -p 6379 cluster nodes | grep -E 'fail|disconnected|noaddr' | awk '{print $1}')

if [ -n "$FAILED_NODES" ]; then
  FAILED_COUNT=$(echo "$FAILED_NODES" | wc -w)
  echo "Found $FAILED_COUNT failed/ghost nodes to clean up"

  HEALTHY_IPS=$(redis-cli -h $ENTRYPOINT_HOST -p 6379 cluster nodes | \
    grep -v -E 'fail|disconnected|noaddr' | \
    awk '{print $2}' | cut -d'@' -f1 | cut -d':' -f1 | sort -u)

  for failed_id in $FAILED_NODES; do
    echo "Forgetting failed node: $failed_id"
    for ip in $HEALTHY_IPS; do
      redis-cli -h $ip -p 6379 CLUSTER FORGET $failed_id 2>/dev/null || true
    done
  done

  sleep 2
  echo "Ghost node cleanup complete"
else
  echo "No failed nodes found - cluster is clean"
fi

# ========== VERIFY STANDBY ==========
echo "=== Step 1: Verify standby node ==="
STANDBY_FQDN="${STANDBY_POD}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
STANDBY_IP=$(getent hosts $STANDBY_FQDN | awk '{print $1}')

if [ -z "$STANDBY_IP" ]; then
  echo "ERROR: Could not resolve standby pod $STANDBY_POD"
  exit 1
fi

STANDBY_NODE_ID=$(redis-cli -h $ENTRYPOINT_HOST cluster nodes | grep "$STANDBY_IP:6379" | grep master | awk '{print $1}')

if [ -z "$STANDBY_NODE_ID" ]; then
  echo "ERROR: Standby node not found in cluster"
  exit 1
fi

# Verify standby has no slots
STANDBY_SLOTS=$(redis-cli -h $ENTRYPOINT_HOST cluster nodes | grep "^$STANDBY_NODE_ID " | awk '{
  slots=0
  for(i=9; i<=NF; i++) {
    if($i ~ /^[0-9]+-[0-9]+$/) {
      split($i, range, "-")
      slots += (range[2] - range[1] + 1)
    } else if($i ~ /^[0-9]+$/) {
      slots += 1
    }
  }
  print slots
}')

if [ "$STANDBY_SLOTS" -ne 0 ]; then
  echo "WARNING: Standby node has $STANDBY_SLOTS slots (expected 0)"
  echo "This is unusual but we'll continue..."
fi

echo "Standby verified: $STANDBY_POD (ID: $STANDBY_NODE_ID)"

# ========== RESOLVE IPs ==========
echo "=== Step 2: Resolving pod IPs ==="
POD_TO_DRAIN_FQDN="${POD_TO_DRAIN}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
POD_IP=$(getent hosts $POD_TO_DRAIN_FQDN | awk '{print $1}')

DEST1_FQDN="${DEST_POD_1}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
DEST1_IP=$(getent hosts $DEST1_FQDN | awk '{print $1}')

if [ -z "$POD_IP" ]; then
  echo "ERROR: Could not resolve IP for $POD_TO_DRAIN"
  exit 1
fi

if [ -z "$DEST1_IP" ]; then
  echo "ERROR: Could not resolve IP for $DEST_POD_1"
  exit 1
fi

echo "Pod to drain: $POD_TO_DRAIN (IP: $POD_IP)"
echo "Destination 1: $DEST_POD_1 (IP: $DEST1_IP)"

# Check if we have a second destination
DEST2_IP=""
if [ -n "$DEST_POD_2" ]; then
  DEST2_FQDN="${DEST_POD_2}.${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local"
  DEST2_IP=$(getent hosts $DEST2_FQDN | awk '{print $1}')
  echo "Destination 2: $DEST_POD_2 (IP: $DEST2_IP)"
fi

# ========== FIND NODE IDs ==========
echo "=== Step 3: Finding Redis node IDs ==="
NODE_TO_DRAIN=$(redis-cli -h $ENTRYPOINT_HOST cluster nodes | \
  grep "$POD_IP:6379" | grep master | awk '{print $1}')

if [ -z "$NODE_TO_DRAIN" ]; then
  echo "Node with IP $POD_IP not found. Assuming already removed."
  exit 0
fi
echo "Node to drain: $NODE_TO_DRAIN"

DEST1_ID=$(redis-cli -h $ENTRYPOINT_HOST cluster nodes | \
  grep "$DEST1_IP:6379" | grep master | awk '{print $1}')

if [ -z "$DEST1_ID" ]; then
  echo "ERROR: Could not find master node for $DEST_POD_1"
  exit 1
fi
echo "Destination 1 node ID: $DEST1_ID"

DEST2_ID=""
if [ -n "$DEST2_IP" ]; then
  DEST2_ID=$(redis-cli -h $ENTRYPOINT_HOST cluster nodes | \
    grep "$DEST2_IP:6379" | grep master | awk '{print $1}')

  if [ -z "$DEST2_ID" ]; then
    echo "ERROR: Could not find master node for $DEST_POD_2"
    exit 1
  fi
  echo "Destination 2 node ID: $DEST2_ID"
fi

# ========== CHECK SLOT COUNT ==========
echo "=== Step 4: Checking slot count ==="
SLOT_COUNT=$(redis-cli -h $ENTRYPOINT_HOST cluster nodes | \
  grep "^$NODE_TO_DRAIN" | awk '{
    slots=0
    for(i=9; i<=NF; i++) {
      if($i ~ /^[0-9]+-[0-9]+$/) {
        split($i, range, "-")
        slots += (range[2] - range[1] + 1)
      } else if($i ~ /^[0-9]+$/) {
        slots += 1
      }
    }
    print slots
  }')

echo "Node has $SLOT_COUNT slots"

if [ "$SLOT_COUNT" -eq 0 ]; then
  echo "Node has no slots. Skipping migration."
else
  # ========== DISABLE FULL COVERAGE ==========
  echo "=== Step 5: Disabling full coverage requirement ==="
  node_ips=$(redis-cli -h $ENTRYPOINT_HOST cluster nodes | \
    awk '{print $2}' | cut -d'@' -f1 | cut -d':' -f1 | sort -u)
  for ip in $node_ips; do
    timeout 5 redis-cli -h $ip -p 6379 CONFIG SET cluster-require-full-coverage no || true
  done
  sleep 2

  # ========== MIGRATE SLOTS ==========
  echo "=== Step 6: Migrating slots ==="
  if [ -n "$DEST2_ID" ]; then
    # Split between two destinations
    HALF_SLOTS=$((SLOT_COUNT / 2))
    REMAINING_SLOTS=$((SLOT_COUNT - HALF_SLOTS))

    echo "Migrating $HALF_SLOTS slots to $DEST1_ID..."
    echo "$HALF_SLOTS" | redis-cli --cluster reshard $ENTRYPOINT \
      --cluster-from $NODE_TO_DRAIN \
      --cluster-to $DEST1_ID \
      --cluster-yes \
      --cluster-timeout 10000 \
      --cluster-pipeline 10

    sleep 5

    echo "Migrating remaining $REMAINING_SLOTS slots to $DEST2_ID..."
    echo "$REMAINING_SLOTS" | redis-cli --cluster reshard $ENTRYPOINT \
      --cluster-from $NODE_TO_DRAIN \
      --cluster-to $DEST2_ID \
      --cluster-yes \
      --cluster-timeout 10000 \
      --cluster-pipeline 10
  else
    # All slots go to single destination
    echo "Migrating all $SLOT_COUNT slots to $DEST1_ID..."
    echo "$SLOT_COUNT" | redis-cli --cluster reshard $ENTRYPOINT \
      --cluster-from $NODE_TO_DRAIN \
      --cluster-to $DEST1_ID \
      --cluster-yes \
      --cluster-timeout 10000 \
      --cluster-pipeline 10
  fi

  sleep 5

  # ========== RE-ENABLE FULL COVERAGE ==========
  echo "=== Step 8: Re-enabling full coverage requirement ==="
  for ip in $node_ips; do
    timeout 5 redis-cli -h $ip -p 6379 CONFIG SET cluster-require-full-coverage yes || true
  done
  sleep 2
fi

# ========== VERIFY ==========
echo "=== Step 9: Final verification ==="
redis-cli -h $ENTRYPOINT_HOST cluster nodes
redis-cli -h $ENTRYPOINT_HOST cluster info

echo "=== Smart Scale-Down Complete ==="
echo "Drained pod $POD_TO_DRAIN now has 0 slots and will become new standby (along with its replica)"
echo "Its slots have been migrated away - StatefulSet will handle deletion of old standby pods"
