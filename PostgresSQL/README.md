# PostgreSQL 16 Production Deployment

## Quick Start

```bash
cd /docker/PostgresSQL

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

The following extensions are automatically installed at startup:

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "hstore";
CREATE EXTENSION IF NOT EXISTS "citext";
```

## Backup

Backups are performed via `pg_dump` and stored in `postgres/backups/`.

```bash
# Manual backup
./scripts/backup.sh

# Backup schedule (cron)
0 3 * * * /docker/PostgresSQL/scripts/backup.sh
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
