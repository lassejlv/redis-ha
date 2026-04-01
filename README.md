# Redis HA Cluster

A Docker-based Redis Cluster with High Availability. 3 masters + 3 replicas out of the box, with HAProxy load balancing, authentication, and multi-server support.

## Setup

Run the interactive setup wizard:

```bash
./setup.sh
```

This will:
- Check and optionally install Docker
- Ask for Redis version, password, node count, memory limits, and ports
- Generate all configuration files
- Optionally start the cluster

**One-liner install** (curl):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lassejlv/redis-ha/main/setup.sh)
```

Or with git:

```bash
git clone https://github.com/lassejlv/redis-ha.git && cd redis-ha && ./setup.sh
```

## Quick Start (Manual)

If you prefer to skip the wizard:

```bash
cp .env.example .env          # Edit .env with your settings
./scripts/start.sh            # Start cluster + HAProxy
./scripts/status.sh           # Check cluster health
```

Connect from host:

```bash
redis-cli -p 7001 -c -a "$REDIS_PASSWORD"    # Direct node access
redis-cli -p 6380 -a "$REDIS_PASSWORD"        # Write via load balancer
redis-cli -p 6381 -a "$REDIS_PASSWORD"        # Read via load balancer
```

## Architecture

```
                      ┌──────────────────┐
                      │     HAProxy      │
                      │  :6380 (write)   │──► masters only
                      │  :6381 (read)    │──► replicas only
                      │  :8404 (stats)   │
                      └────────┬─────────┘
                               │
