#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_header "Starting Redis HA Cluster"

# Start all containers
compose up -d

# Collect node names from running containers
NODES=()
for i in $(seq 1 6); do
  NODES+=("redis-node-$i")
done

# Include scaled nodes if override exists
if [[ -n "$OVERRIDE_FILE" ]]; then
  highest=$(get_highest_node_number)
  for i in $(seq 7 "$highest"); do
    if docker ps --format "{{.Names}}" | grep -q "redis-node-$i"; then
      NODES+=("redis-node-$i")
    fi
  done
fi

wait_for_nodes "${NODES[@]}"

# Initialize cluster if needed
if cluster_is_initialized; then
  echo "Cluster already initialized. Nodes rejoining from persisted state."
else
  echo "Initializing new cluster..."

  NODE_ADDRS=""
  for i in $(seq 1 6); do
    NODE_ADDRS="$NODE_ADDRS redis-node-$i:6379"
  done

  # Retry up to 3 times
  for attempt in 1 2 3; do
    if docker exec redis-node-1 redis-cli --cluster create \
      $NODE_ADDRS \
      --cluster-replicas 1 --cluster-yes; then
      echo "Cluster initialized successfully."
      break
    else
      if [[ $attempt -lt 3 ]]; then
        echo "Attempt $attempt failed, retrying in 5s..."
        sleep 5
      else
        echo "ERROR: Cluster initialization failed after 3 attempts."
        exit 1
      fi
    fi
  done
fi

echo ""
echo "Cluster is running. Verifying..."
echo ""
docker exec redis-node-1 redis-cli cluster info | grep -E "cluster_state|cluster_slots|cluster_known_nodes|cluster_size"
echo ""
echo "Nodes:"
docker exec redis-node-1 redis-cli cluster nodes | awk '{
  id=substr($1,1,8); addr=$2; flags=$3; master=$4; slots="";
  for(i=9;i<=NF;i++) slots=slots" "$i;
  printf "  %-10s %-25s %-20s %s\n", id, addr, flags, slots
}'
echo ""
echo "Host access: redis-cli -p 7001 -c"
