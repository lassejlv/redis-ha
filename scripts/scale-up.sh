#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_header "Scaling Up Redis Cluster"

# Determine next node numbers
HIGHEST=$(get_highest_node_number)
MASTER_NUM=$((HIGHEST + 1))
REPLICA_NUM=$((HIGHEST + 2))
MASTER_PORT=$((7000 + MASTER_NUM))
REPLICA_PORT=$((7000 + REPLICA_NUM))

MASTER_NAME="redis-node-$MASTER_NUM"
REPLICA_NAME="redis-node-$REPLICA_NUM"

echo "Adding nodes: $MASTER_NAME (master) + $REPLICA_NAME (replica)"
echo "Host ports: $MASTER_PORT, $REPLICA_PORT"
echo ""

# Generate or update docker-compose.override.yml
OVERRIDE="$PROJECT_DIR/docker-compose.override.yml"

if [[ ! -f "$OVERRIDE" ]]; then
  cat > "$OVERRIDE" <<HEADER
services:

HEADER
fi

# Check if these nodes already exist in override
if grep -q "$MASTER_NAME:" "$OVERRIDE" 2>/dev/null; then
  echo "ERROR: $MASTER_NAME already defined in override file."
  exit 1
fi

# Append new services
cat >> "$OVERRIDE" <<EOF
  $MASTER_NAME:
    image: redis:\${REDIS_VERSION:-7.4}
    command: redis-server /usr/local/etc/redis/redis.conf
    container_name: $MASTER_NAME
    ports:
      - "$MASTER_PORT:6379"
    volumes:
      - redis-data-$MASTER_NUM:/data
      - ./redis.conf:/usr/local/etc/redis/redis.conf:ro
    networks:
      - redis-cluster-net
    healthcheck:
      test: ["CMD", "redis-cli", "-p", "6379", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    restart: unless-stopped

  $REPLICA_NAME:
    image: redis:\${REDIS_VERSION:-7.4}
    command: redis-server /usr/local/etc/redis/redis.conf
    container_name: $REPLICA_NAME
    ports:
      - "$REPLICA_PORT:6379"
    volumes:
      - redis-data-$REPLICA_NUM:/data
      - ./redis.conf:/usr/local/etc/redis/redis.conf:ro
    networks:
      - redis-cluster-net
    healthcheck:
      test: ["CMD", "redis-cli", "-p", "6379", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    restart: unless-stopped

EOF

# Append volumes if not already present
if ! grep -q "^volumes:" "$OVERRIDE" 2>/dev/null; then
  cat >> "$OVERRIDE" <<EOF
volumes:
  redis-data-$MASTER_NUM:
  redis-data-$REPLICA_NUM:

networks:
  redis-cluster-net:
    external: false
EOF
else
  # Insert new volumes before the networks section
  sed -i.bak "/^volumes:/a\\
  redis-data-$MASTER_NUM:\\
  redis-data-$REPLICA_NUM:" "$OVERRIDE"
  rm -f "$OVERRIDE.bak"
fi

# Update OVERRIDE_FILE so compose() picks it up
OVERRIDE_FILE="$OVERRIDE"

# Start only the new containers
compose up -d "$MASTER_NAME" "$REPLICA_NAME"

wait_for_nodes "$MASTER_NAME" "$REPLICA_NAME"

# Add master to cluster
echo "Adding $MASTER_NAME as master..."
docker exec redis-node-1 redis-cli --cluster add-node \
  "$MASTER_NAME:6379" redis-node-1:6379

# Wait for node to be recognized
sleep 2

# Add replica linked to the new master
MASTER_ID=$(get_node_id "$MASTER_NAME")
echo "Adding $REPLICA_NAME as replica of $MASTER_NAME ($MASTER_ID)..."
docker exec redis-node-1 redis-cli --cluster add-node \
  "$REPLICA_NAME:6379" redis-node-1:6379 \
  --cluster-slave --cluster-master-id "$MASTER_ID"

sleep 2

# Rebalance slots across all masters
echo ""
echo "Rebalancing hash slots across all masters..."
docker exec redis-node-1 redis-cli --cluster rebalance \
  redis-node-1:6379 --cluster-use-empty-masters --cluster-yes || true

echo ""
echo "Scale-up complete."
docker exec redis-node-1 redis-cli cluster info | grep -E "cluster_state|cluster_slots|cluster_known_nodes|cluster_size"
echo ""
docker exec redis-node-1 redis-cli cluster nodes | awk '{
  id=substr($1,1,8); addr=$2; flags=$3;
  slots=""; for(i=9;i<=NF;i++) slots=slots" "$i;
  printf "  %-10s %-25s %-20s %s\n", id, addr, flags, slots
}'

# Update HAProxy to include new nodes
if is_haproxy_enabled; then
  echo ""
  echo "Updating HAProxy configuration..."
  generate_haproxy_config
  reload_haproxy
fi
