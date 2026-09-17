# Qdrant Production Deployment — Single Developer / ≤5 Projects

## Quick Start

```bash
cd qdrant   # from the repo root

# 1. Review and update .env (keys are auto-generated but verify)
cat .env

# 2. Deploy
docker compose up -d

# 3. Verify
docker compose ps
curl -s http://localhost:6333/readyz
curl -s http://localhost:6333/collections -H "api-key: $QDRANT_API_KEY" | jq
```

## Network Access

Qdrant runs on **internal network `platform-qdrant`**. No ports exposed to host.

### For Reverse Proxy (Caddy/Nginx/Cloudflare Tunnel):
```bash
# Join reverse proxy to Qdrant network
docker network connect platform-qdrant <proxy-container>

# Proxy config example (Caddy):
# qdrant.your-domain.example.com {
#     reverse_proxy qdrant:6333
# }
```

### For Applications (same Docker host):
```bash
# Join app container to Qdrant network
docker network connect platform-qdrant <app-container>

# App connects to: http://qdrant:6333
```

## API Keys (Multi-Project)

| Key | Purpose | Collections Access |
|-----|---------|-------------------|
| `QDRANT_API_KEY` | Admin — migrations, backups, admin UI | All |
| `QDRANT_PROJECT_A_KEY` | Project A read/write | `project_a_*` |
| `QDRANT_PROJECT_B_KEY` | Project B read/write | `project_b_*` |
| `QDRANT_PROJECT_C_KEY` | Project C read/write | `project_c_*` |
| `QDRANT_PROJECT_D_KEY` | Project D read/write | `project_d_*` |
| `QDRANT_PROJECT_E_KEY` | Project E read/write | `project_e_*` |
| `QDRANT_READONLY_KEY` | Dashboards, monitoring, CI | All (read-only) |

**Collection naming convention:** `project_a_documents`, `project_b_code`, etc.

## Create Collections (Per Project)

```bash
# Project A — documents (384-dim, cosine)
curl -X PUT http://localhost:6333/collections/project_a_documents \
  -H "api-key: $QDRANT_PROJECT_A_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "vectors": { "size": 384, "distance": "Cosine", "on_disk": true },
    "optimizers_config": { "default_segment_number": 2 },
    "hnsw_config": { "m": 16, "ef_construct": 100 }
  }'

# Create payload indexes for filtering
curl -X PUT http://localhost:6333/collections/project_a_documents/index \
  -H "api-key: $QDRANT_PROJECT_A_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "field_name": "project_id",
    "field_schema": "keyword"
  }'
```

## Quantization (RAM Savings)

For collections >100K vectors, enable quantization:

```bash
curl -X PATCH http://localhost:6333/collections/project_a_documents \
  -H "api-key: $QDRANT_PROJECT_A_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "quantization_config": {
      "scalar": { "type": "int8", "quantile": 0.99, "always_ram": true }
    }
  }'
```

## Snapshots & Backup

### Manual Snapshot
```bash
curl -X POST http://localhost:6333/snapshots \
  -H "api-key: $QDRANT_API_KEY"
```

### List Snapshots
```bash
curl -s http://localhost:6333/snapshots -H "api-key: $QDRANT_API_KEY" | jq
```

### Restore Snapshot
```bash
# 1. Stop Qdrant
docker compose stop qdrant

# 2. Restore (replace storage contents)
# tar -xzf ./snapshots/<snapshot>.tar.gz -C ./storage

# 3. Start Qdrant
docker compose start qdrant
```

### Automated Backup (sidecar)
```bash
# Deploy with backup profile
docker compose --profile backup up -d qdrant-backup
```

## Monitoring

### Health Check
```bash
curl -s http://localhost:6333/readyz
curl -s http://localhost:6333/healthz | jq
```

### Prometheus Metrics (join Prometheus to network)
```bash
docker network connect platform-qdrant prometheus
# Scrape target: qdrant:6333/metrics
```

### Key Metrics to Alert On
- `qdrant_collection_vectors_count` — sudden drops
- `qdrant_request_duration_seconds` — p99 > 1s
- `qdrant_optimizer_status` — stuck indexing
- `qdrant_storage_size_bytes` — disk growth

## Resource Tuning

Current limits (adjust after benchmarking):
```yaml
mem_limit: 6g
mem_reservation: 3g
cpus: 1.5
```

Increase if:
- `oom_kill` in `docker inspect qdrant`
- High latency under load
- `htop` shows Qdrant CPU pegged

Decrease if:
- Other services starved
- RAM pressure on host

## Upgrade Procedure

```bash
# 1. Snapshot
curl -X POST http://localhost:6333/snapshots -H "api-key: $QDRANT_API_KEY"

# 2. Update version in .env
# QDRANT_VERSION=v1.13.0-unprivileged

# 3. Pull & restart
docker compose pull qdrant
docker compose up -d qdrant

# 4. Verify
curl -s http://localhost:6333/readyz
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `readyz` fails | Check logs: `docker compose logs qdrant` |
| OOM kills | Increase `mem_limit` or enable `on_disk: true` |
| Slow searches | Check `on_disk`, add payload indexes, enable quantization |
| Disk full | Prune snapshots, check `storage_path` |
| Auth errors | Verify `api-key` header matches `.env` keys |

## Security Notes

- API keys in `.env` — consider Docker secrets for production
- Network is `internal: true` — no direct Internet access
- Container runs read-only, no-new-privileges, dropped caps
- TLS terminated at reverse proxy (Cloudflare Tunnel → HTTP to Qdrant)

## File Locations

| Path | Purpose |
|------|---------|
| `./storage` | Live vector data |
| `./snapshots` | Local snapshots |
| `./tmp` | Temporary files |
| `./config/production.yaml` | Qdrant config |
| `./.env` | Secrets & config |
