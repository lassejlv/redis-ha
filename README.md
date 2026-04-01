# Redis HA Cluster

A Docker-based Redis Cluster with High Availability. 3 masters + 3 replicas out of the box, with scripts to manage the full lifecycle.

## Prerequisites

- Docker and Docker Compose

## Quick Start

```bash
./scripts/start.sh       # Start cluster (auto-initializes on first run)
./scripts/status.sh      # Check cluster health
```

Connect from host:

```bash
redis-cli -p 7001 -c
```

Ports `7001`-`7006` map to the 6 nodes.

## Scripts

| Script | Description |
|---|---|
| `./scripts/start.sh` | Start all nodes. Initializes the cluster on first run, rejoins on subsequent runs. |
| `./scripts/stop.sh` | Graceful shutdown. Data volumes are preserved. |
| `./scripts/stop.sh --clean` | Stop and delete all data volumes (full reset). |
| `./scripts/restart.sh` | Stop then start. Data preserved. |
| `./scripts/status.sh` | Show cluster state, node roles, slot distribution, and memory usage. |
| `./scripts/scale-up.sh` | Add a master + replica pair. Automatically rebalances hash slots. |
| `./scripts/scale-down.sh` | Remove the last-added pair. Drains slots before removal. Minimum 6 nodes enforced. |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Docker Bridge Network                │
│                                                     │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐            │
│  │ Master 1 │  │ Master 2 │  │ Master 3 │           │
│  │ :7001    │  │ :7002    │  │ :7003    │           │
│  │ 0-5460   │  │ 5461-10922│ │10923-16383│          │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘          │
│       │              │              │                │
│  ┌────▼─────┐  ┌────▼─────┐  ┌────▼─────┐          │
│  │ Replica 4│  │ Replica 5│  │ Replica 6│           │
│  │ :7004    │  │ :7005    │  │ :7006    │           │
│  └──────────┘  └──────────┘  └──────────┘           │
└─────────────────────────────────────────────────────┘
```

- **16384 hash slots** distributed across masters
- Each master has a replica for automatic failover
- `cluster-require-full-coverage no` — cluster stays available during partial failures
- AOF + RDB persistence via named Docker volumes

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

Scaled nodes are tracked in `docker-compose.override.yml` (gitignored).

## Failover Test

```bash
docker stop redis-node-1        # Kill a master
sleep 10                         # Wait for failover
./scripts/status.sh              # Replica promoted to master
docker start redis-node-1       # Old master rejoins as replica
```

## Configuration

Edit `.env` to change the Redis version:

```
REDIS_VERSION=7.4
```

Edit `redis.conf` for Redis settings. Changes take effect on next restart.
