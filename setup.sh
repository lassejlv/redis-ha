#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Repo URL for standalone installer mode
REPO_URL="https://github.com/lassejlv/redis-ha.git"

# ─── Helpers ──────────────────────────────────────────────

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERR]${NC}  $1"; }

ask() {
  local prompt="$1" default="$2" value
  if [[ -n "$default" ]]; then
    echo -en "${CYAN}  $prompt ${DIM}[$default]${NC}: "
  else
    echo -en "${CYAN}  $prompt${NC}: "
  fi
  read -r value < /dev/tty
  echo "${value:-$default}"
}

ask_password() {
  local prompt="$1" pass1 pass2
  while true; do
    echo -en "${CYAN}  $prompt${NC}: "
    read -rs pass1 < /dev/tty
    echo ""
    if [[ -z "$pass1" ]]; then
      echo ""
      return
    fi
    echo -en "${CYAN}  Confirm password${NC}: "
    read -rs pass2 < /dev/tty
    echo ""
    if [[ "$pass1" == "$pass2" ]]; then
      echo "$pass1"
      return
    fi
    warn "Passwords do not match. Try again."
  done
}

ask_yesno() {
  local prompt="$1" default="$2" value
  echo -en "${CYAN}  $prompt ${DIM}[$default]${NC}: "
  read -r value < /dev/tty
  value="${value:-$default}"
  [[ "$value" =~ ^[Yy] ]]
}

validate_port() {
  local port="$1"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1024 ]] || [[ "$port" -gt 65535 ]]; then
    return 1
  fi
  return 0
}

# ─── Banner ───────────────────────────────────────────────

echo ""
echo -e "${BOLD}${BLUE}"
echo "  ╦═╗┌─┐┌┬┐┬┌─┐  ╦ ╦╔═╗  ╔═╗┬  ┬ ┬┌─┐┌┬┐┌─┐┬─┐"
echo "  ╠╦╝├┤  │││└─┐  ╠═╣╠═╣  ║  │  │ │└─┐ │ ├┤ ├┬┘"
echo "  ╩╚═└─┘─┴┘┴└─┘  ╩ ╩╩ ╩  ╚═╝┴─┘└─┘└─┘ ┴ └─┘┴└─"
echo -e "${NC}"
echo -e "  ${DIM}Interactive setup for Redis HA Cluster with Docker${NC}"
echo ""

# ─── Standalone installer: clone if not in repo ──────────

if [[ ! -f "./docker-compose.yml" ]] && [[ ! -f "./scripts/helpers.sh" ]]; then
  info "Not inside the redis-ha project. Cloning repository..."
  if ! command -v git &>/dev/null; then
    error "git is not installed. Please install git first."
    exit 1
  fi
  git clone "$REPO_URL" redis-ha
  cd redis-ha
  success "Repository cloned."
  echo ""
fi

PROJECT_DIR="$(pwd)"

# ─── Step 1: Check Prerequisites ─────────────────────────

echo -e "${BOLD}Step 1: Checking prerequisites${NC}"
echo ""

# Check Docker
if command -v docker &>/dev/null; then
  DOCKER_VERSION=$(docker --version 2>/dev/null | head -1)
  success "Docker installed: $DOCKER_VERSION"
else
  warn "Docker is not installed."
  case "$(uname -s)" in
    Darwin)
      if command -v brew &>/dev/null; then
        if ask_yesno "Install Docker Desktop via Homebrew?" "Y"; then
          info "Installing Docker Desktop..."
          brew install --cask docker
          success "Docker Desktop installed. Please open it from Applications to start the daemon."
          echo -e "  ${DIM}Then re-run this script.${NC}"
          exit 0
        fi
      else
        error "Please install Docker Desktop from: https://www.docker.com/products/docker-desktop/"
        exit 1
      fi
      ;;
    Linux)
      if ask_yesno "Install Docker via official install script? (requires sudo)" "Y"; then
        info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        sudo systemctl enable --now docker 2>/dev/null || true
        sudo usermod -aG docker "$USER" 2>/dev/null || true
        success "Docker installed."
        warn "You may need to log out and back in for group changes to take effect."
        warn "Then re-run this script."
        exit 0
      else
        error "Please install Docker manually: https://docs.docker.com/engine/install/"
        exit 1
      fi
      ;;
    *)
      error "Unsupported platform: $(uname -s)"
      error "Please install Docker manually: https://docs.docker.com/engine/install/"
      exit 1
      ;;
  esac
fi

# Check Docker Compose
if docker compose version &>/dev/null; then
  success "Docker Compose available (plugin)"
elif command -v docker-compose &>/dev/null; then
  success "Docker Compose available (standalone)"
