#!/usr/bin/env bash
set -euo pipefail

# ─── Colors & Symbols ────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CHECK="${GREEN}✓${NC}"
CROSS="${RED}✗${NC}"
ARROW="${CYAN}›${NC}"
DOT="${DIM}·${NC}"

REPO_URL="https://github.com/lassejlv/redis-ha.git"
TOTAL_STEPS=5

# ─── UI Helpers ───────────────────────────────────────────

info()    { echo -e "  ${BLUE}ℹ${NC}  $1"; }
success() { echo -e "  ${CHECK}  $1"; }
warn()    { echo -e "  ${YELLOW}!${NC}  $1"; }
error()   { echo -e "  ${CROSS}  $1"; }

divider() {
  echo -e "  ${DIM}$(printf '─%.0s' {1..52})${NC}"
}

step() {
  local num="$1" title="$2"
  echo ""
  echo -e "  ${BOLD}${WHITE}[$num/$TOTAL_STEPS]${NC} ${BOLD}$title${NC}"
  divider
  echo ""
}

spinner() {
  local pid=$1 msg="$2"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    echo -en "\r  ${CYAN}${frames[$i]}${NC}  $msg" >&2
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
  local exit_code=$?
  echo -en "\r\033[K" >&2
  return $exit_code
}

run_with_spinner() {
  local msg="$1"
  shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  if spinner "$pid" "$msg"; then
    success "$msg"
    return 0
  else
    error "$msg — failed"
    return 1
  fi
}

ask() {
  local prompt="$1" default="$2" value
  if [[ -n "$default" ]]; then
    echo -en "  ${ARROW}  ${prompt} ${DIM}[$default]${NC} " >&2
  else
    echo -en "  ${ARROW}  ${prompt} " >&2
  fi
  read -r value < /dev/tty
  echo "${value:-$default}"
}

ask_password() {
  local prompt="$1" pass1 pass2
  while true; do
    echo -en "  ${ARROW}  ${prompt} " >&2
    read -rs pass1 < /dev/tty
    echo "" >&2
    if [[ -z "$pass1" ]]; then
      return
    fi
    echo -en "  ${ARROW}  Confirm password " >&2
    read -rs pass2 < /dev/tty
    echo "" >&2
    if [[ "$pass1" == "$pass2" ]]; then
      echo "$pass1"
      return
    fi
    warn "Passwords do not match. Try again."
  done
}

ask_yesno() {
  local prompt="$1" default="$2" value
  echo -en "  ${ARROW}  ${prompt} ${DIM}[$default]${NC} " >&2
  read -r value < /dev/tty
  value="${value:-$default}"
  [[ "$value" =~ ^[Yy] ]]
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1024 ]] && [[ "$port" -le 65535 ]]
}

detect_pkg_manager() {
  if command -v apt-get &>/dev/null; then
    echo "apt"
  elif command -v dnf &>/dev/null; then
    echo "dnf"
  elif command -v yum &>/dev/null; then
    echo "yum"
  elif command -v apk &>/dev/null; then
    echo "apk"
  else
    echo "unknown"
  fi
}

# ─── Banner ───────────────────────────────────────────────

clear 2>/dev/null || true
echo ""
echo -e "${BOLD}${RED}"
cat << 'BANNER'
      ██████╗ ███████╗██████╗ ██╗███████╗    ██╗  ██╗ █████╗
      ██╔══██╗██╔════╝██╔══██╗██║██╔════╝    ██║  ██║██╔══██╗
      ██████╔╝█████╗  ██║  ██║██║███████╗    ███████║███████║
      ██╔══██╗██╔══╝  ██║  ██║██║╚════██║    ██╔══██║██╔══██║
      ██║  ██║███████╗██████╔╝██║███████║    ██║  ██║██║  ██║
      ╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝╚══════╝    ╚═╝  ╚═╝╚═╝  ╚═╝
BANNER
echo -e "${NC}"
echo -e "  ${DIM}High-Availability Redis Cluster · Docker · HAProxy · Monitoring${NC}"
echo -e "  ${DIM}github.com/lassejlv/redis-ha${NC}"
echo ""

# ─── Standalone installer: clone if not in repo ──────────

