# Redis HA Cluster

A Docker-based Redis Cluster with High Availability. 3 masters + 3 replicas out of the box, with HAProxy load balancing and multi-server support.

## Prerequisites

- Docker and Docker Compose

## Quick Start

```bash
./scripts/start.sh       # Start cluster + HAProxy (auto-initializes on first run)
./scripts/status.sh      # Check cluster health
```

Connect from host:

```bash
redis-cli -p 7001 -c              # Direct node access
redis-cli -p 6380                  # Write via load balancer (masters)
redis-cli -p 6381                  # Read via load balancer (replicas)
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
| `./scripts/start.sh` | Start all nodes + HAProxy. Initializes cluster on first run. |
| `./scripts/stop.sh` | Graceful shutdown. Data volumes preserved. |
| `./scripts/stop.sh --clean` | Stop and delete all data volumes (full reset). |
| `./scripts/restart.sh` | Stop then start. Data preserved. |
| `./scripts/status.sh` | Cluster state, node roles, slots, memory, and LB health. |
| `./scripts/scale-up.sh` | Add a master + replica pair. Rebalances slots. Updates HAProxy. |
| `./scripts/scale-down.sh` | Remove last-added pair. Drains slots first. Updates HAProxy. |
| `./scripts/generate-server-compose.sh` | Generate a compose file for one server (multi-server). |
| `./scripts/multi-server-init.sh` | Initialize cluster across multiple servers. |

## Load Balancer (HAProxy)

HAProxy provides single-endpoint access to the cluster:

| Endpoint | Port | Routes to |
|---|---|---|
| Write | `6380` | Masters only |
| Read | `6381` | Replicas only |
| Stats | `8404` | HAProxy dashboard |

Role detection uses `tcp-check` with `INFO replication` — no external scripts needed. On failover, HAProxy detects the role change within ~6 seconds.

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

Each node advertises its host's external IP via `--cluster-announce-ip`, so cluster gossip works across servers. Bus ports (1700X) are mapped alongside client ports (700X).

## Failover Test

```bash
docker stop redis-node-1        # Kill a master
sleep 10                         # Wait for failover
./scripts/status.sh              # Replica promoted to master
docker start redis-node-1       # Old master rejoins as replica
```

## Configuration

Edit `.env`:

```
REDIS_VERSION=7.4                # Redis image version
CLUSTER_NODE_TIMEOUT=5000        # Failover detection (ms)
HAPROXY_WRITE_PORT=6380          # LB write endpoint
HAPROXY_READ_PORT=6381           # LB read endpoint
HAPROXY_STATS_PORT=8404          # LB stats dashboard
```

Edit `redis.conf` for Redis settings. Changes take effect on next restart.
