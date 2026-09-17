# Neo4j Enterprise — Production Deployment

Graph database service running **Neo4j Enterprise** (`neo4j:2026.06.0-enterprise`) with HTTPS + TLS-required Bolt, Docker-secret-based auth, Prometheus metrics, and an online-backup workflow. This is the most complex service in the stack — TLS is mandatory (no plaintext Bolt/HTTP fallback for driver traffic), and credentials are never passed as a plain environment variable.

---

## Quick Start

```bash
cd /docker/Data-Infrastructure-Stack/neo4j-production

# 1. Copy the example environment file and adjust for the host
cp .env.example .env
nano .env   # set NEO4J_ACCEPT_LICENSE_AGREEMENT, memory sizing, binds

# 2. Run the init script — creates secret, generates self-signed certs,
#    pulls the pinned image, and starts the container
bash scripts/init.sh

# 3. Verify
docker compose ps
docker compose logs -f neo4j          # watch startup, Ctrl+C when healthy
curl -sk https://127.0.0.1:7473/      # HTTPS root (expect HTTP 400 — that's normal, see Troubleshooting)
wget -qO- http://127.0.0.1:2004/metrics | head   # Prometheus metrics (healthcheck target)
```

`scripts/init.sh` is idempotent — safe to re-run. It only creates the secret and certificates if they don't already exist, then always does `docker compose pull && docker compose up -d`.

### What `init.sh` does, step by step

| Step | Action | Idempotent? |
|---|---|---|
| 1 | `mkdir -p data logs import plugins backups` | Yes |
| 2 | Generate `secrets/neo4j_auth` (`neo4j/<random-48-byte-base64-password>`) if missing | Yes — skipped if file exists |
| 3 | Generate self-signed CA + Bolt/HTTPS certs via `scripts/generate-certs.sh` if `certificates/bolt/public.crt` is missing | Yes — skipped if cert exists |
| 4 | `docker compose pull` (pulls the image pinned in `.env` → `NEO4J_IMAGE`) | Yes |
| 5 | `docker compose up -d` | Yes |

---

## Network Access & Ports

| Port | Protocol | Purpose | Bind (`.env`) | Notes |
|---|---|---|---|---|
| `7473` | HTTPS | Neo4j Browser / HTTP API over TLS | `NEO4J_HTTPS_BIND` (default `0.0.0.0`) | Primary web/API access |
| `7687` | Bolt (TLS required) | Driver connections (cypher-shell, app drivers) | `NEO4J_BOLT_BIND` (default `0.0.0.0`) | `server.bolt.tls_level=REQUIRED` — plaintext `bolt://` will be rejected, use `bolt+s://` |
| `7474` | HTTP | Plain HTTP, for Cloudflare Tunnel ingress only | `NEO4J_HTTP_BIND` (default `0.0.0.0`) | Terminate TLS at the tunnel/proxy if you route through this port; do **not** expose it directly to the internet |
| `2004` | HTTP | Prometheus metrics (`/metrics`) | `NEO4J_METRICS_BIND` | Used by the container healthcheck — keep bound to `127.0.0.1` unless you have a scraper that needs remote access |
| `6362` | Backup protocol | Online (hot) backup service | internal only (not published in `docker-compose.yml`) | Reached via `docker exec`, not published to the host |