if [[ ! -f "./docker-compose.yml" ]] && [[ ! -f "./scripts/helpers.sh" ]]; then
  info "Not inside the redis-ha project. Cloning..."
  if ! command -v git &>/dev/null; then
    error "git is not installed. Please install git first."
    exit 1
  fi
  git clone --quiet "$REPO_URL" redis-ha
  success "Repository cloned into ./redis-ha"
  echo ""
  cd redis-ha
  exec ./setup.sh
fi

PROJECT_DIR="$(pwd)"

# ═════════════════════════════════════════════════════════
# Step 1: System & Dependencies
# ═════════════════════════════════════════════════════════

step 1 "System & Dependencies"

OS="$(uname -s)"
PKG_MANAGER="unknown"

if [[ "$OS" == "Linux" ]]; then
  PKG_MANAGER=$(detect_pkg_manager)

  if [[ "$PKG_MANAGER" != "unknown" ]]; then
    info "Detected package manager: ${BOLD}$PKG_MANAGER${NC}"
    echo ""

    # Update system packages
    case "$PKG_MANAGER" in
      apt)
        run_with_spinner "Updating package lists" sudo apt-get update -qq || true
        run_with_spinner "Upgrading system packages" sudo apt-get upgrade -y -qq || true
        run_with_spinner "Installing dependencies" sudo apt-get install -y -qq curl git ca-certificates gnupg lsb-release || true
        ;;
      dnf)
        run_with_spinner "Updating system packages" sudo dnf update -y --quiet || true
        run_with_spinner "Installing dependencies" sudo dnf install -y --quiet curl git ca-certificates || true
        ;;
      yum)
        run_with_spinner "Updating system packages" sudo yum update -y --quiet || true
        run_with_spinner "Installing dependencies" sudo yum install -y --quiet curl git ca-certificates || true
        ;;
      apk)
        run_with_spinner "Updating package lists" apk update --quiet || true
        run_with_spinner "Installing dependencies" apk add --quiet curl git ca-certificates || true
        ;;
    esac
    echo ""
  fi
elif [[ "$OS" == "Darwin" ]]; then
  info "macOS detected — skipping system package update"
  echo ""
fi

# ─── Docker ──────────────────────────────────────────────

if command -v docker &>/dev/null; then
  DOCKER_VERSION=$(docker --version 2>/dev/null | sed 's/Docker version //' | cut -d, -f1)
  success "Docker ${DIM}v${DOCKER_VERSION}${NC}"
else
  warn "Docker is not installed"
  echo ""

  case "$OS" in
    Darwin)
      if command -v brew &>/dev/null; then
        if ask_yesno "Install Docker Desktop via Homebrew?" "Y"; then
          run_with_spinner "Installing Docker Desktop" brew install --cask docker
          echo ""
          warn "Open Docker Desktop from Applications to start the daemon."
          warn "Then re-run: ${BOLD}./setup.sh${NC}"
          exit 0
        fi
      fi
      error "Install Docker Desktop: https://docker.com/products/docker-desktop/"
      exit 1
      ;;
    Linux)
      if ask_yesno "Install Docker via official script? (requires sudo)" "Y"; then
        echo ""
        run_with_spinner "Installing Docker" bash -c 'curl -fsSL https://get.docker.com | sh'
        sudo systemctl enable --now docker 2>/dev/null || true
        sudo usermod -aG docker "$USER" 2>/dev/null || true

        # Verify Docker works (may need sudo if group not active yet)
        if docker info &>/dev/null 2>&1; then
          success "Docker installed and running"
        elif sudo docker info &>/dev/null 2>&1; then
          success "Docker installed (using sudo for this session)"
          # Alias docker to sudo docker for rest of this script
          docker() { sudo docker "$@"; }
          export -f docker 2>/dev/null || true
        else
          error "Docker installed but daemon not responding"
          warn "Try: ${BOLD}sudo systemctl start docker${NC} then re-run this script"
          exit 1
        fi
      else
        error "Docker is required. Install: https://docs.docker.com/engine/install/"
        exit 1
      fi
      ;;
    *)
      error "Unsupported platform: $OS"
      exit 1
      ;;
  esac
