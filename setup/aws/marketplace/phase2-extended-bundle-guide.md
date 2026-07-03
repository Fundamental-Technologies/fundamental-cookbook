# Phase 2 Extended Bundle: Deploy + Validation Guide

This is the runbook for **P2-9**: end-to-end validation of the Phase 2 (DOPS-302) extended private-VPC bundle. It assumes you are already familiar with the base flow in the [Deployment Guide](deployment-guide.md) and the [Upgrade Guide](update-guide.md); this document covers only what is new or different for Phase 2.

---

## 1. What Phase 2 Adds

Phase 2 brings the customer app tier into the EKS cluster:

- The API moves off the encrypted-EC2 confidential-compute path and into the cluster, running in full-feature mode (Keycloak + Postgres + Redis on, Auth0 off).
- A new in-cluster **Keycloak** deployment, running as the sole identity provider behind a private realm.
- A new app **Postgres** cluster managed by CNPG, `ftm-main`.
- **fun-portal**, now containerized and driven by runtime config instead of build-time env vars.
- **events-handler**, now DB-backed for model listing instead of relying on the API's in-memory state.

At the end of this phase, the API Gateway and the EC2 API tier are removed entirely. Consumers reach the API directly over a PrivateLink `VpcEndpointService` fronted by the EKS-ingress NLB. Keycloak JWTs plus API keys replace API Gateway IAM auth as the authentication mechanism.

Messaging stays managed this phase: Amazon MQ and ElastiCache are unchanged.

### Version contract after Phase 2

| Component | Version | Notes |
|---|---|---|
| `templateVersion` | 2.0.0 | Unchanged from Phase 1 |
| AMI | unchanged | No new AMI for Phase 2 |
| `appBundleVersion` | 1.10.0 | New for Phase 2 |
| `fundamental-application` chart | 1.13.0 | New for Phase 2 |

---

## 2. Prerequisite: Merge + Publish Order

**The bundle cannot be built until this completes.** The `fundamental-application` umbrella chart pins ECR-published chart and image versions, so every app-repo PR below must merge to main and have its CI publish the corresponding image/chart to ECR **before** the bundle build runs. Building early means `enumerate-images.sh` and the bundle build will reference unpublished artifacts and fail (or worse, silently pin a stale tag).

Merge and publish in this order:

1. **ftm-api-service** PR #335 (app private-full mode, PLA-213) and PR #339 (P2-3 migration hook, based on #335) merge to main. CI publishes the ftm-api-service image, currently tagged `0.0.203-remove-private-deployment-99bf1f5` on the branch (note a `0.0.204` bump landed after that), plus the chart to ECR `/helm`.
2. **fun-portal** PR #201 (P2-7) merges to main. CI (a new `cd-main.yml` workflow) publishes the `fun-portal` image and chart to ECR `/helm`.
   > **Important:** fun-portal had no published chart before this. The umbrella currently pins `fun-portal` chart `0.9.0` as a forward-looking guess made before publish. After #201 merges, verify the actual published version and correct the umbrella pin in fun-k8s PR #124 if it differs.
3. **events-handler** is already published at chart/image `0.1.5`. No action needed here.
4. **fun-k8s** PR #124 merges to main. CI publishes `fundamental-application` `1.13.0` (plus the `keycloak`, `traefik` `0.3.0`, and `pg-resources` chart dependencies it pulls in). Also confirm `Chart.lock` regenerates cleanly in CI: it could not be regenerated offline during development.
5. **ec2-marketplace** PR #36: update the chart-version pins in `cf-stack/release.yaml` from the interim branch-preview tags to the clean published semver (there is an existing TODO on this tied to fun-k8s PR #121), then merge. Building the bundle via the release workflow produces the infra and app tarballs and uploads them to the producer S3 bucket.

Do not start the bundle build until all five steps above are done.

---

## 3. Deploy the Extended Bundle

The deploy flow itself is unchanged from the [Deployment Guide](deployment-guide.md). The only thing that changes for Phase 2 is the `FunAppBundleVersion` parameter: use **`1.10.0`** instead of the Phase 1 value.

