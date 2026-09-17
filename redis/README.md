# Redis Shared Infrastructure — Production Deployment

## Quick Start

```bash
cd redis   # from the repo root

# 1. Review .env (passwords are pre-generated)
cat .env

# 2. Deploy
docker compose --env-file .env up -d

# 3. Verify
docker compose ps
docker exec redis redis-cli -a $REDIS_ADMIN_PASSWORD ping
```

## Access

| Method | Endpoint | Use Case |
|--------|----------|----------|
| Local (Docker) | `redis:6379` | Applications in `platform-redis` network |
| Localhost (Tunnel) | `127.0.0.1:6379` | Cloudflare Tunnel / Tailscale |
| Direct (Tailscale) | `<tailscale-ip>:6379` | Direct Tailscale access |

## API Keys (Multi-Project)

| User | Password | Namespace | Permissions |
|------|----------|-----------|-------------|
| `admin` | `sk_admin_K7x9mP2qR5vY8wE4zL1nM3bV6cX9pQ2rT7yU0iO5aS8dF1gH4jK6lZ3` | `*` | Full (minus dangerous) |
| `project-a` | `sk_proj_a_m9nB3vC5xZ8qW2eR4tY7uI1oP6aS3dF8gH5jK7lZ9xC2vB4n` | `project-a:*` | Read/Write |
| `project-b` | `sk_proj_b_p7qW9eR2tY5uI8oP1aS4dF7gH0jK3lZ6xC9vB2nM5qW8eR1` | `project-b:*` | Read/Write |
| `project-c` | `sk_proj_c_a4sD7fG1hJ0kL3zX6cV9bN2mQ5wE8rT2yU5iO1pA4sD7fG0` | `project-c:*` | Read/Write |
| `project-d` | `sk_proj_d_z3xC6vB9nM2qW5eR8tY1uI4oP7aS0dF3gH6jK9lZ2xC5vB8` | `project-d:*` | Read/Write |
| `project-e` | `sk_proj_e_m6nB9qW3eR0tY7uI1oP4aS8dF2gH5jK8lZ1xC4vB7nM0qW9` | `project-e:*` | Read/Write |
| `readonly` | `sk_ro_p2qW5eR8tY1uI4oP7aS0dF3gH6jK9lZ4xC7vB1nM5qW8eR2tY4` | `*` | Read Only |

**Usage:** `redis-cli -u redis://user:password@host:6379`

## Key Naming Convention

```
project-a:cache:key
project-a:session:user:123
project-b:cache:key
project-b:queue:jobs
```

## Operations

### Manual Backup
```bash
./scripts/backup.sh
```

### Restore
```bash
./scripts/restore.sh ./snapshots/dump-20260818-030000.rdb
```

### Manual Snapshot
```bash
docker exec redis redis-cli -a $REDIS_ADMIN_PASSWORD --rdb /snapshots/dump-manual.rdb
```

### Monitor
```bash
# Real-time stats
docker exec redis redis-cli -a $REDIS_ADMIN_PASSWORD INFO stats

# Memory
docker exec redis redis-cli -a $REDIS_ADMIN_PASSWORD INFO memory

# Slowlog
docker exec redis redis-cli -a $REDIS_ADMIN_PASSWORD SLOWLOG GET 10

# Clients
docker exec redis redis-cli -a $REDIS_ADMIN_PASSWORD CLIENT LIST
```

## Health Check
```bash
docker exec redis redis-cli -a $REDIS_ADMIN_PASSWORD ping
# Returns: PONG
```

## Configuration

Key settings in `config/redis.conf`:
- `maxmemory 1536mb` — Hard limit
- `maxmemory-policy volatile-lru` — Evict TTL keys only
- `save 900 1 / 300 10 / 60 10000` — RDB snapshots
- `appendonly no` — AOF DISABLED (HDD mitigation)
- ACL file: `config/users.acl`

## Security

- Binding: `127.0.0.1:6379` (no public exposure)
- Network: `platform-redis` (internal Docker network)
- Authentication: ACL-based (no default user)
- Dangerous commands renamed to empty string
- Read-only root filesystem
- Dropped capabilities: ALL
- No new privileges

## Backup

- **Automatic**: Daily 03:00 UTC via `redis-backup` sidecar (profile: backup)
- **Retention**: 7 daily snapshots
- **Location**: `./snapshots/`
- **Remote**: Configure S3/R2 in backup script

```bash
# Deploy with backup
docker compose --profile backup up -d
```

## Restore Test (Monthly)

```bash
./scripts/restore.sh ./snapshots/dump-20260818-030000.rdb
```

## Migration to SSD (When Available)

```bash
# 1. Mount SSD at /srv/platform/redis
# 2. Update .env:
#    REDIS_DATA_HOST=/srv/platform/redis/data
#    REDIS_SNAPSHOTS_HOST=/srv/platform/redis/snapshots
# 3. Migrate:
docker compose stop redis
rsync -a ./data/ /srv/platform/redis/data/
rsync -a ./snapshots/ /srv/platform/redis/snapshots/
docker compose up -d

# 4. Enable AOF for durability (edit redis.conf):
#    appendonly yes
#    appendfsync everysec
```

## ⚠️ Current Limitations (HDD)

- **AOF Disabled**: No append-only file (would kill HDD IOPS)
- **RDB Only**: Daily snapshots, up to 24h data loss for cache
- **No Durable State**: Do NOT store unrecoverable data
- **SSD Required** for production durable workloads