┌──────────────────────────────┼──────────────────────────────┐
│              Docker Bridge Network                          │
│                              │                              │
│  ┌───────────┐  ┌────────────┴──┐  ┌───────────┐           │
│  │  Master 1  │  │   Master 2   │  │  Master 3  │          │
│  │  :7001     │  │   :7002      │  │  :7003     │          │
│  │  0-5460    │  │  5461-10922  │  │ 10923-16383│          │
│  └─────┬──────┘  └──────┬──────┘  └─────┬──────┘          │
│        │                │                │                  │
│  ┌─────▼──────┐  ┌──────▼──────┐  ┌─────▼──────┐          │
│  │  Replica 4 │  │  Replica 5  │  │  Replica 6 │          │
│  │  :7004     │  │  :7005      │  │  :7006     │          │
│  └────────────┘  └─────────────┘  └────────────┘          │
└────────────────────────────────────────────────────────────┘
```

- **16384 hash slots** distributed across masters
- Each master has a replica for automatic failover
- HAProxy detects master/replica roles via `tcp-check` every 2s
- `cluster-require-full-coverage no` — cluster stays available during partial failures
- AOF + RDB persistence via named Docker volumes

## Scripts

| Script | Description |
|---|---|
| `./setup.sh` | Interactive setup wizard. Checks Docker, configures everything. |
| `./scripts/start.sh` | Start all nodes + HAProxy. Initializes cluster on first run. |
| `./scripts/stop.sh` | Graceful shutdown. Data volumes preserved. |
| `./scripts/stop.sh --clean` | Stop and delete all data volumes (full reset). |
| `./scripts/restart.sh` | Stop then start. Data preserved. |
| `./scripts/status.sh` | Cluster state, node roles, slots, memory, and LB health. |
| `./scripts/scale-up.sh` | Add a master + replica pair. Rebalances slots. Updates HAProxy. |
| `./scripts/scale-down.sh` | Remove last-added pair. Drains slots first. Updates HAProxy. |
| `./scripts/urls.sh` | Show all Redis connection URLs (internal, public, localhost). |

## Authentication

The setup wizard configures Redis authentication. When a password is set:

- `redis.conf` gets `requirepass` + `masterauth` directives
- All scripts authenticate automatically via `REDISCLI_AUTH` environment variable
- HAProxy health checks authenticate via `AUTH` in the tcp-check sequence
- Container health checks authenticate via the `REDISCLI_AUTH` env var

Password is stored in `.env` (gitignored). The tracked `.env.example` has empty defaults.

## Load Balancer (HAProxy)

HAProxy provides single-endpoint access to the cluster:

| Endpoint | Port | Routes to |
|---|---|---|
| Write | `6380` | Masters only |
| Read | `6381` | Replicas only |
| Stats | `8404` | HAProxy dashboard |

Role detection uses `tcp-check` with `INFO replication`. On failover, HAProxy detects the role change within ~6 seconds.

Stats dashboard: http://localhost:8404/stats

**Note:** The LB is for simple single-key operations and read distribution. Clients that need full cluster semantics (multi-key, `MOVED` handling) should connect directly to nodes with `-c` flag.

## Scaling

Scale up adds nodes in master+replica pairs:

```bash
./scripts/scale-up.sh     # Adds nodes 7 & 8, rebalances slots to 4 masters
./scripts/scale-up.sh     # Adds nodes 9 & 10, rebalances to 5 masters
```

Scale down removes the last-added pair:

```bash
./scripts/scale-down.sh   # Drains slots from last master, removes pair
```

HAProxy is automatically updated on scale events. Scaled nodes are tracked in `docker-compose.override.yml` (gitignored).

## Multi-Server Deployment

Deploy across multiple machines using `cluster-announce-ip/port`. No Docker Swarm needed.

### 1. Configure servers

Copy `multi-server/servers.conf.example` to `multi-server/servers.conf` and edit:

```
# Place a master + replica of a DIFFERENT master on each server
192.168.1.10  1,4
192.168.1.11  2,5
192.168.1.12  3,6
```

### 2. Generate per-server compose files

```bash
./scripts/generate-server-compose.sh 192.168.1.10 1,4
./scripts/generate-server-compose.sh 192.168.1.11 2,5
./scripts/generate-server-compose.sh 192.168.1.12 3,6
```

### 3. Start nodes on each server

Copy the project to each server, then:

```bash
docker compose -f docker-compose.server-192.168.1.10.yml up -d
```

### 4. Initialize the cluster

From any machine with network access to all servers:

```bash
./scripts/multi-server-init.sh
```

## Monitoring & Alerts

A Rust-based monitoring daemon runs alongside the cluster and sends notifications when issues are detected.

**What it monitors:**
- Cluster state (up/down)
- Node failures and recoveries
- Failover events (replica promoted to master)
- Memory usage exceeding threshold
- Nodes joining or disappearing

**Notification channels:**

| Channel | Config | Description |
|---|---|---|
| Email | `SMTP_*` vars | SMTP with TLS support |
| Discord | `DISCORD_WEBHOOK_URL` | Rich embeds with color-coded severity |
| Webhook | `WEBHOOK_URL` | Generic POST with JSON payload |

Enable via `./setup.sh` or set `MONITOR_ENABLED=true` in `.env`:

```bash
MONITOR_ENABLED=true
MONITOR_INTERVAL=10              # Check every 10 seconds
MONITOR_MEMORY_THRESHOLD=80      # Alert at 80% memory usage

# Discord example
DISCORD_ENABLED=true
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...

# Email example
SMTP_ENABLED=true
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_FROM=alerts@example.com
SMTP_TO=team@example.com
```

The monitor uses **alert deduplication** — it sends one alert per issue and a recovery notification when resolved. No spam.

View monitor logs: `docker logs redis-monitor`

## Failover Test

```bash
docker stop redis-node-1        # Kill a master
sleep 10                         # Wait for failover
./scripts/status.sh              # Replica promoted to master
docker start redis-node-1       # Old master rejoins as replica
```

## Configuration

Run `./setup.sh` to reconfigure, or edit `.env` directly:

```
REDIS_VERSION=7.4                # Redis image version
REDIS_PASSWORD=                  # Redis auth password
CLUSTER_NODE_TIMEOUT=5000        # Failover detection (ms)
REDIS_MAXMEMORY=                 # Per-node memory limit (e.g. 256mb)
HAPROXY_WRITE_PORT=6380          # LB write endpoint
HAPROXY_READ_PORT=6381           # LB read endpoint
HAPROXY_STATS_PORT=8404          # LB stats dashboard
```

After editing `.env`, regenerate `redis.conf` by running `./setup.sh` or restart with `./scripts/restart.sh`.