The application umbrella installs as Helm release `fun-app` in the `serving` namespace, alongside the existing temporal workloads.

If you are upgrading an already-deployed Phase 1 stack rather than deploying fresh, follow the [Upgrade Guide](update-guide.md) in-place update flow, setting `FunAppBundleVersion=1.10.0` and leaving `FunInfraBundleVersion` at its current value (infra is unchanged this phase).

---

## 4. Validation Checklist

This is the core of P2-9. Work through every item before signing off on the deployment.

### Pods

- [ ] All new pods are `Running` in the `serving` namespace:
  - [ ] `keycloak` (Helm release `fun-app`)
  - [ ] CNPG `ftm-main-pg` (the app database)
  - [ ] Keycloak's own CNPG instance
  - [ ] `ftm-api-service`
  - [ ] `fun-portal`
  - [ ] `events-handler`
  - [ ] Existing `temporal` workloads are still healthy

### Migration Job

- [ ] The DB migration job (a `post-install,post-upgrade` Helm hook) completed successfully.
- [ ] `alembic_version` reports revision `0004`.
- [ ] All 7 expected tables exist:

| Table |
|---|
| `trained_models` |
| `org_api_keys` |
| `org_settings` |
| `org_api_usage` |
| `integrations` |
| `usage_events` |
| `usage_policies` |

### Keycloak

- [ ] Realm `fundamental-private` was imported exactly once (this is a post-install-only step; it is not re-imported on upgrade).
- [ ] Client `fun-portal` exists (public client).
- [ ] Client `ftm-api-service` exists (bearer-only).
- [ ] Client `ftm-api-service-sa` exists (service account).
- [ ] The service-account secret `fun-app-service-account` exists, with key `KEYCLOAK_SERVICE_CLIENT_SECRET`.

### Secrets

- [ ] `ftm-api-service-internal-jwt-secret` exists (generated in-cluster on first install, preserved across upgrades).
- [ ] `temporal-encryption-key` matches the key already in use by the on-EC2 temporal-worker. These must be equal or workflow payload decryption will fail.
- [ ] `ftm-api-service-redis`, `ftm-tasks-backend`, and `ftm-dramatiq` are populated from the managed ElastiCache and Amazon MQ endpoints.
- [ ] DB credentials are read from CNPG secret `ftm-main-pg-app` via `secretKeyRef` (not hardcoded).

### Flows

- [ ] Portal login: OIDC redirect to Keycloak succeeds, and the portal receives a valid session.
- [ ] API call using the portal-issued JWT succeeds; the API validates the JWT against the in-cluster Keycloak.
- [ ] API to Temporal on port 7233 (in-cluster) works.
- [ ] API to managed RabbitMQ (Amazon MQ) over AMQPS works.
- [ ] API to Redis over `rediss://` (ElastiCache) works.
- [ ] `events-handler` consumes the `model-events` topic and upserts rows into `trained_models`.
- [ ] `GET /model-management/trained-models` returns DB-backed results (not stale/in-memory data).

### Consumer Path

- [ ] From the consumer VPC, traffic reaches the new PrivateLink interface endpoint, then port 443 on the EKS-ingress NLB, then Traefik's `websecure` entrypoint (TLS), then the API.
- [ ] Requests are authenticated by Keycloak JWT plus API key. Confirm there is no remaining dependency on API Gateway, since it is gone in this phase.

### Upgrade