else
  error "Docker Compose is not installed."
  error "Install it: https://docs.docker.com/compose/install/"
  exit 1
fi

# Check Docker daemon
if docker info &>/dev/null 2>&1; then
  success "Docker daemon is running"
else
  warn "Docker daemon is not running."
  case "$(uname -s)" in
    Darwin)
      info "Please open Docker Desktop from your Applications folder."
      ;;
    Linux)
      info "Try: sudo systemctl start docker"
      ;;
  esac
  error "Start Docker and re-run this script."
  exit 1
fi

echo ""

# ─── Step 2: Interactive Configuration ───────────────────

echo -e "${BOLD}Step 2: Configuration${NC}"
echo ""

# Redis version
REDIS_VERSION=$(ask "Redis version" "7.4")

# Password
echo ""
echo -e "  ${DIM}A password is recommended for production use.${NC}"
echo -e "  ${DIM}Press Enter to skip (no authentication).${NC}"
REDIS_PASSWORD=$(ask_password "Redis password")
if [[ -n "$REDIS_PASSWORD" ]]; then
  success "Password set."
else
  warn "No password set. Cluster will be unauthenticated."
fi

# Number of masters
echo ""
NUM_MASTERS=$(ask "Number of master nodes (min 3)" "3")
while ! [[ "$NUM_MASTERS" =~ ^[0-9]+$ ]] || [[ "$NUM_MASTERS" -lt 3 ]]; do
  warn "Must be a number >= 3"
  NUM_MASTERS=$(ask "Number of master nodes (min 3)" "3")
done
TOTAL_NODES=$((NUM_MASTERS * 2))

# Max memory
echo ""
echo -e "  ${DIM}Examples: 256mb, 1gb, 4gb. Leave empty for no limit.${NC}"
REDIS_MAXMEMORY=$(ask "Max memory per node" "")

# HAProxy ports
echo ""
echo -e "  ${DIM}HAProxy load balancer ports:${NC}"
HAPROXY_WRITE_PORT=$(ask "Write endpoint port (masters)" "6380")
while ! validate_port "$HAPROXY_WRITE_PORT"; do
  warn "Invalid port. Must be 1024-65535."
  HAPROXY_WRITE_PORT=$(ask "Write endpoint port" "6380")
done

HAPROXY_READ_PORT=$(ask "Read endpoint port (replicas)" "6381")
while ! validate_port "$HAPROXY_READ_PORT"; do
  warn "Invalid port. Must be 1024-65535."
  HAPROXY_READ_PORT=$(ask "Read endpoint port" "6381")
done

HAPROXY_STATS_PORT=$(ask "Stats dashboard port" "8404")
while ! validate_port "$HAPROXY_STATS_PORT"; do
  warn "Invalid port. Must be 1024-65535."
  HAPROXY_STATS_PORT=$(ask "Stats dashboard port" "8404")
done

# ─── Monitoring (optional) ────────────────────────────────

echo ""
echo -e "${BOLD}Monitoring & Alerts (optional)${NC}"
echo ""

MONITOR_ENABLED="false"
MONITOR_INTERVAL="10"
MONITOR_MEMORY_THRESHOLD="80"
SMTP_ENABLED="false"
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USERNAME=""
SMTP_PASSWORD=""
SMTP_FROM=""
SMTP_TO=""
SMTP_TLS="true"
DISCORD_ENABLED="false"
DISCORD_WEBHOOK_URL=""
WEBHOOK_ENABLED="false"
WEBHOOK_URL=""
WEBHOOK_HEADERS=""

if ask_yesno "Enable cluster monitoring?" "N"; then
  MONITOR_ENABLED="true"
  MONITOR_INTERVAL=$(ask "Check interval in seconds" "10")
  MONITOR_MEMORY_THRESHOLD=$(ask "Memory alert threshold (%)" "80")

  echo ""
  echo -e "  ${DIM}Configure one or more notification channels:${NC}"

  # Email
  echo ""
  if ask_yesno "  Enable email notifications (SMTP)?" "N"; then
    SMTP_ENABLED="true"
    SMTP_HOST=$(ask "  SMTP host" "")
    while [[ -z "$SMTP_HOST" ]]; do
      warn "SMTP host is required."
      SMTP_HOST=$(ask "  SMTP host" "")
    done
    SMTP_PORT=$(ask "  SMTP port" "587")
    SMTP_USERNAME=$(ask "  SMTP username" "")
    SMTP_PASSWORD=$(ask_password "  SMTP password")
    SMTP_FROM=$(ask "  From address" "")
    SMTP_TO=$(ask "  To address(es, comma-separated)" "")
    SMTP_TLS=$(ask "  Use TLS? (true/false)" "true")
  fi

  # Discord
  echo ""
  if ask_yesno "  Enable Discord notifications?" "N"; then
    DISCORD_ENABLED="true"
    DISCORD_WEBHOOK_URL=$(ask "  Discord webhook URL" "")
    while [[ -z "$DISCORD_WEBHOOK_URL" ]]; do
      warn "Webhook URL is required."
      DISCORD_WEBHOOK_URL=$(ask "  Discord webhook URL" "")
    done
  fi

  # Generic webhook
  echo ""
  if ask_yesno "  Enable generic webhook notifications?" "N"; then
    WEBHOOK_ENABLED="true"
    WEBHOOK_URL=$(ask "  Webhook URL" "")
    while [[ -z "$WEBHOOK_URL" ]]; do
      warn "Webhook URL is required."
      WEBHOOK_URL=$(ask "  Webhook URL" "")
    done
    WEBHOOK_HEADERS=$(ask "  Custom headers (Header:Value,... or empty)" "")
  fi
