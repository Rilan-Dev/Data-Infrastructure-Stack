# PostgreSQL 16 Production Deployment

## Quick Start

```bash
cd PostgresSQL   # from the repo root

# 1. Review and update .env (keys are auto-generated but verify)
cat .env

# 2. Deploy
docker compose up -d

# 3. Verify
docker compose ps
psql -h localhost -p 65432 -U ${POSTGRES_USER} -d ${POSTGRES_DB}
```

## Network Access

PostgreSQL is exposed on `0.0.0.0:65432` → `5432`. Connect via:

```bash
psql -h localhost -p 65432 -U ${POSTGRES_USER} -d ${POSTGRES_DB}
```

## Credentials

| Role | Username | Password | Database | Notes |
|---|---|---|---|---|
| Admin | `${POSTGRES_USER}` | `${POSTGRES_PASSWORD}` | `${POSTGRES_DB}` | Superuser |

## Extensions

The image used is [`pgvector/pgvector:pg16`](https://github.com/pgvector/pgvector) — official `postgres:16` with the `pgvector` extension precompiled — instead of vanilla `postgres:16`. This allows vector similarity search (embeddings) directly in PostgreSQL alongside relational data.

The following extensions are automatically installed at startup (see `postgres/init/01-create-extensions.sql`):

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "hstore";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "vector";
```

| Extension | Purpose |
|---|---|
| `uuid-ossp` | UUID generation functions |
| `pgcrypto` | Cryptographic functions (hashing, encryption) |
| `pg_trgm` | Trigram-based fuzzy text search/similarity |
| `hstore` | Key-value pair storage within a column |
| `citext` | Case-insensitive text type |
| `vector` (pgvector) | Vector similarity search — `vector` column type, `<->`/`<=>`/`<#>` distance operators, HNSW/IVFFlat indexes for embeddings |

### Example: using pgvector

```sql
CREATE TABLE items (
    id bigserial PRIMARY KEY,
    embedding vector(1536)
);

-- HNSW index for approximate nearest-neighbor search
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops);

-- Nearest neighbor query
SELECT id FROM items ORDER BY embedding <-> '[0.1, 0.2, ...]' LIMIT 5;
```

### Important: pgvector is automatically enabled for new databases

When you create a new database in this PostgreSQL instance, the `vector` extension will be automatically enabled. This means you can immediately start using vector similarity search in any new database without needing to manually run `CREATE EXTENSION vector`.

### For existing databases

If you have existing databases that need vector support, you can enable it by running:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

This ensures that pgvector is available for all databases in this PostgreSQL instance, making it fully accessible for normal database applications.

## Backup

Backups are performed via `pg_dump` and stored in `postgres/backups/`.

```bash
# Manual backup
./scripts/backup.sh

# Backup schedule (cron)
0 3 * * * cd /path/to/Data-Infrastructure-Stack/PostgresSQL && ./scripts/backup.sh >> postgres/backups/cron.log 2>&1
```

## Restore

```bash
# Restore from backup
./scripts/restore.sh backup.sql
```

## Monitoring

Connect to the database and run:

```sql
SELECT * FROM pg_stat_activity;
SELECT * FROM pg_stat_database;
```

## Troubleshooting

- **Connection refused**: Verify container is running (`docker compose ps`)
- **Authentication failed**: Check credentials in `.env`
- **Disk full**: Check backup retention settings

## Known Limitations

- No SSL/TLS configuration (plaintext connections only)
- No replication setup (single-node only)

---

## License

Internal infrastructure repository. No license specified — all rights reserved unless stated otherwise.
