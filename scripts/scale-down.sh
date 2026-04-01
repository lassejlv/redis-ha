#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_header "Scaling Down Redis Cluster"

OVERRIDE="$PROJECT_DIR/docker-compose.override.yml"

# Check minimum node count
NODE_COUNT=$(get_running_nodes | wc -l | tr -d '[:space:]')
if [[ "$NODE_COUNT" -le 6 ]]; then
  echo "ERROR: Cannot scale below 6 nodes (3 masters + 3 replicas)."
  echo "Current node count: $NODE_COUNT"
  exit 1
fi

# Find the last two nodes (highest numbered pair)
HIGHEST=$(get_highest_node_number)
REPLICA_NUM=$HIGHEST
MASTER_NUM=$((HIGHEST - 1))

MASTER_NAME="redis-node-$MASTER_NUM"
REPLICA_NAME="redis-node-$REPLICA_NUM"

echo "Removing nodes: $MASTER_NAME + $REPLICA_NAME"
echo ""

# Get node IDs
MASTER_ID=$(get_node_id "$MASTER_NAME")
REPLICA_ID=$(get_node_id "$REPLICA_NAME")

if [[ -z "$MASTER_ID" || -z "$REPLICA_ID" ]]; then
  echo "ERROR: Could not determine node IDs."
  echo "  $MASTER_NAME ID: $MASTER_ID"
  echo "  $REPLICA_NAME ID: $REPLICA_ID"
  exit 1
fi

# Verify the master actually is a master by checking cluster nodes
MASTER_FLAGS=$(redis_exec redis-node-1 cluster nodes | grep "$MASTER_ID" | awk '{print $3}')
REPLICA_FLAGS=$(redis_exec redis-node-1 cluster nodes | grep "$REPLICA_ID" | awk '{print $3}')

# If the "master" is actually a replica and vice versa, swap them
if echo "$MASTER_FLAGS" | grep -q "slave" && echo "$REPLICA_FLAGS" | grep -q "master"; then
  echo "Note: Roles are swapped from expected. Adjusting..."
  TEMP_ID=$MASTER_ID; MASTER_ID=$REPLICA_ID; REPLICA_ID=$TEMP_ID
  TEMP_NAME=$MASTER_NAME; MASTER_NAME=$REPLICA_NAME; REPLICA_NAME=$TEMP_NAME
fi

# Reshard: drain all slots from departing master
echo "Draining hash slots from $MASTER_NAME..."
docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD:-}" redis-node-1 \
  redis-cli $(redis_cluster_auth) --cluster rebalance \
  redis-node-1:6379 --cluster-weight "$MASTER_ID"=0 --cluster-yes || true

# Wait for resharding to complete
sleep 3

# Verify master has 0 slots
REMAINING_SLOTS=$(redis_exec redis-node-1 cluster nodes \
  | grep "$MASTER_ID" | awk '{for(i=9;i<=NF;i++) print $i}' | wc -l | tr -d '[:space:]')

if [[ "$REMAINING_SLOTS" -gt 0 ]]; then
  echo "WARNING: Master still has $REMAINING_SLOTS slot ranges. Retrying rebalance..."
  docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD:-}" redis-node-1 \
    redis-cli $(redis_cluster_auth) --cluster rebalance \
    redis-node-1:6379 --cluster-weight "$MASTER_ID"=0 --cluster-yes || true
  sleep 3
fi

# Remove replica first
echo "Removing replica $REPLICA_NAME ($REPLICA_ID) from cluster..."
docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD:-}" redis-node-1 \
  redis-cli $(redis_cluster_auth) --cluster del-node \
  redis-node-1:6379 "$REPLICA_ID"

sleep 1

# Remove master
echo "Removing master $MASTER_NAME ($MASTER_ID) from cluster..."
docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD:-}" redis-node-1 \
  redis-cli $(redis_cluster_auth) --cluster del-node \
  redis-node-1:6379 "$MASTER_ID"

# Stop and remove containers
echo "Stopping containers..."
compose stop "redis-node-$MASTER_NUM" "redis-node-$REPLICA_NUM" 2>/dev/null || true
compose rm -f "redis-node-$MASTER_NUM" "redis-node-$REPLICA_NUM" 2>/dev/null || true

# Update override file: remove the service definitions for removed nodes
if [[ -f "$OVERRIDE" ]]; then
  # Remove service blocks for both nodes
  for NUM in $MASTER_NUM $REPLICA_NUM; do
    # Use awk to remove the service block
    awk -v name="redis-node-$NUM:" '
      $0 ~ "^  " name { skip=1; next }
      skip && /^  [a-z]/ { skip=0 }
      skip && /^[a-z]/ { skip=0 }
      !skip { print }
    ' "$OVERRIDE" > "$OVERRIDE.tmp" && mv "$OVERRIDE.tmp" "$OVERRIDE"

    # Remove volume entries
    sed -i.bak "/redis-data-$NUM:/d" "$OVERRIDE"
    rm -f "$OVERRIDE.bak"
  done

  # Remove override file if it's effectively empty
  SERVICE_COUNT=$(grep -c "container_name:" "$OVERRIDE" 2>/dev/null || echo "0")
  if [[ "$SERVICE_COUNT" -eq 0 ]]; then
    rm -f "$OVERRIDE"
    echo "Override file removed (no scaled nodes remain)."
  fi
fi

echo ""
echo "Scale-down complete."
redis_exec redis-node-1 cluster info | grep -E "cluster_state|cluster_slots|cluster_known_nodes|cluster_size"
echo ""
redis_exec redis-node-1 cluster nodes | awk '{
  id=substr($1,1,8); addr=$2; flags=$3;
  slots=""; for(i=9;i<=NF;i++) slots=slots" "$i;
  printf "  %-10s %-25s %-20s %s\n", id, addr, flags, slots
}'

# Update HAProxy to remove old nodes
if is_haproxy_enabled; then
  echo ""
  echo "Updating HAProxy configuration..."
  generate_haproxy_config
  reload_haproxy
fi
