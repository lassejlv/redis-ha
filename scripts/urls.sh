#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_header "Redis Connection URLs"

# Build auth portion of URL
AUTH=""
if [[ -n "${REDIS_PASSWORD:-}" ]]; then
  AUTH=":${REDIS_PASSWORD}@"
fi

# Detect host IP for public URLs
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
if [[ -z "$HOST_IP" ]]; then
  HOST_IP=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' || true)
fi
if [[ -z "$HOST_IP" ]]; then
  HOST_IP="<server-ip>"
fi

# Get running nodes
RUNNING=$(get_running_nodes)
if [[ -z "$RUNNING" ]]; then
  echo "Cluster is not running."
  exit 0
fi

HIGHEST=$(get_highest_node_number)

# ─── Internal URLs (Docker network) ──────────────────────

echo "--- Internal URLs (inside Docker network) ---"
echo ""
echo "  Use these from other containers on redis-cluster-net."
echo ""
for node in $RUNNING; do
  NUM=$(echo "$node" | sed 's/redis-node-//')
  echo "  redis://${AUTH}${node}:6379"
done
echo ""

if is_haproxy_enabled; then
  echo "  Load Balancer (write):  redis://${AUTH}redis-haproxy:6380"
  echo "  Load Balancer (read):   redis://${AUTH}redis-haproxy:6381"
  echo ""
fi

# ─── Public URLs (host access) ───────────────────────────

echo "--- Public URLs (host / external access) ---"
echo ""
echo "  Use these from the host machine or external clients."
echo ""

for node in $RUNNING; do
  NUM=$(echo "$node" | sed 's/redis-node-//')
  PORT=$((7000 + NUM))
  echo "  redis://${AUTH}${HOST_IP}:${PORT}"
done
echo ""

if is_haproxy_enabled; then
  WRITE_PORT="${HAPROXY_WRITE_PORT:-6380}"
  READ_PORT="${HAPROXY_READ_PORT:-6381}"
  echo "  Load Balancer (write):  redis://${AUTH}${HOST_IP}:${WRITE_PORT}"
  echo "  Load Balancer (read):   redis://${AUTH}${HOST_IP}:${READ_PORT}"
  echo "  Stats dashboard:        http://${HOST_IP}:${HAPROXY_STATS_PORT:-8404}/stats"
  echo ""
fi

# ─── Localhost URLs ──────────────────────────────────────

echo "--- Localhost URLs ---"
echo ""
for node in $RUNNING; do
  NUM=$(echo "$node" | sed 's/redis-node-//')
  PORT=$((7000 + NUM))
  echo "  redis://${AUTH}localhost:${PORT}"
done
echo ""

if is_haproxy_enabled; then
  WRITE_PORT="${HAPROXY_WRITE_PORT:-6380}"
  READ_PORT="${HAPROXY_READ_PORT:-6381}"
  echo "  Load Balancer (write):  redis://${AUTH}localhost:${WRITE_PORT}"
  echo "  Load Balancer (read):   redis://${AUTH}localhost:${READ_PORT}"
  echo ""
fi

# ─── Quick copy ──────────────────────────────────────────

echo "--- Quick Copy ---"
echo ""
if is_haproxy_enabled; then
  WRITE_PORT="${HAPROXY_WRITE_PORT:-6380}"
  READ_PORT="${HAPROXY_READ_PORT:-6381}"
  echo "  Recommended (write): redis://${AUTH}localhost:${WRITE_PORT}"
  echo "  Recommended (read):  redis://${AUTH}localhost:${READ_PORT}"
else
  echo "  Primary node: redis://${AUTH}localhost:7001"
fi
echo ""