fi

echo ""

# ─── Step 3: Summary ─────────────────────────────────────

echo -e "${BOLD}Step 3: Review configuration${NC}"
echo ""
echo -e "  ┌────────────────────────────────────────────┐"
echo -e "  │  ${BOLD}Redis HA Cluster Configuration${NC}            │"
echo -e "  ├────────────────────────────────────────────┤"
printf "  │  %-18s %-23s │\n" "Redis version:" "$REDIS_VERSION"
if [[ -n "$REDIS_PASSWORD" ]]; then
  printf "  │  %-18s %-23s │\n" "Authentication:" "Enabled"
else
  printf "  │  %-18s %-23s │\n" "Authentication:" "Disabled"
fi
printf "  │  %-18s %-23s │\n" "Masters:" "$NUM_MASTERS"
printf "  │  %-18s %-23s │\n" "Replicas:" "$NUM_MASTERS"
printf "  │  %-18s %-23s │\n" "Total nodes:" "$TOTAL_NODES"
printf "  │  %-18s %-23s │\n" "Max memory:" "${REDIS_MAXMEMORY:-no limit}"
echo -e "  ├────────────────────────────────────────────┤"
printf "  │  %-18s %-23s │\n" "Write port:" "$HAPROXY_WRITE_PORT"
printf "  │  %-18s %-23s │\n" "Read port:" "$HAPROXY_READ_PORT"
printf "  │  %-18s %-23s │\n" "Stats port:" "$HAPROXY_STATS_PORT"
printf "  │  %-18s %-23s │\n" "Node ports:" "7001-$((7000 + TOTAL_NODES))"
if [[ "$MONITOR_ENABLED" == "true" ]]; then
  echo -e "  ├────────────────────────────────────────────┤"
  printf "  │  %-18s %-23s │\n" "Monitoring:" "Enabled (${MONITOR_INTERVAL}s)"
  printf "  │  %-18s %-23s │\n" "Memory threshold:" "${MONITOR_MEMORY_THRESHOLD}%"
  local_channels=""
  [[ "$SMTP_ENABLED" == "true" ]] && local_channels="Email "
  [[ "$DISCORD_ENABLED" == "true" ]] && local_channels="${local_channels}Discord "
  [[ "$WEBHOOK_ENABLED" == "true" ]] && local_channels="${local_channels}Webhook"
  printf "  │  %-18s %-23s │\n" "Channels:" "${local_channels:-None}"
fi
echo -e "  └────────────────────────────────────────────┘"
echo ""

if ! ask_yesno "Apply this configuration?" "Y"; then
  info "Aborted."
  exit 0
fi

echo ""

# ─── Step 4: Generate Configuration Files ────────────────

echo -e "${BOLD}Step 4: Generating configuration${NC}"
echo ""

# Generate .env
cat > "$PROJECT_DIR/.env" <<EOF
REDIS_VERSION=$REDIS_VERSION
REDIS_PASSWORD=$REDIS_PASSWORD
CLUSTER_NODE_TIMEOUT=5000
REDIS_MAXMEMORY=$REDIS_MAXMEMORY

# HAProxy load balancer ports
HAPROXY_WRITE_PORT=$HAPROXY_WRITE_PORT
HAPROXY_READ_PORT=$HAPROXY_READ_PORT
HAPROXY_STATS_PORT=$HAPROXY_STATS_PORT

# Multi-server (optional)
MULTI_SERVER=false
ANNOUNCE_IP=

# Monitoring
MONITOR_ENABLED=$MONITOR_ENABLED
MONITOR_INTERVAL=$MONITOR_INTERVAL
MONITOR_MEMORY_THRESHOLD=$MONITOR_MEMORY_THRESHOLD

