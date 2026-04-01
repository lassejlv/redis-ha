#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

usage() {
  echo "Usage: $0 <server-ip> <node-numbers> [base-port]"
  echo ""
  echo "Generate a Docker Compose file for a specific server in a multi-server cluster."
  echo ""
  echo "Arguments:"
  echo "  server-ip      External IP of this server (e.g. 192.168.1.10)"
  echo "  node-numbers   Comma-separated node numbers to run (e.g. 1,4)"
  echo "  base-port      Base client port (default: 7000, so node 1 = 7001)"
  echo ""
  echo "Example:"
  echo "  $0 192.168.1.10 1,4"
  echo "  $0 192.168.1.11 2,5"
  echo "  $0 192.168.1.12 3,6"
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

SERVER_IP="$1"
NODE_NUMS="$2"
BASE_PORT="${3:-7000}"

OUTPUT="$PROJECT_DIR/docker-compose.server-${SERVER_IP}.yml"

IFS=',' read -ra NODES <<< "$NODE_NUMS"

print_header "Generating Compose for $SERVER_IP"
echo "Nodes: ${NODES[*]}"
echo "Output: $OUTPUT"
echo ""

# Start building the compose file
cat > "$OUTPUT" <<'HEADER'
x-redis-node: &redis-node
  image: redis:${REDIS_VERSION:-7.4}
  networks:
    - redis-cluster-net
  healthcheck:
    test: ["CMD", "redis-cli", "-p", "6379", "ping"]
    interval: 5s
    timeout: 3s
    retries: 5
    start_period: 10s
  restart: unless-stopped

services:
HEADER

VOLUME_LINES=""

for NUM in "${NODES[@]}"; do
  CLIENT_PORT=$((BASE_PORT + NUM))
  BUS_PORT=$((CLIENT_PORT + 10000))

  cat >> "$OUTPUT" <<EOF
  redis-node-${NUM}:
    <<: *redis-node
    container_name: redis-node-${NUM}
    command: >
      redis-server /usr/local/etc/redis/redis.conf
      --cluster-announce-ip ${SERVER_IP}
      --cluster-announce-port ${CLIENT_PORT}
      --cluster-announce-bus-port ${BUS_PORT}
    ports:
      - "${CLIENT_PORT}:6379"
      - "${BUS_PORT}:16379"
    volumes:
      - redis-data-${NUM}:/data
      - ./redis.conf:/usr/local/etc/redis/redis.conf:ro

EOF

  VOLUME_LINES="${VOLUME_LINES}  redis-data-${NUM}:\n"
done

# Write volumes and network
cat >> "$OUTPUT" <<EOF
volumes:
$(echo -e "$VOLUME_LINES")
networks:
  redis-cluster-net:
    driver: bridge
EOF

echo "Generated: $OUTPUT"
echo ""
echo "Next steps:"
echo "  1. Copy this project to $SERVER_IP"
echo "  2. Run: docker compose -f docker-compose.server-${SERVER_IP}.yml up -d"
echo "  3. After all servers are running, initialize the cluster with:"
echo "     ./scripts/multi-server-init.sh"