- [ ] Alembic migrations run cleanly on a version bump (test with a no-op or trivial bump if a real one is not available).
- [ ] Perform a stateful in-place upgrade and confirm no data loss.
- [ ] Exercise the delete-and-rebuild fallback (see [section 6](#6-backup-before-delete-and-rebuild)) only after taking a CNPG backup first.

---

## 5. Open Items to Resolve During P2-9

These surfaced during implementation and are not yet closed. Track each explicitly rather than assuming they are handled.

**(a) BLOCKER: portal and API Traefik routes collide.** The API and fun-portal `IngressRoute` objects both match the same `Host(<EKS-ingress NLB DNS>)`. Traefik cannot disambiguate two routes on the same host with no path distinction. Assign distinct internal hostnames to each service (or a clean path split) so both can be routed correctly.

**(b) External browser-reachable URLs and TLS.** `VITE_BASE_URL` and `VITE_OIDC_AUTHORITY` (fun-portal), and the API's external `KEYCLOAK_URL`, all currently resolve to the raw EKS-ingress NLB DNS name using Traefik's default self-signed certificate. Worse, the API's `KEYCLOAK_URL` (the browser/issuer URL used for JWT `iss` validation) is currently set to the in-cluster address `http://fun-app:8080`, which is not reachable from a browser and must be changed to the actual browser-reachable issuer URL. Fixing this requires assigning real internal hostnames and a trusted certificate, which also resolves item (a).

**(c) Redis over TLS.** The bundle uses `rediss://` because ElastiCache Serverless mandates TLS. Confirm the API actually connects over TLS in practice, not just that the connection string is correct.

**(d) Air-gap follow-up: Keycloak's wait-for-postgres image.** The keycloak chart's `wait-for-postgresql` init container image (`postgres:17`) was made configurable in keycloak chart `0.2.4`, but the umbrella still pins `0.2.2`, which defaults to a docker.io image. For a true air-gapped customer this breaks, since docker.io is not reachable. Bump the umbrella's keycloak dependency to `0.2.4` and point `waitForPostgres.image` at a registry-mirrored image that is included in the bundle.

**(e) Temporal encryption key is now per-deployment.** It is generated as an AWS Secrets Manager secret (`GenerateSecretString`) and fed to both the in-cluster API and the EC2 temporal-worker, replacing the old all-zero default key. Validate that the worker can still decrypt workflow payloads with the new per-deployment key.

**(f) PrivateLink principals are same-account only.** `VpcEndpointServicePermissions.AllowedPrincipals` is currently set to the same-account root, which is fine while consumers are same-account. For cross-account consumers this must be set to their real account principals before go-live.

**(g) Stale docs referencing the removed API Gateway.** `customer-setup-guide.md` and `fundamental-setup-instructions.md` still reference API Gateway outputs that no longer exist post-Phase-2. These need updating. Note that the orphan API-tier parameters (`ApiInstanceType`, `ApiDesiredCapacity`, `ApiS3Path`) were left in the template intentionally, so existing customer parameter files do not break on upgrade.

**(h) Start-ordering: events-handler may race the migration.** On a first install, `events-handler` may start before the migration job has created `trained_models`. This self-heals via Dramatiq redelivery combined with an idempotent `ON CONFLICT DO NOTHING` insert, but it is worth confirming this behavior during validation rather than assuming it.

---

## 6. Backup Before Delete-and-Rebuild

Delete-and-rebuild is the Phase 1 fallback upgrade path, and it destroys PVCs, including Keycloak's realm state and the app database. **Never run it without a fresh backup.**

Before triggering a delete-and-rebuild:

1. Take a CNPG backup of `ftm-main-pg` using the `pg-resources` chart's backup mechanism (`ScheduledBackup`, or trigger an on-demand `Backup` object against the same cluster). Confirm the backup completes and lands in the configured backup destination before proceeding.
2. Note the backup name/timestamp so you can identify it for restore.
3. Proceed with the delete-and-rebuild as described in the [Upgrade Guide](update-guide.md).
4. After the rebuild, restore from the backup taken in step 1 using CNPG's standard restore flow (a new `Cluster` object with a `bootstrap.recovery` section pointing at the backup).

Migrations are forward-only and backward-compatible by design, so even without a restore the rebuilt database re-migrates to head cleanly. The backup exists to preserve customer data (trained models, API keys, org settings, usage history), not schema state.

---

## Related guides

- [Deployment Guide](deployment-guide.md): base install flow, prerequisites, and stack verification.
- [Upgrade Guide](update-guide.md): in-place update mechanics and the delete-and-rebuild fallback referenced in section 6.
