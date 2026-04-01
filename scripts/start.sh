#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_header "Starting Redis HA Cluster"

# Collect expected node names
NODES=()
for i in $(seq 1 6); do
  NODES+=("redis-node-$i")
done

# Include scaled nodes if override exists
if [[ -n "$OVERRIDE_FILE" ]] && [[ -f "$OVERRIDE_FILE" ]]; then
  scaled=$(grep "container_name:" "$OVERRIDE_FILE" 2>/dev/null | awk '{print $2}' || true)
  for node in $scaled; do
    NODES+=("$node")
  done
fi

# Generate HAProxy config before starting (HAProxy needs it at boot)
if is_haproxy_enabled; then
  generate_haproxy_config "${NODES[@]}"
fi

# Start all containers
compose up -d

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
    if docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD:-}" redis-node-1 \
      redis-cli $(redis_cluster_auth) --cluster create \
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
redis_exec redis-node-1 cluster info | grep -E "cluster_state|cluster_slots|cluster_known_nodes|cluster_size"
echo ""
echo "Nodes:"
redis_exec redis-node-1 cluster nodes | awk '{
  id=substr($1,1,8); addr=$2; flags=$3; master=$4; slots="";
  for(i=9;i<=NF;i++) slots=slots" "$i;
  printf "  %-10s %-25s %-20s %s\n", id, addr, flags, slots
}'

AUTH=""
if [[ -n "${REDIS_PASSWORD:-}" ]]; then
  AUTH=":${REDIS_PASSWORD}@"
fi

echo ""
echo "Connection URLs:"
if is_haproxy_enabled; then
  WRITE_PORT="${HAPROXY_WRITE_PORT:-6380}"
  READ_PORT="${HAPROXY_READ_PORT:-6381}"
  echo "  Write: redis://${AUTH}localhost:${WRITE_PORT}"
  echo "  Read:  redis://${AUTH}localhost:${READ_PORT}"
  echo "  Stats: http://localhost:${HAPROXY_STATS_PORT:-8404}/stats"
else
  echo "  redis://${AUTH}localhost:7001"
fi
echo ""
echo "Run ./scripts/urls.sh for all internal/public/localhost URLs."
