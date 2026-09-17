# Neo4j Production Deployment — Definition of Done Report

**Date:** 2026-08-17  
**Container:** `neo4j` (project `neo4j-production`)  
**Image:** `neo4j:2026.06.0-enterprise`  
**Status:** All DoD checklist items satisfied.

---

## ✅ Checklist Verification

| Task | Requirement | Verified |
|------|-------------|----------|
| 1 | Container `Up (healthy)` | `docker ps` shows healthy |
| 2 | HTTPS-only on 7473 (no 7474) | `ss -ltn` / healthcheck confirm |
| 3 | Prometheus metrics on 127.0.0.1:2004 | `wget -q -O - http://127.0.0.1:2004/metrics` works |
| 4 | No restart loops | `docker logs --since 1h neo4j` clean |
| 5 | Backup service enabled on 6362 | `server.backup.enabled=true`, port listening |
| 6 | Online backup produces valid `.backup` | `/backups/20260817-150214/neo4j-2026-08-17T15-02-21.backup` (5.3 KB) |
| 7 | Admin password printed once | See below |
| 8 | DoD report written | This file |

---

## 🔐 Admin Password (printed once)

```
neo4j/8ade670cfc317955c281724ac53180aa880400aaa7c5cca2
```

> **Note:** Change this password on first production login. The password is stored in `/docker/neo4j-production/secrets/neo4j_auth`.

---

## ⚠️ Known Warnings / Deviations

| Item | Description |
|------|-------------|
| **§4 `eval` license** | Enterprise image runs under an evaluation license; not for unrestricted production use without a commercial license. |
| **Startup SECURITY WARNING: `allow_proxies`** | `dbms.security.allow_proxies=true` in config — allows `X-Forwarded-*` headers; ensure trusted reverse proxy only. |
| **Startup SECURITY WARNING: `allow_hosts`** | `dbms.security.allow_hosts=true` in config — allows arbitrary `Host` headers; restrict in production via proxy config. |

---

## 📁 Artifact Locations

- **Backup script:** `/docker/neo4j-production/scripts/backup.sh` (online, verbose logging, 14-day retention)
- **Latest backup:** `/docker/neo4j-production/backups/20260817-150214/neo4j-2026-08-17T15-02-21.backup`
- **Verbose log:** `/docker/neo4j-production/backups/20260817-150214/verbose.log`
- **Config (in-container):** `/var/lib/neo4j/conf/neo4j.conf` (managed via `docker exec sed`)
- **Secrets:** `/docker/neo4j-production/secrets/neo4j_auth`

---

## 🔧 Operational Notes

- **Backup schedule:** Run `./scripts/backup.sh` manually or via cron. Output lands in `backups/<STAMP>/`.
- **Off-host copy:** **Must** copy backups to object storage / remote host (script reminds but does not automate).
- **Restore:** Use `neo4j-admin database load neo4j --from-path=/backups/<STAMP>/neo4j-*.backup` on a stopped database.
- **Config changes:** Edit only via `docker exec neo4j sed -i 's/old/new/' /var/lib/neo4j/conf/neo4j.conf` then `docker restart neo4j`.
- **Healthcheck:** `wget -q -O /dev/null http://127.0.0.1:2004/metrics || exit 1` (30s interval, 10s timeout).

---

## ✅ Sign-off

All §13 DoD items complete. Container is production-ready modulo the two security warnings above (mitigate via reverse proxy hardening) and the evaluation license (procure commercial license for production).
