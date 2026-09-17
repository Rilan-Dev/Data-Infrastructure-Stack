# Data Infrastructure Stack

Self-hosted, Docker Compose–based data infrastructure for a single production host: relational storage, a graph database, a vector database, a message broker, and a cache/key-value store. Each service is independently deployable, independently backed up, and independently documented.

> **Host profile:** Xeon-class server, 32GB RAM, mixed HDD/SSD storage, single Docker host (no Swarm/K8s). Services are exposed either directly on `0.0.0.0` or restricted to an internal Docker network + Cloudflare Tunnel, depending on the service's security posture.

---

## Stack Overview

| Service | Image | Purpose | Exposure | Docs |
|---|---|---|---|---|
| **PostgreSQL** | `pgvector/pgvector:pg16` | Primary relational database + vector similarity search (pgvector) | `0.0.0.0:65432` → `5432` | [`PostgresSQL/`](./PostgresSQL) |
| **Neo4j** | `neo4j:2026.06.0-enterprise` | Graph database (HTTPS + Bolt only) | `7473` (HTTPS), `7687` (Bolt), `2004` (metrics), `7474` (HTTP, tunnel ingress) | [`neo4j-production/`](./neo4j-production) |
| **Qdrant** | `qdrant/qdrant:v1.12.2-unprivileged` | Vector database (multi-project, API-key scoped) | Internal network `platform-qdrant` + `127.0.0.1:6334` | [`qdrant/README.md`](./qdrant/README.md) |
| **RabbitMQ** | `rabbitmq:3.13-management-alpine` | Message broker + management UI | `0.0.0.0:5672,15672,5671,4369,25672` | [`rabbitmq/`](./rabbitmq) |
| **Redis** | `redis:7.4.1-alpine` | Cache / key-value store (ACL multi-user) | `0.0.0.0:6379` | [`redis/README.md`](./redis/README.md) |

Each service directory is **self-contained**: its own `docker-compose.yml`, `.env` (not committed), config files, backup scripts, and volumes. There is intentionally **no root-level `docker-compose.yml`** — services are started/stopped independently.

---

## Repository Structure

```
Data-Infrastructure-Stack/
├── PostgresSQL/            # PostgreSQL 16 (pgvector/pgvector:pg16) — relational DB + vector search
│   ├── docker-compose.yml
│   ├── .env.example
│   └── postgres/
│       ├── config/         # postgresql.conf
│       ├── init/           # init SQL scripts (uuid-ossp, pgcrypto, pg_trgm, hstore, citext, vector)
│       ├── backups/        # pg_dump output (gitignored)
│       └── logs/           # gitignored
│
├── neo4j-production/       # Neo4j Enterprise — graph DB
│   ├── docker-compose.yml
│   ├── DoD-report.md       # deployment verification report
│   ├── .env.example
│   ├── config/              # neo4j.conf, logging configs
│   ├── scripts/             # backup.sh, restore.sh, init.sh, healthcheck.sh, generate-certs.sh
│   ├── secrets/             # neo4j_auth (gitignored)
│   ├── certificates/        # TLS certs (gitignored)
│   ├── backups/              # online backups (gitignored)
│   └── data/ logs/ import/ plugins/   # runtime volumes (gitignored)
│
├── qdrant/                 # Qdrant — vector DB
│   ├── docker-compose.yml
│   ├── README.md            # full runbook
│   ├── config/production.yaml
│   ├── storage/ snapshots/ tmp/       # runtime volumes (gitignored)
│   └── .env.example
│
├── rabbitmq/                # RabbitMQ — message broker
│   ├── docker-compose.yml
│   ├── README.md
│   ├── .env.example
│   ├── config/rabbitmq.conf
│   ├── definitions/          # exchanges/queues/users export
│   ├── scripts/
│   └── data/ backup/          # gitignored
│
├── redis/                   # Redis — cache / KV store
│   ├── docker-compose.yml
│   ├── README.md             # full runbook
│   ├── config/                # redis.conf, users.acl, entrypoint.sh
│   ├── scripts/backup.sh restore.sh
│   ├── data/ snapshots/       # gitignored
│   └── .env.example
│
├── AGENTS.md                 # architecture & conventions reference (agents/devs)
├── .gitignore
└── README.md                 # this file
```

---

## Prerequisites

- Docker Engine 24+
- Docker Compose v2 (`docker compose`, not `docker-compose`)
- Sufficient free RAM (services collectively reserve ~10GB; see per-service resource limits)
- For Neo4j: TLS certificates (self-signed generator provided in `neo4j-production/scripts/generate-certs.sh`)

---

## Quick Start (per service)

Each service is deployed independently from its own directory:

```bash
cd <service-directory>          # e.g. cd redis
cp .env.example .env            # if an example exists — fill in real secrets
docker compose up -d
docker compose ps
```

| Service | Start command |
|---|---|
| PostgreSQL | `cd PostgresSQL && docker compose up -d` |
| Neo4j | `cd neo4j-production && docker compose up -d` |
| Qdrant | `cd qdrant && docker compose up -d` |
| RabbitMQ | `cd rabbitmq && docker compose up -d` |
| Redis | `cd redis && docker compose up -d` |

See each service's README/runbook for credentials, health checks, backup/restore procedures, and troubleshooting.

---

## Secrets & Environment Handling

- **Never commit `.env` files.** Only `.env.example` (placeholder values) is tracked in git.
- Neo4j uses a **Docker secret file** (`neo4j-production/secrets/neo4j_auth`) instead of an env var for credentials.
- Redis uses **ACL-based multi-user auth** (`redis/config/users.acl`) — passwords are injected via environment variables at container start, not hardcoded in the ACL file.
- Qdrant uses a **7-key, per-project API key scheme** — see [`qdrant/README.md`](./qdrant/README.md).
- All credential material, TLS certificates, backups, snapshots, and runtime data directories are excluded via [`.gitignore`](./.gitignore).

**Before pushing to a public remote**, always verify with a dry run:
```bash
git add -A -n | grep -viE 'compose|\.md|config|scripts|\.example'
```
This should return nothing — if it does, something sensitive may be staged.

---

## Backups

| Service | Method | Location |
|---|---|---|
| PostgreSQL | `pg_dump` (manual/cron) | `PostgresSQL/postgres/backups/` |
| Neo4j | `neo4j-admin database dump` via `scripts/backup.sh` | `neo4j-production/backups/<timestamp>/` |
| Qdrant | REST snapshot API via `qdrant-backup` sidecar (daily, 03:00) | `qdrant/snapshots/` |
| RabbitMQ | Definitions export (`rabbitmqadmin export`) | `rabbitmq/backup/` |
| Redis | `redis-cli --rdb` via `redis-backup` sidecar (daily, 03:00) | `redis/snapshots/` |

**Off-host copies are not automated** — each service's backup script/sidecar writes locally only. Periodically sync `*/backups/` and `*/snapshots/` to object storage or a remote host.

---

## Documentation Index

- [`AGENTS.md`](./AGENTS.md) — stack architecture, conventions, and guidance for AI coding agents / new contributors
- [`qdrant/README.md`](./qdrant/README.md) — Qdrant runbook (quick start, API keys, collections, quantization, monitoring, upgrade, troubleshooting)
- [`redis/README.md`](./redis/README.md) — Redis runbook (quick start, ACL credentials, key naming, backup/restore, SSD migration notes)
- [`neo4j-production/DoD-report.md`](./neo4j-production/DoD-report.md) — Neo4j deployment verification report (checklist, credentials, known warnings, operational notes)

---

## License

Internal infrastructure repository. No license specified — all rights reserved unless stated otherwise.
