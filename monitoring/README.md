# Platform Monitoring — Prometheus / Alertmanager / Grafana

Self-hosted observability for the platform. Today it watches one thing closely:
the **Paperclip GitHub credential broker**, which failed silently for three days
in RILAAA-75 and blocked every unattended engineer heartbeat from committing.
This stack is the detection that should have caught it (RILAAA-81).

No new recurring spend. Every image is one we already run or pull for free, and
every host port is bound to `127.0.0.1`.

---

## Services

| Service | Container | Image | Local URL |
|---|---|---|---|
| Prometheus | `platform-prometheus` | `prom/prometheus:v3.5.0` | http://127.0.0.1:9490 |
| Alertmanager | `platform-alertmanager` | `prom/alertmanager:v0.28.1` | http://127.0.0.1:9493 |
| Grafana | `platform-grafana` | `grafana/grafana:12.1.1` | http://127.0.0.1:3090 |
| Identity exporter | `paperclip-identity-exporter` | `prometheuscommunity/postgres-exporter:v0.17.1` | internal only, `:9187` |

Nothing is published beyond loopback. To reach Grafana from another machine, use
an SSH tunnel (`ssh -L 3090:127.0.0.1:3090 <host>`) or add it to the Cloudflare
Tunnel — do not change the port binding to `0.0.0.0`.

**Dashboard:** Grafana → *Platform* folder → **Paperclip Credential Broker**
(`/d/paperclip-credential-broker`). It is file-provisioned from
`grafana/dashboards/`, so edit the JSON in git rather than the UI; UI edits are
disabled and would be overwritten anyway.

---

## Quick start

```bash
cd /docker/Data-Infrastructure-Stack/monitoring

cp .env.example .env && chmod 600 .env
$EDITOR .env                          # set GRAFANA_ADMIN_PASSWORD

./scripts/provision-metrics-role.sh --rotate   # creates paperclip_metrics_ro
./scripts/verify-readonly.sh                   # MUST pass before going further
./scripts/provision-alert-email.sh             # paste the Resend API key

docker compose up -d
./scripts/test-rules.sh                        # promtool lint + unit tests
./scripts/send-test-alert.sh                   # prove a notification arrives
```

`docker compose ps` should show all four containers `healthy`.

### Rollback

```bash
docker compose down            # removes all four containers, keeps history
docker compose down -v         # also discards the TSDB and Grafana state
```

This stack creates no schema, owns no data another service reads, and writes
nothing outside `monitoring/` and its own named volumes. Rolling back is one
command with no migration and no coordination. The only external artifact is the
`paperclip_metrics_ro` Postgres role, which is read-only and harmless to leave
behind; drop it with `DROP ROLE paperclip_metrics_ro;` as `postgres` if you want
a clean slate.

---

## The signal

Paperclip records the broker's verdict for **every run** in
`run_identity_contexts` in the `paperclip` database on `postgres-db`:

```sql
select cause,
       coalesce(github->>'status','unknown') as st,
       count(*)
from run_identity_contexts
where created_at > now() - interval '15 minutes'
group by 1, 2;
```

`cause` is what woke the run. `company_default` means an **unattended** heartbeat
— the ones nobody is watching. That distinction is the whole point: during
RILAAA-75, `company_default` was 100% `unavailable` while `manual_user_wake` sat
at 100% `available`, so anyone spot-checking by hand saw a healthy system.

### Metrics

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `paperclip_identity_context_window_count` | gauge | `credential`, `cause`, `status` | Contexts in the trailing 15 min. Drives the warning alert. |
| `paperclip_identity_context_cumulative_total` | counter | `credential`, `cause`, `status` | Contexts since the table was last pruned. Drives the page and the dashboard. |
| `paperclip_identity_context_freshness_seconds` | gauge | — | Age of the newest row; `-1` if the table is empty. |

Recording rules `paperclip:identity_contexts:1h`,
`paperclip:identity_available:1h` and `paperclip:identity_availability_ratio:1h`
give the dashboard one shared definition of "availability".

### Two design decisions worth knowing before you change anything

**1. The page reads the counter, not the 15-minute gauge.** Unattended heartbeats
fire roughly every 30 minutes, so a 15-minute window is *empty about half the
time even during a total outage*. The obvious rule — `window_count > 0 for 30m` —
resets on every quiet gap and would never have paged for RILAAA-75 at all. The
paging rule therefore uses `increase(cumulative_total[35m])`, a lookback wide
enough to always span a full heartbeat cycle. `prometheus/tests/` contains a
regression test that models the real 30-minute arrival pattern; it fails if
anyone reverts to the gauge form.

**2. Quiet label combinations are reported as `0`, not omitted.** The exporter
`LEFT JOIN`s the 15-minute window against every `(cause, status)` pair the table
has ever seen. Without that, a quiet pair returns no row, the series goes stale,
and Grafana drops the line — which is the same invisibility that hid RILAAA-75
for three days. A cause with *no attempts at all* in the last hour is genuinely
excluded from the availability ratio, because availability is undefined with zero
attempts; the freshness tile is what catches global silence.

