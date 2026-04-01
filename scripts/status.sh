#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

print_header "Redis HA Cluster Status"

# Check if any nodes are running
RUNNING=$(get_running_nodes)
if [[ -z "$RUNNING" ]]; then
  echo "Cluster is not running."
  exit 0
fi

echo "--- Cluster Info ---"
docker exec redis-node-1 redis-cli cluster info 2>/dev/null \
  | grep -E "cluster_state|cluster_slots|cluster_known_nodes|cluster_size" \
  | sed 's/\r//'
echo ""

echo "--- Cluster Nodes ---"
printf "  %-10s %-25s %-18s %-12s %s\n" "ID" "ADDRESS" "ROLE" "STATUS" "SLOTS"
echo "  $(printf '%.0s-' {1..85})"
docker exec redis-node-1 redis-cli cluster nodes 2>/dev/null | sort -t: -k2 -n | while IFS= read -r line; do
  id=$(echo "$line" | awk '{print substr($1,1,8)}')
  addr=$(echo "$line" | awk '{print $2}' | cut -d@ -f1)
  flags=$(echo "$line" | awk '{print $3}' | sed 's/myself,//')
  link=$(echo "$line" | awk '{print $8}')
  slots=$(echo "$line" | awk '{for(i=9;i<=NF;i++) printf "%s ",$i}')

  if echo "$flags" | grep -q "master"; then
    role="master"
  else
    role="replica"
  fi

  if [[ "$link" == "connected" ]]; then
    status="ok"
  else
    status="$link"
  fi

  printf "  %-10s %-25s %-18s %-12s %s\n" "$id" "$addr" "$role" "$status" "$slots"
done
echo ""

echo "--- Container Status ---"
compose ps
echo ""

echo "--- Memory Usage ---"
for node in $RUNNING; do
  mem=$(docker exec "$node" redis-cli info memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '[:space:]')
  printf "  %-20s %s\n" "$node" "$mem"
done
echo ""