> The root README documents `7473/7687/2004/7474` as the stack-level exposure for this service — see [`../README.md`](../README.md#stack-overview).

### Cloudflare Tunnel / external routing

`config/neo4j.conf` advertises a public hostname for cluster/routing purposes even though this is a single-instance deployment:

```conf
server.bolt.advertised_address=bolt-neo4j.ostechnologies.in:443
server.cluster.advertised_address=bolt-neo4j.ostechnologies.in:443
server.routing.advertised_address=bolt-neo4j.ostechnologies.in:443
```

This tells Bolt drivers connecting through the tunnel to route back through `bolt-neo4j.ostechnologies.in:443` instead of the container's internal address. If you deploy this stack under a different domain, update these three lines (and regenerate certificates with matching SANs — see below) before going live.

---

## TLS Certificates

TLS is **not optional** here: `dbms.ssl.policy.bolt.enabled=true`, `dbms.ssl.policy.https.enabled=true`, and `server.bolt.tls_level=REQUIRED` are all set in `config/neo4j.conf`. The container will not accept plaintext Bolt traffic.

### Self-signed certs (default / dev)

`scripts/generate-certs.sh` creates a private CA and issues Bolt + HTTPS leaf certs signed by it:

```bash
bash scripts/generate-certs.sh
```

This produces:

```
certificates/
├── ca/ca.crt, ca.key             # private CA (keep ca.key off any shared host)
├── bolt/private.key, public.crt  # Bolt TLS cert
└── https/private.key, public.crt # HTTPS TLS cert
```

SANs baked into the generated certs: `DNS:neo4j.example.com, DNS:localhost, IP:127.0.0.1`. **Edit the `SAN_EXTFILE` block in `scripts/generate-certs.sh` to match your real hostname** (e.g. `bolt-neo4j.ostechnologies.in`) before regenerating for anything beyond local testing — clients doing hostname verification against the advertised address will otherwise fail TLS handshake.

### Production certs (trusted CA)

Self-signed certs mean every client must trust the private CA explicitly (`--insecure` in curl, custom trust store in drivers). For a real production rollout:

1. Obtain a certificate (e.g. via Let's Encrypt / your CA of choice) for the Bolt and HTTPS SANs.
2. Replace `certificates/bolt/{private.key,public.crt}` and `certificates/https/{private.key,public.crt}` with the issued files.
3. `docker compose restart neo4j`.

### Rotating certificates

```bash
# Certs expire after 825 days (generate-certs.sh) — rotate before expiry:
bash scripts/generate-certs.sh   # will NOT overwrite by itself; remove old certs first if regenerating
docker compose restart neo4j
```

Existing `.bak-*` files under `certificates/bolt/` and `certificates/https/` are prior rotations kept as backups (excluded from git via `.gitignore`).

---

## Authentication & Credentials

Unlike the other services in this stack, Neo4j auth is **not** passed via a plain environment variable — it's read from a Docker secret file, mounted read-only into the container and referenced by `NEO4J_AUTH_FILE`.

- **Secret file:** `secrets/neo4j_auth` (gitignored, `chmod 600`)
- **Format:** single line, `neo4j/<password>`
- **Created by:** `scripts/init.sh` on first run (`openssl rand -base64 48`)

### Retrieve the current password

```bash
cat secrets/neo4j_auth
# neo4j/<password>
```

### Change the password (after first login, or periodically)

```bash
# Via cypher-shell (requires the OLD password)
docker exec -it neo4j cypher-shell -a bolt+s://localhost:7687 -u neo4j -p '<old-password>' \
  "ALTER CURRENT USER SET PASSWORD FROM '<old-password>' TO '<new-password>';"

# Then update the secret file to match what future container restarts will expect
# for scripted/automated logins (the secret file only sets the INITIAL password —
# Neo4j persists the changed password in its own auth store afterward, so this
# step is just to keep local records/automation in sync).
printf 'neo4j/<new-password>\n' > secrets/neo4j_auth
chmod 600 secrets/neo4j_auth
```

> ⚠️ The password documented in `DoD-report.md` from the initial deployment (2026-08-17) should be treated as **compromised** since it's committed to a report file — rotate it before using this deployment for anything beyond initial verification, and consider removing/redacting the password from `DoD-report.md` in git history.

### Connect with cypher-shell

```bash
docker exec -it neo4j cypher-shell -a bolt+s://localhost:7687 -u neo4j -p '<password>'
```

### Connect with Neo4j Browser

Open `https://<host>:7473` in a browser (accept the self-signed cert warning if using dev certs), then connect with Bolt URL `bolt+s://<host>:7687`.

### Connect from an application driver

```python
from neo4j import GraphDatabase

driver = GraphDatabase.driver(
    "bolt+s://<host>:7687",
    auth=("neo4j", "<password>"),
)
```

Always use `bolt+s://` (or `neo4j+s://` for routed/cluster-aware drivers) — `bolt://` will be rejected because of `server.bolt.tls_level=REQUIRED`.

---

## Enterprise Licensing

`NEO4J_ACCEPT_LICENSE_AGREEMENT` in `.env` controls how the Enterprise image is licensed:

| Value | Meaning |
|---|---|
| `eval` | Evaluation/development use only — **current default**. Not licensed for unrestricted production use. |
| `yes` | You hold a commercial Neo4j Enterprise license and accept its terms. |

Before relying on this deployment in production long-term, procure a commercial license and switch this value, or migrate to Neo4j Community Edition if Enterprise-only features (backup service, advanced security, clustering) aren't required.

---

## Memory & Resource Tuning

Memory is set both via `.env` (passed as environment variables into the container) **and** duplicated in `config/neo4j.conf`. The `.env` example ships example values for a 32GB/8-CPU host — recalculate for the actual host before deploying:

```bash
docker run --rm -e NEO4J_AUTH=none neo4j:2026.06.0-enterprise \
  neo4j-admin server memory-recommendation --docker
```

Then update in **both** places to keep them in sync:

- `.env`: `NEO4J_server_memory_heap_initial__size`, `NEO4J_server_memory_heap_max__size`, `NEO4J_server_memory_pagecache_size`
- `config/neo4j.conf`: `server.memory.heap.initial_size`, `server.memory.heap.max_size`, `server.memory.pagecache.size`

Container-level limits (`deploy.resources.limits`) are set separately via `NEO4J_MEM_LIMIT` / `NEO4J_CPUS` in `.env` — these should be comfortably above the heap+pagecache total to leave headroom for OS/JVM overhead.

> ⚠️ **Config precedence note:** per the comments in `docker-compose.yml`, `config/neo4j.conf` (mounted read-write at `/var/lib/neo4j/conf`) is the single source of truth — the entrypoint appends env-derived settings into it at startup. If you change memory values, prefer updating both files together rather than relying on env-only overrides, since the file is authoritative for everything else (TLS, listeners, metrics, backup).

---

## Backup & Restore

Neo4j Enterprise's **online backup service** is enabled (`server.backup.enabled=true`, listening on `6362` inside the container only) so backups can be taken without stopping the database.

### Manual backup

```bash
./scripts/backup.sh
```

This:
1. Creates `backups/<YYYYMMDD-HHMMSS>/`
2. Runs `neo4j-admin database backup neo4j --to-path=/backups/<STAMP> --verbose` as the in-container `neo4j` user (uid matches database file ownership)
3. Writes `verbose.log` into the same directory
4. Prunes local backups older than 14 days
5. Prints a reminder — **off-host copies are not automated**; periodically sync `backups/` to object storage or a remote host

### Schedule via cron

```bash
# Example: nightly at 02:00
0 2 * * * cd /docker/Data-Infrastructure-Stack/neo4j-production && ./scripts/backup.sh >> backups/cron.log 2>&1
```

### Restore

⚠️ **Destructive** — restore overwrites the live database. `scripts/restore.sh` requires typing `RESTORE` to confirm.

```bash
./scripts/restore.sh 20260817-150214
```

This stops the `neo4j` container, runs `neo4j-admin database restore --from-path=/backup --to-path=/data/databases --overwrite-destination` against a temporary container mounted on the same `data` volume, then starts `neo4j` again.

To restore a **different host** (disaster recovery), copy the desired `backups/<STAMP>/` directory to the new host first, then run the same script there.

---

## Monitoring & Health Checks

### Container health check

```yaml
test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:2004/metrics || exit 1"]
interval: 30s
timeout: 10s
retries: 5
start_period: 60s
```

The healthcheck deliberately probes the Prometheus metrics endpoint (`2004`) rather than `7473` — the Neo4j image has no `curl`, only `wget`, and `wget` treats HTTPS `400` responses (which `7473`'s root path returns) as a failure even with `--content-on-error`.

```bash
docker compose ps                 # look for "Up (healthy)"
docker inspect --format='{{.State.Health.Status}}' neo4j
```

### External health probe

`scripts/healthcheck.sh` checks the HTTPS endpoint from outside the container (e.g. for an external monitoring/cron job):

```bash
bash scripts/healthcheck.sh
echo $?   # 0 = reachable, 1 = unreachable
```

### Prometheus metrics

```bash
wget -qO- http://127.0.0.1:2004/metrics | less
```

Bind this to `127.0.0.1` only (`NEO4J_METRICS_BIND=127.0.0.1`) unless a remote Prometheus scraper needs direct access — prefer joining a scraper to the host network or proxying instead of exposing `2004` publicly.

### Logs

```bash
docker compose logs -f neo4j
tail -f logs/debug.log.0*
```

---

## Plugins

The `plugins/` directory is mounted at `/plugins` and currently empty. To add APOC, Graph Data Science, or other `.jar` plugins:

```bash
# Example: APOC (match the version to the Neo4j image version)
curl -L -o plugins/apoc-<version>-core.jar \
  https://github.com/neo4j/apoc/releases/download/<version>/apoc-<version>-core.jar
docker compose restart neo4j
```

Some plugins require additional `dbms.security.procedures.unrestricted` / `unrestricted` entries in `config/neo4j.conf` — check the plugin's docs before enabling in production.

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `curl https://127.0.0.1:7473/` returns HTTP 400 | **Expected** — the HTTPS root path doesn't serve a friendly response; this is why the healthcheck uses `2004` instead. Use Neo4j Browser or a real query to confirm the DB is functioning. |
| `bolt://` connection refused / TLS error | `server.bolt.tls_level=REQUIRED` — use `bolt+s://` (or `neo4j+s://`) instead of plaintext `bolt://`. |
| Driver/browser rejects the self-signed cert | Either trust the private CA (`certificates/ca/ca.crt`) in your client, or replace the certs with ones from a trusted CA (see TLS Certificates above). |
| Container restart loop | `docker compose logs neo4j` — check for TLS cert path errors (cert/key mismatch, wrong permissions), or an invalid `neo4j.conf` edit. |
| `neo4j-admin` commands fail with permission errors | Database files are owned by the in-container `neo4j` user (uid 7474) — run admin commands with `docker exec -u neo4j neo4j ...`, not as root. |
| Backup fails with permission denied on `backups/<STAMP>/` | The backup dir needs to be writable by both the in-container `neo4j` user and the host user running the verbose log redirect — `scripts/backup.sh` already `chmod 777`s the timestamped dir; don't remove that line unless you've solved the dual-owner bind mount differently. |
| `SECURITY WARNING: allow_proxies` / `allow_hosts` in logs | Expected — `dbms.security.allow_proxies=true` and `dbms.security.allow_hosts=true` are set to support the Cloudflare Tunnel reverse-proxy setup. Ensure only the trusted tunnel/proxy can reach the container's published ports; do not expose these ports directly to untrusted networks. |
| Metrics endpoint returns nothing | Confirm `server.metrics.enabled=true` and `server.metrics.prometheus.enabled=true` are still set in `config/neo4j.conf`, and that `NEO4J_METRICS_BIND` matches how you're probing it (container-internal `127.0.0.1:2004` always works via `docker exec`, host access depends on the bind). |

---

## Known Limitations / Security Notes

Carried over from `DoD-report.md` (initial deployment verification, 2026-08-17):

- **Evaluation license**: the Enterprise image runs under `NEO4J_ACCEPT_LICENSE_AGREEMENT=eval` — not licensed for unrestricted production use without a commercial license.
- **`dbms.security.allow_proxies=true`**: trusts `X-Forwarded-*` headers — only safe because access is expected to go through a trusted reverse proxy (Cloudflare Tunnel). Don't expose the container directly to untrusted networks with this setting enabled.
- **`dbms.security.allow_hosts=true`**: accepts arbitrary `Host` headers — same mitigation as above; restrict via proxy-level `Host` validation in production.
- **No off-host backup automation**: `scripts/backup.sh` only writes locally; someone/something must periodically copy `backups/` to remote/object storage.
- **Single instance, not clustered**: the `server.cluster.*` / `server.routing.*` advertised addresses in `config/neo4j.conf` configure client-side routing behavior for Bolt drivers going through the tunnel domain — they do not mean this is a multi-member Neo4j cluster.

---

## File Locations

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Service definition |
| `.env` / `.env.example` | Environment configuration (`.env` gitignored) |
| `config/neo4j.conf` | Primary Neo4j configuration (network, TLS, memory, metrics, backup) — authoritative source |
| `config/neo4j-admin.conf`, `config/server-logs.xml`, `config/user-logs.xml` | Admin tool config and logging configuration |
| `secrets/neo4j_auth` | Initial auth credential (gitignored) |
| `certificates/` | TLS certs for Bolt and HTTPS, plus the private CA (gitignored) |
| `data/` | Database files, transaction logs, cluster state (gitignored) |
| `logs/` | Neo4j server/debug logs (gitignored) |
| `import/` | CSV/data files for `LOAD CSV` imports |
| `plugins/` | APOC / GDS / custom plugin `.jar` files |
| `backups/<timestamp>/` | Online backup artifacts + `verbose.log` (gitignored) |
| `scripts/init.sh` | First-run bootstrap (secret, certs, pull, up) |
| `scripts/generate-certs.sh` | Self-signed CA + Bolt/HTTPS cert generation |
| `scripts/backup.sh` | Online backup |
| `scripts/restore.sh` | Restore from a backup (destructive, confirmation required) |
| `scripts/healthcheck.sh` | External HTTPS reachability probe |
| `DoD-report.md` | Initial deployment verification report (checklist, known warnings) |