fi

# ─── Docker Compose ──────────────────────────────────────

if docker compose version &>/dev/null; then
  COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "available")
  success "Docker Compose ${DIM}v${COMPOSE_VERSION}${NC}"
elif command -v docker-compose &>/dev/null; then
  success "Docker Compose ${DIM}(standalone)${NC}"
else
  error "Docker Compose not found: https://docs.docker.com/compose/install/"
  exit 1
fi

# ─── Docker Daemon ───────────────────────────────────────

if docker info &>/dev/null 2>&1; then
  success "Docker daemon running"
else
  echo ""
  case "$OS" in
    Darwin) warn "Start Docker Desktop, then re-run this script." ;;
    Linux)  warn "Run: ${BOLD}sudo systemctl start docker${NC}" ;;
  esac
  error "Docker daemon not responding"
  exit 1
fi

# ═════════════════════════════════════════════════════════
# Step 2: Configuration
# ═════════════════════════════════════════════════════════

step 2 "Configuration"

echo -e "  ${DIM}Press Enter to accept defaults shown in brackets.${NC}"
echo ""

# Redis version
REDIS_VERSION=$(ask "Redis version" "7.4")

# Password
echo ""
echo -e "  ${DIM}A password is recommended for production use.${NC}"
echo -e "  ${DIM}Press Enter to skip (no authentication).${NC}"
REDIS_PASSWORD=$(ask_password "Redis password")
if [[ -n "$REDIS_PASSWORD" ]]; then
  success "Password configured"
else
  warn "No password — cluster will be open"
fi

# Masters
echo ""
NUM_MASTERS=$(ask "Number of master nodes (min 3)" "3")
while ! [[ "$NUM_MASTERS" =~ ^[0-9]+$ ]] || [[ "$NUM_MASTERS" -lt 3 ]]; do
  warn "Must be >= 3"
  NUM_MASTERS=$(ask "Number of master nodes (min 3)" "3")
done
TOTAL_NODES=$((NUM_MASTERS * 2))

# Memory
echo ""
echo -e "  ${DIM}Examples: 256mb, 1gb, 4gb. Empty = no limit.${NC}"
REDIS_MAXMEMORY=$(ask "Max memory per node" "")

# HAProxy ports
echo ""
echo -e "  ${BOLD}Load Balancer Ports${NC}"
HAPROXY_WRITE_PORT=$(ask "Write port (masters)" "6380")
while ! validate_port "$HAPROXY_WRITE_PORT"; do
  warn "Invalid port (1024-65535)"
  HAPROXY_WRITE_PORT=$(ask "Write port" "6380")
done

HAPROXY_READ_PORT=$(ask "Read port (replicas)" "6381")
while ! validate_port "$HAPROXY_READ_PORT"; do
  warn "Invalid port (1024-65535)"
  HAPROXY_READ_PORT=$(ask "Read port" "6381")
done

HAPROXY_STATS_PORT=$(ask "Stats dashboard port" "8404")
while ! validate_port "$HAPROXY_STATS_PORT"; do
  warn "Invalid port (1024-65535)"
  HAPROXY_STATS_PORT=$(ask "Stats dashboard port" "8404")
done

# ─── Monitoring ──────────────────────────────────────────

echo ""
echo -e "  ${BOLD}Monitoring & Alerts${NC}"
echo ""

MONITOR_ENABLED="false"
MONITOR_INTERVAL="10"
MONITOR_MEMORY_THRESHOLD="80"
SMTP_ENABLED="false"; SMTP_HOST=""; SMTP_PORT="587"; SMTP_USERNAME=""
SMTP_PASSWORD=""; SMTP_FROM=""; SMTP_TO=""; SMTP_TLS="true"
DISCORD_ENABLED="false"; DISCORD_WEBHOOK_URL=""
WEBHOOK_ENABLED="false"; WEBHOOK_URL=""; WEBHOOK_HEADERS=""

