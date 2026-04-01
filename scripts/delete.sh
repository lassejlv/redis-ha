#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_header "Delete Redis HA Cluster"

echo "This will completely remove the Redis HA cluster from your system."
echo ""
echo "  What will be removed:"
echo "    - All Redis containers"
echo "    - All data volumes (ALL DATA WILL BE LOST)"
echo "    - HAProxy container"
echo "    - Monitor container"
echo "    - Docker images (redis, haproxy, monitor)"
echo "    - Generated config files"
echo ""
echo -e "\033[1;31m  WARNING: This action is irreversible!\033[0m"
echo ""

read -rp "  Type 'delete' to confirm: " CONFIRM < /dev/tty
if [[ "$CONFIRM" != "delete" ]]; then
  echo ""
  echo "Aborted."
  exit 0
fi

echo ""

# Stop and remove all containers + volumes
echo "Stopping all containers and removing volumes..."
compose down -v 2>/dev/null || true

# Remove orphan containers that might not be in compose
for container in $(docker ps -a --filter "name=redis-node-" --filter "name=redis-haproxy" --filter "name=redis-monitor" --format "{{.Names}}" 2>/dev/null); do
  echo "  Removing container: $container"
  docker rm -f "$container" 2>/dev/null || true
done

# Remove dangling volumes
echo "Removing volumes..."
for vol in $(docker volume ls --filter "name=redis-data-" --format "{{.Name}}" 2>/dev/null); do
  echo "  Removing volume: $vol"
  docker volume rm "$vol" 2>/dev/null || true
done

# Remove Docker images
echo "Removing Docker images..."
docker rmi redis:"${REDIS_VERSION:-7.4}" 2>/dev/null && echo "  Removed redis:${REDIS_VERSION:-7.4}" || true
docker rmi haproxy:lts-alpine 2>/dev/null && echo "  Removed haproxy:lts-alpine" || true
docker rmi redis-ha-monitor 2>/dev/null && echo "  Removed redis-ha-monitor" || true
# Also try the compose-built image name
docker rmi "$(basename "$PROJECT_DIR")-monitor" 2>/dev/null || true

# Remove generated files
echo "Removing generated config files..."
rm -f "$PROJECT_DIR/.env"
rm -f "$PROJECT_DIR/redis.conf"
rm -f "$PROJECT_DIR/haproxy/haproxy.cfg"
rm -f "$PROJECT_DIR/docker-compose.override.yml"
rm -f "$PROJECT_DIR/multi-server/servers.conf"
rm -f "$PROJECT_DIR"/docker-compose.server-*.yml

echo ""

# Remove Docker network if orphaned
docker network rm redis-cluster-net 2>/dev/null && echo "Removed Docker network." || true

echo ""
echo "Cluster removed."
echo ""

read -rp "  Also delete the project directory ($PROJECT_DIR)? [y/N]: " DELETE_DIR < /dev/tty
if [[ "$DELETE_DIR" =~ ^[Yy]$ ]]; then
  echo "Deleting project directory..."
  rm -rf "$PROJECT_DIR"
  echo "Done. Project directory removed."
else
  echo "Project files kept. Run ./setup.sh to reconfigure."
fi
echo ""
