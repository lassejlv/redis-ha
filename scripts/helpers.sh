#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Auto-detect docker compose command
if docker compose version &>/dev/null; then
  COMPOSE_CMD="docker compose"
else
  COMPOSE_CMD="docker-compose"
fi

compose() {
  $COMPOSE_CMD -f "$PROJECT_DIR/docker-compose.yml" \
    ${OVERRIDE_FILE:+-f "$OVERRIDE_FILE"} \
    "$@"
}

# Set override file path if it exists
OVERRIDE_FILE=""
if [[ -f "$PROJECT_DIR/docker-compose.override.yml" ]]; then
  OVERRIDE_FILE="$PROJECT_DIR/docker-compose.override.yml"
fi

wait_for_nodes() {
  local nodes=("$@")
  local timeout=30
  local elapsed=0

  echo "Waiting for nodes to be ready..."
  for node in "${nodes[@]}"; do
    while ! docker exec "$node" redis-cli ping &>/dev/null; do
      sleep 1
      elapsed=$((elapsed + 1))
      if [[ $elapsed -ge $timeout ]]; then
        echo "ERROR: Timed out waiting for $node after ${timeout}s"
        return 1
      fi
    done
  done
  echo "All nodes ready."
}

cluster_is_initialized() {
  local info
  info=$(docker exec redis-node-1 redis-cli cluster info 2>/dev/null) || return 1
  local state known_nodes
  state=$(echo "$info" | grep "cluster_state" | tr -d '[:space:]')
  known_nodes=$(echo "$info" | grep "cluster_known_nodes" | cut -d: -f2 | tr -d '[:space:]')

  [[ "$state" == "cluster_state:ok" ]] && [[ "$known_nodes" -gt 1 ]] 2>/dev/null
}

get_node_id() {
  local container="$1"
  docker exec "$container" redis-cli cluster myid 2>/dev/null | tr -d '[:space:]'
}

get_running_nodes() {
  docker ps --filter "name=redis-node-" --format "{{.Names}}" | sort -t- -k3 -n
}

get_highest_node_number() {
  get_running_nodes | sed 's/redis-node-//' | sort -n | tail -1
}

get_master_count() {
  docker exec redis-node-1 redis-cli cluster nodes 2>/dev/null \
    | grep "master" | grep -v "fail" | wc -l | tr -d '[:space:]'
}

print_header() {
  echo ""
  echo "========================================="
  echo "  $1"
  echo "========================================="
  echo ""
}