if ask_yesno "Enable cluster monitoring?" "N"; then
  MONITOR_ENABLED="true"
  MONITOR_INTERVAL=$(ask "Check interval (seconds)" "10")
  MONITOR_MEMORY_THRESHOLD=$(ask "Memory alert threshold (%)" "80")

  echo ""
  echo -e "  ${DIM}Configure notification channels:${NC}"

  echo ""
  if ask_yesno "Email (SMTP)?" "N"; then
    SMTP_ENABLED="true"
    SMTP_HOST=$(ask "SMTP host" "")
    while [[ -z "$SMTP_HOST" ]]; do
      warn "Required"; SMTP_HOST=$(ask "SMTP host" "")
    done
    SMTP_PORT=$(ask "SMTP port" "587")
    SMTP_USERNAME=$(ask "SMTP username" "")
    SMTP_PASSWORD=$(ask_password "SMTP password")
    SMTP_FROM=$(ask "From address" "")
    SMTP_TO=$(ask "To address(es)" "")
    SMTP_TLS=$(ask "Use TLS?" "true")
  fi

  echo ""
  if ask_yesno "Discord webhook?" "N"; then
    DISCORD_ENABLED="true"
    DISCORD_WEBHOOK_URL=$(ask "Webhook URL" "")
    while [[ -z "$DISCORD_WEBHOOK_URL" ]]; do
      warn "Required"; DISCORD_WEBHOOK_URL=$(ask "Webhook URL" "")
    done
  fi

  echo ""
  if ask_yesno "Generic POST webhook?" "N"; then
    WEBHOOK_ENABLED="true"
    WEBHOOK_URL=$(ask "Webhook URL" "")
    while [[ -z "$WEBHOOK_URL" ]]; do
      warn "Required"; WEBHOOK_URL=$(ask "Webhook URL" "")
    done
    WEBHOOK_HEADERS=$(ask "Custom headers (K:V,K:V or empty)" "")
  fi
fi

# ═════════════════════════════════════════════════════════
# Step 3: Review
# ═════════════════════════════════════════════════════════

step 3 "Review"

AUTH_DISPLAY="Disabled"
[[ -n "$REDIS_PASSWORD" ]] && AUTH_DISPLAY="Enabled"

MONITOR_DISPLAY="Disabled"
CHANNELS=""
if [[ "$MONITOR_ENABLED" == "true" ]]; then
  MONITOR_DISPLAY="Every ${MONITOR_INTERVAL}s"
  [[ "$SMTP_ENABLED" == "true" ]] && CHANNELS="Email "
  [[ "$DISCORD_ENABLED" == "true" ]] && CHANNELS="${CHANNELS}Discord "
  [[ "$WEBHOOK_ENABLED" == "true" ]] && CHANNELS="${CHANNELS}Webhook"
fi

echo -e "  ${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}║         Redis HA Cluster Configuration       ║${NC}"
echo -e "  ${BOLD}╠══════════════════════════════════════════════╣${NC}"
printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Redis" "v${REDIS_VERSION}"
printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Authentication" "$AUTH_DISPLAY"
printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Topology" "${NUM_MASTERS}m + ${NUM_MASTERS}r = ${TOTAL_NODES} nodes"
printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Max memory" "${REDIS_MAXMEMORY:-unlimited}"
echo -e "  ${BOLD}╠══════════════════════════════════════════════╣${NC}"
printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Write port" "$HAPROXY_WRITE_PORT"
printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Read port" "$HAPROXY_READ_PORT"
printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Stats port" "$HAPROXY_STATS_PORT"
printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Node ports" "7001-$((7000 + TOTAL_NODES))"
echo -e "  ${BOLD}╠══════════════════════════════════════════════╣${NC}"
printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Monitoring" "$MONITOR_DISPLAY"
if [[ -n "$CHANNELS" ]]; then
  printf "  ${BOLD}║${NC}  %-16s ${WHITE}%-26s${NC} ${BOLD}║${NC}\n" "Channels" "$CHANNELS"
fi
echo -e "  ${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

if ! ask_yesno "Apply this configuration?" "Y"; then
  echo ""
  info "Aborted."
  exit 0
fi

# ═════════════════════════════════════════════════════════
# Step 4: Generate
# ═════════════════════════════════════════════════════════

step 4 "Generating Files"

