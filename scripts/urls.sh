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
# Try public IP first (for cloud VMs), then private, then fallback
PUBLIC_IP=$(curl -sf --max-time 2 ifconfig.me 2>/dev/null || true)
PRIVATE_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
if [[ -z "$PRIVATE_IP" ]]; then
  PRIVATE_IP=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' || true)
fi

# Get running nodes
RUNNING=$(get_running_nodes)
if [[ -z "$RUNNING" ]]; then
  echo "Cluster is not running."
  exit 0
fi

# ─── Internal URLs (Docker network) ──────────────────────

echo "--- Internal URLs (inside Docker network) ---"
echo ""
echo "  Use these from other containers on redis-cluster-net."
echo ""
for node in $RUNNING; do
  echo "  redis://${AUTH}${node}:6379"
done
if is_haproxy_enabled; then
  echo ""
  echo "  Load Balancer (write):  redis://${AUTH}redis-haproxy:6380"
  echo "  Load Balancer (read):   redis://${AUTH}redis-haproxy:6381"
fi
echo ""

# ─── Localhost URLs ──────────────────────────────────────

echo "--- Localhost URLs ---"
echo ""
for node in $RUNNING; do
  NUM=$(echo "$node" | sed 's/redis-node-//')
  PORT=$((7000 + NUM))
  echo "  redis://${AUTH}localhost:${PORT}"
done
if is_haproxy_enabled; then
  WRITE_PORT="${HAPROXY_WRITE_PORT:-6380}"
  READ_PORT="${HAPROXY_READ_PORT:-6381}"
  echo ""
  echo "  Load Balancer (write):  redis://${AUTH}localhost:${WRITE_PORT}"
  echo "  Load Balancer (read):   redis://${AUTH}localhost:${READ_PORT}"
  echo "  Stats dashboard:        http://localhost:${HAPROXY_STATS_PORT:-8404}/stats"
fi
echo ""

# ─── Public URLs (external access) ───────────────────────

echo "--- Public / External URLs ---"
echo ""

if [[ -n "$PUBLIC_IP" ]]; then
  echo "  Public IP: $PUBLIC_IP"
elif [[ -n "$PRIVATE_IP" ]]; then
  echo "  Private IP: $PRIVATE_IP (no public IP detected)"
else
  echo "  Could not detect host IP. Set ANNOUNCE_IP in .env."
fi
echo ""

DISPLAY_IP="${PUBLIC_IP:-${PRIVATE_IP:-<server-ip>}}"

if is_haproxy_enabled; then
  WRITE_PORT="${HAPROXY_WRITE_PORT:-6380}"
  READ_PORT="${HAPROXY_READ_PORT:-6381}"
  echo "  Load Balancer (write):  redis://${AUTH}${DISPLAY_IP}:${WRITE_PORT}"
  echo "  Load Balancer (read):   redis://${AUTH}${DISPLAY_IP}:${READ_PORT}"
  echo "  Stats dashboard:        http://${DISPLAY_IP}:${HAPROXY_STATS_PORT:-8404}/stats"
  echo ""
fi

echo "  Direct nodes:"
for node in $RUNNING; do
  NUM=$(echo "$node" | sed 's/redis-node-//')
  PORT=$((7000 + NUM))
  echo "    redis://${AUTH}${DISPLAY_IP}:${PORT}"
done
echo ""

echo "  NOTE: Direct node access from external clients may fail due to"
echo "  Redis Cluster MOVED redirections pointing to internal Docker IPs."
echo "  Use the HAProxy load balancer endpoints for external access."
echo ""

# ─── Quick copy ──────────────────────────────────────────

echo "--- Recommended ---"
echo ""
if is_haproxy_enabled; then
  WRITE_PORT="${HAPROXY_WRITE_PORT:-6380}"
  READ_PORT="${HAPROXY_READ_PORT:-6381}"
  echo "  From same machine:"
  echo "    Write: redis://${AUTH}localhost:${WRITE_PORT}"
  echo "    Read:  redis://${AUTH}localhost:${READ_PORT}"
  if [[ -n "$DISPLAY_IP" && "$DISPLAY_IP" != "<server-ip>" ]]; then
    echo ""
    echo "  From external clients:"
    echo "    Write: redis://${AUTH}${DISPLAY_IP}:${WRITE_PORT}"
    echo "    Read:  redis://${AUTH}${DISPLAY_IP}:${READ_PORT}"
  fi
else
  echo "  redis://${AUTH}localhost:7001"
fi
echo ""

# ─── Firewall reminder ──────────────────────────────────

echo "--- Firewall ---"
echo ""
echo "  Ensure these ports are open for external access:"
PORTS="7001-$((7000 + $(echo "$RUNNING" | wc -l | tr -d '[:space:]')))"
echo "    Redis nodes:    $PORTS/tcp"
if is_haproxy_enabled; then
  echo "    HAProxy write:  ${HAPROXY_WRITE_PORT:-6380}/tcp"
  echo "    HAProxy read:   ${HAPROXY_READ_PORT:-6381}/tcp"
  echo "    HAProxy stats:  ${HAPROXY_STATS_PORT:-8404}/tcp"
fi
echo ""
echo "  Example (ufw):  sudo ufw allow ${HAPROXY_WRITE_PORT:-6380}/tcp"
echo "  Example (firewalld): sudo firewall-cmd --add-port=${HAPROXY_WRITE_PORT:-6380}/tcp"
echo ""
