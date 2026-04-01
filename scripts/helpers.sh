#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env if present
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a
  source "$PROJECT_DIR/.env"
  set +a
fi

# Export for host-level redis-cli calls (e.g. multi-server-init.sh)
export REDISCLI_AUTH="${REDIS_PASSWORD:-}"

# Auto-detect docker compose command
if docker compose version &>/dev/null; then
  COMPOSE_CMD="docker compose"
else
  COMPOSE_CMD="docker-compose"
fi

# Set override file path if it exists
OVERRIDE_FILE=""
if [[ -f "$PROJECT_DIR/docker-compose.override.yml" ]]; then
  OVERRIDE_FILE="$PROJECT_DIR/docker-compose.override.yml"
fi

is_haproxy_enabled() {
  [[ -f "$PROJECT_DIR/docker-compose.lb.yml" ]]
}

compose() {
  local lb_flag=""
  if is_haproxy_enabled; then
    lb_flag="-f $PROJECT_DIR/docker-compose.lb.yml"
  fi
  $COMPOSE_CMD -f "$PROJECT_DIR/docker-compose.yml" \
    ${OVERRIDE_FILE:+-f "$OVERRIDE_FILE"} \
    $lb_flag \
    "$@"
}

# Execute redis-cli inside a container with auth if configured.
# Usage: redis_exec <container> [redis-cli args...]
redis_exec() {
  local container="$1"
  shift
  local auth_env=()
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    auth_env=(-e "REDISCLI_AUTH=$REDIS_PASSWORD")
  fi
  docker exec "${auth_env[@]}" "$container" redis-cli "$@"
}

# Returns auth flags for redis-cli --cluster commands.
# These commands need explicit -a flag in addition to REDISCLI_AUTH.
redis_cluster_auth() {
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    echo "-a $REDIS_PASSWORD"
  fi
}

# Generate haproxy/haproxy.cfg from template.
# Accepts optional node list; if empty, builds from base 6 + override.
generate_haproxy_config() {
  local template="$PROJECT_DIR/haproxy/haproxy.cfg.template"
  local output="$PROJECT_DIR/haproxy/haproxy.cfg"
  local nodes=("$@")

  if [[ ! -f "$template" ]]; then
    echo "WARNING: HAProxy template not found at $template"
    return 1
  fi

  # Build node list if not provided
  if [[ ${#nodes[@]} -eq 0 ]]; then
    for i in $(seq 1 6); do
      nodes+=("redis-node-$i")
    done
    # Add scaled nodes from override
    if [[ -n "$OVERRIDE_FILE" ]] && [[ -f "$OVERRIDE_FILE" ]]; then
      local scaled
      scaled=$(grep "container_name:" "$OVERRIDE_FILE" 2>/dev/null | awk '{print $2}' || true)
      for node in $scaled; do
        nodes+=("$node")
      done
    fi
  fi

  # Build server lines
  local server_lines=""
  for node in "${nodes[@]}"; do
    server_lines="${server_lines}    server ${node} ${node}:6379 check inter 2s fall 3 rise 2"$'\n'
  done

  # Build auth line for HAProxy tcp-check
  local auth_line=""
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    auth_line="    tcp-check send \"AUTH ${REDIS_PASSWORD}\r\n\""$'\n'"    tcp-check expect string +OK"
  fi

  # Replace placeholders in template
  local config
  config=$(cat "$template")
  config="${config/# AUTH_LINE/$auth_line}"
  config="${config/# AUTH_LINE/$auth_line}"
  config="${config/# SERVER_LIST_MASTERS/$server_lines}"
  config="${config/# SERVER_LIST_REPLICAS/$server_lines}"

  echo "$config" > "$output"
  echo "HAProxy config generated at $output"
}

reload_haproxy() {
  if docker ps --format "{{.Names}}" | grep -q "redis-haproxy"; then
    docker kill -s HUP redis-haproxy >/dev/null 2>&1
    echo "HAProxy reloaded."
  fi
}

wait_for_nodes() {
  local nodes=("$@")
  local timeout=30
  local elapsed=0

  echo "Waiting for nodes to be ready..."
  for node in "${nodes[@]}"; do
    while ! redis_exec "$node" ping &>/dev/null; do
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
  info=$(redis_exec redis-node-1 cluster info 2>/dev/null) || return 1
  local state known_nodes
  state=$(echo "$info" | grep "cluster_state" | tr -d '[:space:]')
  known_nodes=$(echo "$info" | grep "cluster_known_nodes" | cut -d: -f2 | tr -d '[:space:]')

  [[ "$state" == "cluster_state:ok" ]] && [[ "$known_nodes" -gt 1 ]] 2>/dev/null
}

get_node_id() {
  local container="$1"
  redis_exec "$container" cluster myid 2>/dev/null | tr -d '[:space:]'
}

get_running_nodes() {
  docker ps --filter "name=redis-node-" --format "{{.Names}}" | sort -t- -k3 -n
}

get_highest_node_number() {
  get_running_nodes | sed 's/redis-node-//' | sort -n | tail -1
}

get_master_count() {
  redis_exec redis-node-1 cluster nodes 2>/dev/null \
    | grep "master" | grep -v "fail" | wc -l | tr -d '[:space:]'
}

is_multi_server() {
  [[ "${MULTI_SERVER:-false}" == "true" ]]
}

get_announce_ip() {
  echo "${ANNOUNCE_IP:-}"
}

print_header() {
  echo ""
  echo "========================================="
  echo "  $1"
  echo "========================================="
  echo ""
}
