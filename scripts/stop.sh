#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

CLEAN=false
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=true ;;
  esac
done

if $CLEAN; then
  print_header "Stopping Redis HA Cluster (CLEAN)"
  echo "WARNING: This will delete all data volumes!"
  read -r -p "Are you sure? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
  compose down -v
  # Remove override file on clean stop
  rm -f "$PROJECT_DIR/docker-compose.override.yml"
  echo "Cluster stopped and all data removed."
else
  print_header "Stopping Redis HA Cluster"
  compose down
  echo "Cluster stopped. Data volumes preserved."
fi