---

## Alerts

| Alert | Severity | Fires when | Notified |
|---|---|---|---|
| `PaperclipUnattendedIdentityUnavailable` | warning | Any `company_default` denial in the last 15 min | email |
| `PaperclipUnattendedIdentityUnavailableSustained` | critical | Denials and zero successes for `company_default` across 35 min | email, repeats hourly |
| `PaperclipIdentityExporterDown` | warning | Exporter unscrapeable for 10 min | email |
| `PaperclipIdentityContextsStale` | info | No identity context for over 2 h | dashboard only |
| `AlertmanagerNotificationsFailing` | warning | Delivery failing for 10 min | email (best effort) |
| `AlertmanagerUnreachable` | warning | Prometheus has no Alertmanager for 10 min | email (best effort) |

The warning has no `for` delay on purpose — the exporter's 15-minute query window
already provides all the smoothing needed, and the correct steady state after
RILAAA-75 is **zero**. An inhibition rule suppresses the warning while the
critical version of the same cause is firing.

### Runbook per alert

#### `PaperclipUnattendedIdentityUnavailable`

Unattended runs are getting no GitHub identity. They do **not** fail loudly —
they degrade to `fatal: empty ident name` on the first commit, which is easy to
misread as a git config problem in the workspace.

1. Confirm it is cause-specific, not global:
   ```bash
   docker exec postgres-db psql -U postgres -d paperclip -c "
     select cause, coalesce(github->>'status','unknown') st, count(*)
     from run_identity_contexts
     where created_at > now() - interval '1 hour'
     group by 1,2 order by 1,2;"
   ```
   `company_default → unavailable` with other causes `available` is the RILAAA-75
   shape.
2. Read the `reason` the broker returned:
   ```bash
   docker exec postgres-db psql -U postgres -d paperclip -c "
     select created_at, cause, github
     from run_identity_contexts
     where github->>'status' = 'unavailable'
     order by created_at desc limit 5;"
   ```
3. `"No managed GitHub identity is available for this run"` on `company_default`
   only means the **GitHub user-grant has no agent delegation**. That was the
   RILAAA-75 root cause and it is fixed on the Paperclip board, not on this host.
   Do not try to patch the grant table or call `/usr/bin/git` directly. See
   RILAAA-75.
4. The alert clears on its own once identities are handed out again — no manual
   resolve needed.

#### `PaperclipUnattendedIdentityUnavailableSustained`

Same cause, now confirmed across a full heartbeat cycle. Every unattended
engineer has lost at least one cycle of work. Escalate to whoever owns the
Paperclip GitHub connection; engineers will keep waking and failing until the
grant is fixed.

#### `PaperclipIdentityExporterDown`

We are blind, which is worse than a known outage. Almost always one of:

```bash
docker compose ps paperclip-identity-exporter
docker logs --tail 50 paperclip-identity-exporter
```

- `password authentication failed` → the role password and `.env` drifted. Re-run
  `./scripts/provision-metrics-role.sh` (no `--rotate`) to push the `.env` value
  back onto the role, then `docker compose restart paperclip-identity-exporter`.
- `connection refused` / `no such host` → `postgres-db` is down, or the
  `postgressql_postgres_network` external network was recreated. Restart the
  exporter after Postgres is healthy.
- `permission denied for table` → someone changed the grant. Run
  `./scripts/verify-readonly.sh`; it will say exactly which check broke.

#### `PaperclipIdentityContextsStale`

No run of any kind for two hours. Unattended heartbeats should produce one every
30 minutes, so either the Paperclip control plane is stopped or every agent is
paused. **While this is firing, the broker alerts above are silent for lack of
data, not for lack of a problem** — do not read a quiet dashboard as healthy.

#### `AlertmanagerNotificationsFailing`

Alerts are firing and nobody is being told. Check the reason:

```bash
docker logs --tail 50 platform-alertmanager | grep err=
```

- `missing password for PLAIN auth mechanism` → the Resend API key was never
  installed. Run `./scripts/provision-alert-email.sh`.
- `permission denied: /etc/alertmanager/secrets/smtp_password` → the secret file
  is not readable by uid 1000. `chmod 600` it and confirm it is owned by the user
  that owns this directory; Alertmanager deliberately runs as `1000:1000` for
  this reason.
- `535` / `Invalid API key` → the key was revoked or the sending domain
  (`info.ostechnologies.in`) is no longer verified in Resend.

Note the counter only moves once Alertmanager exhausts its retries, so this alert
trails the first failed attempt by several minutes.

#### `AlertmanagerUnreachable`

Rules are evaluating with nowhere to send results.

```bash
docker compose ps alertmanager
curl -s http://127.0.0.1:9490/api/v1/alertmanagers | python3 -m json.tool
```

---

## Secrets

Two credentials, neither of which appears in any committed file:

| Credential | Lives in | Used by |
|---|---|---|
| `paperclip_metrics_ro` password | `.env` (mode 600, gitignored) | exporter, via `DATA_SOURCE_PASS` |
| Resend API key | `alertmanager/secrets/smtp_password` (mode 600, gitignored) | Alertmanager, via `smtp_auth_password_file` |
| Grafana admin password | `.env` (mode 600, gitignored) | Grafana, via `GF_SECURITY_ADMIN_PASSWORD` |

Both paths are covered by the repository `.gitignore` (`*.env` and
`**/*secret*`); `git check-ignore -v` confirms it. The provisioning scripts pipe
secrets through stdin or temp files and never pass them as arguments, so they do
not appear in `ps`, in shell history, or in the Docker daemon's command log.
`alertmanager.yml` and the dashboard JSON are committable precisely because
neither contains a credential.

**Rotation.** Both are safe to rotate at any time; neither is shared with another
service.

```bash
./scripts/provision-metrics-role.sh --rotate     # new DB password, applied atomically
docker compose restart paperclip-identity-exporter
./scripts/verify-readonly.sh

./scripts/provision-alert-email.sh               # new Resend key
docker compose restart alertmanager
./scripts/send-test-alert.sh
```

---

## Least privilege

`paperclip_metrics_ro` may do exactly one thing: `SELECT` on
`public.run_identity_contexts`. It has no `SUPERUSER`, `CREATEDB`, `CREATEROLE`,
`REPLICATION` or `BYPASSRLS`, a connection limit of 4, and not one other table
grant anywhere on the cluster. This is why the exporter runs with
`--disable-default-metrics --disable-settings-metrics`: the standard collectors
read `pg_stat_*` and `pg_settings` and would force us to grant `pg_monitor`.

`./scripts/verify-readonly.sh` asserts all of that — 15 checks covering the
permitted `SELECT`, every write verb, reach into other tables and other
databases, role attributes, and the exact grant list. **Re-run it after any
change to `create-metrics-role.sql`.** A grant that was never tested is not
verified.

One honest caveat it encodes rather than hides: PostgreSQL grants `CONNECT` on
most databases to `PUBLIC`, and a per-role `REVOKE` does not override that. The
role can therefore *open* a connection to another database on the cluster. It
holds no table, sequence, function or schema-`CREATE` privilege there, so it can
read and write nothing — and the script proves that instead of pretending the
connection itself is blocked.

---

## Testing

```bash
./scripts/test-rules.sh        # promtool check config + check rules + test rules
```

`prometheus/tests/` holds the unit tests. They cover the RILAAA-75 shape, the
30-minute-gap regression, automatic resolution when the broker recovers, exporter
loss, control-plane silence, and both alerting-pipeline failures. Add a case
before changing a threshold — the tests exist because two of the rules in here
were wrong in ways that only a test modelling real arrival timing catches.

`./scripts/send-test-alert.sh` covers what promtool cannot: whether a
notification actually leaves the host.

---

## Adding a second credential source

`run_identity_contexts` currently carries one jsonb column, `github`. The metrics
are already labelled `credential="github"` so a second source is additive, not a
rename:

1. Add a `UNION ALL` branch to each query in
   `postgres-exporter/queries.yaml`, selecting `'<name>' AS credential` and the
   new column's `->> 'status'`.
2. `docker compose restart paperclip-identity-exporter`.

The existing alert rules and dashboard pick it up automatically — the rules match
on `cause`, not on `credential`, and the dashboard has a `credential` template
variable.

---

## Adding another scrape target

Prometheus currently scrapes only itself, Alertmanager, and the identity
exporter. To add a service, append a `scrape_config` to
`prometheus/prometheus.yml`, put its alerts in a new
`prometheus/rules/<subject>.rules.yml` with a matching
`prometheus/tests/<subject>.test.yml`, then:

```bash
./scripts/test-rules.sh
curl -X POST http://127.0.0.1:9490/-/reload
```

`--web.enable-lifecycle` is on, so rule and config changes need a reload, not a
restart. Reachability matters: the target must be on the `monitoring` network, or
you must attach the relevant external network to Prometheus the way the exporter
attaches to `postgressql_postgres_network`.

---

## Retention and backup

Prometheus keeps 30 days in the `monitoring_prometheus_data` volume — enough to
review a multi-day outage after the fact. This is **derived, reconstructible
data**: every number in it comes from `run_identity_contexts`, which is backed up
as part of the Postgres backup. It is deliberately not in the backup rotation.

What *is* worth protecting is configuration, and all of it — compose file, rules,
tests, dashboard JSON, provisioning, scripts — is in git. The only unversioned
state is the two secrets, which are rotatable in seconds using the commands
above. Losing this host's volumes costs 30 days of graphs, not any ability to
rebuild the stack or re-detect an outage.

---

## Related

- **RILAAA-75** — the outage itself (no managed GitHub identity for agent runs).
- **RILAAA-81** — this work: the detection that should have caught it.
- `../PostgresSQL/` — the `postgres-db` instance this exporter reads.