# .env
cat > "$PROJECT_DIR/.env" <<EOF
REDIS_VERSION=$REDIS_VERSION
REDIS_PASSWORD=$REDIS_PASSWORD
CLUSTER_NODE_TIMEOUT=5000
REDIS_MAXMEMORY=$REDIS_MAXMEMORY

HAPROXY_WRITE_PORT=$HAPROXY_WRITE_PORT
HAPROXY_READ_PORT=$HAPROXY_READ_PORT
HAPROXY_STATS_PORT=$HAPROXY_STATS_PORT

MULTI_SERVER=false
ANNOUNCE_IP=

MONITOR_ENABLED=$MONITOR_ENABLED
MONITOR_INTERVAL=$MONITOR_INTERVAL
MONITOR_MEMORY_THRESHOLD=$MONITOR_MEMORY_THRESHOLD

SMTP_ENABLED=$SMTP_ENABLED
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_USERNAME=$SMTP_USERNAME
SMTP_PASSWORD=$SMTP_PASSWORD
SMTP_FROM=$SMTP_FROM
SMTP_TO=$SMTP_TO
SMTP_TLS=$SMTP_TLS

DISCORD_ENABLED=$DISCORD_ENABLED
DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL

WEBHOOK_ENABLED=$WEBHOOK_ENABLED
WEBHOOK_URL=$WEBHOOK_URL
WEBHOOK_HEADERS=$WEBHOOK_HEADERS
EOF
success ".env"

# redis.conf
cat > "$PROJECT_DIR/redis.conf" <<EOF
port 6379
bind 0.0.0.0
protected-mode no

cluster-enabled yes
cluster-config-file nodes.conf
cluster-node-timeout 5000
cluster-require-full-coverage no
cluster-allow-reads-when-down yes

appendonly yes
appendfilename "appendonly.aof"
save 900 1
save 300 10
save 60 10000

maxmemory-policy allkeys-lru
EOF

[[ -n "$REDIS_MAXMEMORY" ]] && echo "maxmemory $REDIS_MAXMEMORY" >> "$PROJECT_DIR/redis.conf"

if [[ -n "$REDIS_PASSWORD" ]]; then
  cat >> "$PROJECT_DIR/redis.conf" <<EOF

requirepass $REDIS_PASSWORD
masterauth $REDIS_PASSWORD
EOF
fi

echo -e "\nloglevel notice" >> "$PROJECT_DIR/redis.conf"
success "redis.conf"

# docker-compose.yml (if custom master count)
if [[ "$NUM_MASTERS" -ne 3 ]]; then
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

  sed -i.bak "s/seq 1 6/seq 1 $TOTAL_NODES/g" "$PROJECT_DIR/scripts/start.sh"
  rm -f "$PROJECT_DIR/scripts/start.sh.bak"
  success "docker-compose.yml ${DIM}(${TOTAL_NODES} nodes)${NC}"
else
  success "docker-compose.yml ${DIM}(default 6 nodes)${NC}"
fi

# ═════════════════════════════════════════════════════════
# Step 5: Launch
# ═════════════════════════════════════════════════════════

step 5 "Launch"

if ask_yesno "Start the cluster now?" "Y"; then
  echo ""
  exec "$PROJECT_DIR/scripts/start.sh"
else
  AUTH=""
  [[ -n "$REDIS_PASSWORD" ]] && AUTH=":${REDIS_PASSWORD}@"

  echo ""
  success "Setup complete!"
  echo ""
  divider
  echo ""
  echo -e "  ${BOLD}Start:${NC}   ./scripts/start.sh"
  echo -e "  ${BOLD}Status:${NC}  ./scripts/status.sh"
  echo -e "  ${BOLD}URLs:${NC}    ./scripts/urls.sh"
  echo -e "  ${BOLD}Delete:${NC}  ./scripts/delete.sh"
  echo ""
  divider
  echo ""
  echo -e "  ${DIM}Write:${NC}  redis://${AUTH}localhost:${HAPROXY_WRITE_PORT}"
  echo -e "  ${DIM}Read:${NC}   redis://${AUTH}localhost:${HAPROXY_READ_PORT}"
  echo -e "  ${DIM}Stats:${NC}  http://localhost:${HAPROXY_STATS_PORT}/stats"
  echo ""
fi
