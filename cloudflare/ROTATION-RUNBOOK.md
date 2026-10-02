# Cloudflare API Token — Rotation Runbook

**Status:** prepared and dry-run tested, **not yet executable unattended**. Two prerequisites
are open — see [Why this is not one paste yet](#why-this-is-not-one-paste-yet).
**Owner:** DevOps Engineer · **Prepared:** 2026-10-02 · **Issue:** RILAAA-95

---

## 1. The human step

> **What the board does, assuming no context.**
>
> 1. Go to the Cloudflare dashboard → **My Profile → API Tokens** (or **Manage Account → API
>    Tokens** if the credential is account-scoped).
> 2. Find the existing token for zone `ostechnologies.in`. **Roll** it. Do not delete it yet —
>    deleting before the swap is verified removes the rollback path.
> 3. Copy the new value.
> 4. Paste it **once**, into the Paperclip secret at path
>    `integrations/cloudflare/api-token`. That is the only place it goes.
>
> Do not paste it into an issue comment, a chat message, a file, or a terminal. One paste, one
> destination. Everything after that is scripted.

Once prerequisite **P1** below is closed, step 4 is genuinely the last human action: an agent
runs `rotate-cloudflare-token.sh --apply`, and the script reads the value from the secrets
provider, swaps every consumer, health-checks, and rolls back by itself if anything fails.

---

## 2. Two different Cloudflare credentials — do not confuse them

This is the single most important fact in this document, and it is good news.

| | **API token** (the leaked one) | **Tunnel token** |
|---|---|---|
| Where it lives | `CLOUDFLARE_API_TOKEN` env var on one container | `/etc/cloudflared/token`, root-owned `0600` |
| What it grants | DNS/API authority over the whole `ostechnologies.in` zone | permission for `cloudflared` to run tunnel `fd658971-…` |
| Who uses it | `obsidian-commerce-api` only, for programmatic DNS records | `cloudflared.service` on the host |
| Rotating it affects | that one container | every public hostname |
| **In scope here** | **yes** | **no** |

**Rotating the API token does not touch the tunnel, and therefore does not take any public
hostname down.** The 19 production hostnames are served by `cloudflared` using the *tunnel*
token, which this runbook deliberately never reads or modifies. The blast radius of the swap is
one container.

The leaked credential is nonetheless serious: `CLOUDFLARE_ZONE_NAME=ostechnologies.in` and a
zone-scoped API token can rewrite DNS for every hostname in the table below. The exposure risk
is high even though the *rotation* risk is low. That asymmetry is the argument for doing it.

---

## 3. Blast radius

### 3.1 Consumers of the API token

Enumerated from live container state on 2026-10-02, not from documentation.

| Consumer | Container | Variable | Status | What breaks on a bad swap |
|---|---|---|---|---|
| Obsidian Commerce API | `obsidian-commerce-api` | `CLOUDFLARE_API_TOKEN` | **live** (53 chars, `sha256:f7d69895…`) | programmatic DNS record creation for custom domains. The API itself still serves; only the Cloudflare-calling code path fails. |
| Doable API | `doable-api` | `CF_API_TOKEN` | **declared but empty** | nothing — the variable is set to an empty string. Not a real consumer. The script skips it and will keep skipping it until someone populates it. |

No other container, systemd unit, `.env` file, or host process holds a Cloudflare API token.
`cloudflared.service` has no `CLOUDFLARE_API_TOKEN` in its unit or environment.

**Restart order:** none required. There is exactly one live consumer and nothing depends on it
for startup. It is not a dependency of the gateway, the tunnel, or any other container.

### 3.2 Hostnames fronted by this Cloudflare account

All resolve through tunnel `fd658971-ff3f-4d85-961d-13636bc3dbe7`. **None of them are affected
by an API-token swap** — listed because the leaked token can rewrite their DNS, which is the
exposure, and because they form the verification surface.

`nexahub` · `auth` · `platform` · `pro-rilan` · `default` · `api-nexahub` · `jenkins` · `n8n` ·
`dynamic-ui` · `talentbridge` · `dur` · `obsidian` · `api-obsidian` · `api-dynoshopcy` ·
`api-equitenant` · `camofox-api` · `camofox-vnc` · `camofox-cp` · `openclaw`
(all `.ostechnologies.in`)

### 3.3 Pre-rotation baseline — read this before judging a post-swap check

`baseline/hostnames.tsv` records the HTTP status of every hostname **before** any rotation.
This matters more than it sounds: **6 of 19 hostnames are already returning 502 right now**,
with origins that are down for reasons unrelated to Cloudflare.

```
obsidian 502   api-equitenant 502   camofox-api 502
camofox-vnc 502   camofox-cp 502     openclaw 502
jenkins 403 (auth challenge — expected)
api-obsidian 404 / api-dynoshopcy 404 (routed, no root handler — expected)
```

Without this baseline, a post-rotation check would show six failing hostnames and look like
catastrophic rotation damage, triggering an unnecessary rollback. `verify-cloudflare-rotation.sh`
compares against the baseline and only reports a **regression** when a host that *was* healthy
stops being healthy.

> Those six down origins are a real availability problem, but they are **pre-existing and out of
> scope for this runbook**. They should be tracked separately.

---

## 4. Why this is not one paste yet

The task asked me to say plainly if the human step is not genuinely one paste. **It is not, yet.**
Two prerequisites are open. Both are small, and neither needs the board.

### P1 — The paste has no destination (blocking)

There is **no local encrypted secrets provider installed on this host**. `sops`, `age`, and
`pass` are all absent; `/docker/credentials/` is three plaintext `.env` files. The "local
encrypted provider" in the build-vs-buy table is an intended default that was never stood up.

The nearest thing that actually exists and is actually encrypted is the **Paperclip secrets
provider**, which this runbook adopts as the destination. It needs one setup action:

- Create the secret at `integrations/cloudflare/api-token`, and grant an `access.*` binding to
  the DevOps Engineer agent.
- Verified today that this is genuinely not yet wired: `GET /api/agents/me/secrets` returns
  `{"secrets":[]}`, and the script's `--source paperclip` path fails cleanly with
  *"is the access binding granted to this agent?"* rather than silently deploying nothing.

Until P1 lands, the only working source is the break-glass `--source file:/path` mode, which
requires a human to write the token to a `0600` file — that is a second handling step and a
second exposure, so it should be a last resort, not the plan.

### P2 — The live consumer is an unmanaged, unreproducible container (blocking for safety)

`obsidian-commerce-api` was created by Docker Compose as service `api` in project
`dynamic-ui-render` — but **that service no longer exists in the compose file**, and
`git log -S` shows it never did. The container is drifted: there is no declaration anywhere in
the repo that can recreate it.

Consequences:

- `docker compose up -d api` cannot re-apply a new token. The service is not defined.
- The container carries **77 environment variables, roughly 15 of which are other live
  secrets** — `JWT_ACCESS_SECRET`, `NEO4J_PASSWORD`, `GITHUB_APP_CLIENT_SECRET`,
  `GITHUB_WEBHOOK_SECRET`, `AI_SECRET_ENCRYPTION_KEY`, `SENTRY_AUTH_TOKEN`, and more — **whose
  only copy is Docker's container config.** There is no source file.
- So the rotation must destroy and recreate the container, reconstructing all 77 variables from
  `docker inspect`. `rotate-cloudflare-token.sh` does exactly that, snapshots everything first,
  and rolls back automatically on an unhealthy result. It works, but it is a reconstruction, not
  a redeploy.

**This is a standing risk far larger than the token itself.** If that container is ever removed
without a snapshot, ~15 production secrets are gone permanently. Restoring the `api` service to
a committed compose file, with secrets sourced from the secrets provider, is the real fix.

---

## 5. The procedure

### 5.1 Before (no credential needed)

```bash
cd /docker/Data-Infrastructure-Stack/cloudflare/scripts

# Refresh the baseline so the comparison reflects reality at rotation time.
./verify-cloudflare-rotation.sh --baseline

# Confirm the plan. Mutates nothing.
./rotate-cloudflare-token.sh --dry-run --source current   # expect: idempotent no-op
```

### 5.2 Swap

After the board completes the single paste:

```bash
./rotate-cloudflare-token.sh --dry-run    # reads the real new value, shows the plan
./rotate-cloudflare-token.sh --apply
```

`--apply` is idempotent: if every consumer already holds the target value it exits `0` having
changed nothing, so a retry after a partial failure is always safe.

### 5.3 Verify

```bash
./verify-cloudflare-rotation.sh           # exit 0 = no regression vs baseline
```

Checklist — all four must hold:

- [ ] `cloudflared.service` is `active` and reports **≥1 ready edge connection**.
- [ ] `verify-cloudflare-rotation.sh` exits `0` — **no regressions** against the baseline.
- [ ] `docker inspect -f '{{.State.Health.Status}}' obsidian-commerce-api` → `healthy`.
- [ ] The container's `CLOUDFLARE_API_TOKEN` fingerprint matches the new value and **differs**
      from `sha256:f7d69895…`:
      ```bash
      source ./lib-cfrotate.sh
      fingerprint "$(container_env_value obsidian-commerce-api CLOUDFLARE_API_TOKEN)"; echo
      ```

### 5.4 Roll back (if the new token is wrong)

The script rolls back on its own if the container fails its health check. To undo a *verified-
unhealthy* rotation manually:

```bash
./rotate-cloudflare-token.sh --rollback <snapshot-id>   # ids live in ~/.local/state/cloudflare-rotation
```

The pre-rotation container is preserved as `obsidian-commerce-api-prerotate-<stamp>`, so
rollback is a rename and a start — seconds, not a rebuild.

### 5.5 Clean up (required — do not skip)

Snapshots contain every environment variable, including the ~15 unrelated secrets from P2.

```bash
rm -rf ~/.local/state/cloudflare-rotation/<snapshot-id>
docker rm obsidian-commerce-api-prerotate-<stamp>
```

Only then delete the old token in the Cloudflare dashboard.

---

## 6. Secret-handling rules these scripts follow

- **No credential is ever printed.** Values are referenced only by truncated SHA-256 via
  `fingerprint()`. A 16-hex-char prefix of a SHA-256 over a high-entropy token is not reversible.
- **An empty value is reported as `<empty/unset>`**, never as `e3b0c442…`. That hash is the
  SHA-256 of the empty string and reads like a real fingerprint — it is how "there is no secret
  here" disguises itself as "here is a secret".
- **No credential is passed in `argv`.** `/proc/<pid>/cmdline` is world-readable, so the new
  value reaches `docker run` through a `0600` `--env-file`, which is `shred`ed afterwards.
- **Break-glass files must be `0600`/`0400`.** The script refuses to read a credential from a
  more permissive file (verified).
- **Length sanity check.** Values under 20 characters are rejected, catching a pasted zone ID,
  account ID, or truncated token — each of which would authenticate as nothing and fail silently.

### Related finding (not fixed here)

`/docker/Dynamic-UI-Render/.env` is mode **0755** (world-readable) and is **not gitignored**.
It holds no Cloudflare token today, so it is out of scope for this runbook, but it is one
`git add -A` away from being the next leak.

---

## 7. Dry-run evidence (2026-10-02)

| Test | Expected | Result |
|---|---|---|
| A. `--source current` | idempotent no-op across all consumers | ✅ both consumers `SKIP`, "idempotency confirmed" |
| B. differing value | plans an `UPDATE` for the live consumer only | ✅ `UPDATE sha256:f7d69895… → sha256:ab564e8c…`, `doable-api` skipped |
| C. `0644` token file | refuse to read | ✅ `refusing to read a credential from a non-0600 file` |
| D. 5-char value | refuse to deploy | ✅ `implausibly short (5 chars); refusing to deploy` |
| E. `--source paperclip`, no binding | fail clean, name the cause | ✅ `is the access binding granted to this agent?` |
| F. baseline capture | record 19 hostnames | ✅ written to `baseline/hostnames.tsv` |
| G. verify vs baseline | no regressions | ✅ exit `0`, "rotation is clean" |

Tests B–D used a synthetic placeholder string, never a real credential. No `--apply` was run:
this issue is preparation only.

---

## 8. Would a real rotation succeed unattended today?

**No — and the two reasons are P1 and P2, not the mechanism.**

The mechanism is ready: the swap is scripted, idempotent, self-rolling-back, and dry-run tested
end to end, against a verified baseline that prevents a false rollback. The blast radius is one
container and the tunnel is untouched.

What is missing is a destination for the paste (P1) and a safe, declarative way to re-apply
config to the one live consumer (P2). Close those two and the answer becomes yes.
