# RabbitMQ Production Deployment

## Quick Start

```bash
cd rabbitmq   # from the repo root

# 1. Review and update .env (keys are auto-generated but verify)
cat .env

# 2. Deploy
docker compose up -d

# 3. Verify
docker compose ps
rabbitmqctl status
```

## Network Access

RabbitMQ is exposed on `0.0.0.0:5672,15672,5671,4369,25672`. Connect via:

```bash
# Management UI
http://localhost:15672

# CLI
rabbitmqctl status
```

## Credentials

| Role | Username | Password | Virtual Host | Notes |
|---|---|---|---|---|
| Admin | `${RABBITMQ_ADMIN_USER}` | `${RABBITMQ_ADMIN_PASSWORD}` | `/` | Superuser |

## Exchanges & Queues

The following exchanges and queues are automatically created at startup:

```bash
# List exchanges
rabbitmqctl list_exchanges

# List queues
rabbitmqctl list_queues
```

## Backup

Backups are performed via `rabbitmqadmin` and stored in `rabbitmq/backup/`.

```bash
# Manual backup
./scripts/backup.sh

# Backup schedule (cron)
0 3 * * * cd /path/to/Data-Infrastructure-Stack/rabbitmq && ./scripts/backup.sh >> backup/cron.log 2>&1
```

## Restore

```bash
# Restore from backup
./scripts/restore.sh backup.json
```

## Monitoring

Connect to the management UI and navigate to the "Overview" tab.

## Troubleshooting

- **Connection refused**: Verify container is running (`docker compose ps`)
- **Authentication failed**: Check credentials in `.env`
- **Disk full**: Check backup retention settings

## Known Limitations

- No SSL/TLS configuration (plaintext connections only)
- No clustering setup (single-node only)

---

## License

Internal infrastructure repository. No license specified — all rights reserved unless stated otherwise.
