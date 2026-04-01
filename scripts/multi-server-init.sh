#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

CONF="${1:-$PROJECT_DIR/multi-server/servers.conf}"

if [[ ! -f "$CONF" ]]; then
  echo "ERROR: Server config not found: $CONF"
  echo ""
  echo "Usage: $0 [servers.conf]"
  echo ""
  echo "Create a servers.conf file (see multi-server/servers.conf.example)."
  echo "Format: <server-ip>  <node-numbers>"
  echo ""
  echo "Example:"
  echo "  192.168.1.10  1,4"
  echo "  192.168.1.11  2,5"
  echo "  192.168.1.12  3,6"
  exit 1
fi

print_header "Multi-Server Cluster Initialization"

BASE_PORT="${BASE_PORT:-7000}"
NODE_ADDRS=""
ALL_NODES=()

# Parse config and build node address list
while IFS= read -r line; do
  # Skip comments and empty lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// /}" ]] && continue

  SERVER_IP=$(echo "$line" | awk '{print $1}')
  NODE_NUMS=$(echo "$line" | awk '{print $2}')

  IFS=',' read -ra NUMS <<< "$NODE_NUMS"
  for NUM in "${NUMS[@]}"; do
    PORT=$((BASE_PORT + NUM))
    NODE_ADDRS="$NODE_ADDRS $SERVER_IP:$PORT"
    ALL_NODES+=("$SERVER_IP:$PORT")
  done
done < "$CONF"

echo "Cluster nodes:"
for addr in "${ALL_NODES[@]}"; do
  echo "  $addr"
done
echo ""

# Verify all nodes are reachable
echo "Checking node connectivity..."
FAILED=false
for addr in "${ALL_NODES[@]}"; do
  IP=$(echo "$addr" | cut -d: -f1)
  PORT=$(echo "$addr" | cut -d: -f2)
  if redis-cli -h "$IP" -p "$PORT" ping >/dev/null 2>&1; then
    echo "  $addr - OK"
  else
    echo "  $addr - UNREACHABLE"
    FAILED=true
  fi
done
echo ""

if $FAILED; then
  echo "ERROR: Some nodes are unreachable. Start all nodes first."
  echo ""
  echo "On each server, run:"
  echo "  docker compose -f docker-compose.server-<ip>.yml up -d"
  exit 1
fi

# Check if cluster is already initialized
FIRST_ADDR="${ALL_NODES[0]}"
FIRST_IP=$(echo "$FIRST_ADDR" | cut -d: -f1)
FIRST_PORT=$(echo "$FIRST_ADDR" | cut -d: -f2)

CLUSTER_INFO=$(redis-cli -h "$FIRST_IP" -p "$FIRST_PORT" cluster info 2>/dev/null || true)
KNOWN=$(echo "$CLUSTER_INFO" | grep "cluster_known_nodes" | cut -d: -f2 | tr -d '[:space:]')

if [[ "${KNOWN:-0}" -gt 1 ]]; then
  echo "Cluster already initialized ($KNOWN known nodes). Skipping creation."
  echo ""
  redis-cli -h "$FIRST_IP" -p "$FIRST_PORT" cluster info | grep -E "cluster_state|cluster_slots|cluster_known_nodes|cluster_size"
  exit 0
fi

# Initialize the cluster
echo "Creating cluster..."
redis-cli $(redis_cluster_auth) --cluster create $NODE_ADDRS --cluster-replicas 1 --cluster-yes

echo ""
echo "Cluster initialized."
redis-cli -h "$FIRST_IP" -p "$FIRST_PORT" cluster info | grep -E "cluster_state|cluster_slots|cluster_known_nodes|cluster_size"
echo ""
redis-cli -h "$FIRST_IP" -p "$FIRST_PORT" cluster nodes | awk '{
  id=substr($1,1,8); addr=$2; flags=$3;
  slots=""; for(i=9;i<=NF;i++) slots=slots" "$i;
  printf "  %-10s %-25s %-20s %s\n", id, addr, flags, slots
}'