# Email (SMTP)
SMTP_ENABLED=$SMTP_ENABLED
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_USERNAME=$SMTP_USERNAME
SMTP_PASSWORD=$SMTP_PASSWORD
SMTP_FROM=$SMTP_FROM
SMTP_TO=$SMTP_TO
SMTP_TLS=$SMTP_TLS

# Discord
DISCORD_ENABLED=$DISCORD_ENABLED
DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL

# Generic webhook
WEBHOOK_ENABLED=$WEBHOOK_ENABLED
WEBHOOK_URL=$WEBHOOK_URL
WEBHOOK_HEADERS=$WEBHOOK_HEADERS
EOF
success "Generated .env"

# Generate redis.conf
cat > "$PROJECT_DIR/redis.conf" <<EOF
# Networking
port 6379
bind 0.0.0.0
protected-mode no

# Cluster
cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
cluster-require-full-coverage no
cluster-allow-reads-when-down yes

# Persistence
appendonly yes
appendfilename "appendonly.aof"
save 900 1
save 300 10
save 60 10000

# Memory
maxmemory-policy allkeys-lru
EOF

if [[ -n "$REDIS_MAXMEMORY" ]]; then
  echo "maxmemory $REDIS_MAXMEMORY" >> "$PROJECT_DIR/redis.conf"
fi

if [[ -n "$REDIS_PASSWORD" ]]; then
  cat >> "$PROJECT_DIR/redis.conf" <<EOF

# Authentication
requirepass $REDIS_PASSWORD
masterauth $REDIS_PASSWORD
EOF
fi

echo "
# Logging
loglevel notice" >> "$PROJECT_DIR/redis.conf"

success "Generated redis.conf"

# Generate docker-compose.yml if non-default master count
if [[ "$NUM_MASTERS" -ne 3 ]]; then
  info "Generating docker-compose.yml for $TOTAL_NODES nodes..."

  cat > "$PROJECT_DIR/docker-compose.yml" <<'ANCHOR'
x-redis-node: &redis-node
  image: redis:${REDIS_VERSION:-7.4}
  command: redis-server /usr/local/etc/redis/redis.conf
  networks:
    - redis-cluster-net
  environment:
    - REDISCLI_AUTH=${REDIS_PASSWORD:-}
  healthcheck:
    test: ["CMD", "redis-cli", "-p", "6379", "ping"]
    interval: 5s
    timeout: 3s
    retries: 5
    start_period: 10s
  restart: unless-stopped

services:
ANCHOR

  for i in $(seq 1 "$TOTAL_NODES"); do
    PORT=$((7000 + i))
    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  redis-node-$i:
    <<: *redis-node
    container_name: redis-node-$i
    ports:
      - "$PORT:6379"
    volumes:
      - redis-data-$i:/data
      - ./redis.conf:/usr/local/etc/redis/redis.conf:ro

EOF
  done

  echo "volumes:" >> "$PROJECT_DIR/docker-compose.yml"
  for i in $(seq 1 "$TOTAL_NODES"); do
    echo "  redis-data-$i:" >> "$PROJECT_DIR/docker-compose.yml"
  done

  cat >> "$PROJECT_DIR/docker-compose.yml" <<'EOF'

networks:
  redis-cluster-net:
    driver: bridge
EOF

  success "Generated docker-compose.yml ($TOTAL_NODES nodes)"

  # Update start.sh node count reference
  # The start.sh script uses `seq 1 6` — we need to update the helpers or
  # make start.sh dynamic. For now, patch the seq range.
  sed -i.bak "s/seq 1 6/seq 1 $TOTAL_NODES/g" "$PROJECT_DIR/scripts/start.sh"
  rm -f "$PROJECT_DIR/scripts/start.sh.bak"
  success "Updated start.sh for $TOTAL_NODES nodes"
else
  success "Using default docker-compose.yml (6 nodes)"
fi

echo ""

# ─── Step 5: Start Cluster ───────────────────────────────

echo -e "${BOLD}Step 5: Launch${NC}"
echo ""

if ask_yesno "Start the cluster now?" "Y"; then
  echo ""
  exec "$PROJECT_DIR/scripts/start.sh"
else
  echo ""
  success "Setup complete! Start the cluster with:"
  echo ""
  echo -e "  ${BOLD}./scripts/start.sh${NC}"
  echo ""
  if [[ -n "$REDIS_PASSWORD" ]]; then
    echo -e "  Connect: ${DIM}redis-cli -p 7001 -c -a \"$REDIS_PASSWORD\"${NC}"
  else
    echo -e "  Connect: ${DIM}redis-cli -p 7001 -c${NC}"
  fi
  echo -e "  Status:  ${DIM}./scripts/status.sh${NC}"
  echo -e "  Stats:   ${DIM}http://localhost:$HAPROXY_STATS_PORT/stats${NC}"
  echo ""
fi
