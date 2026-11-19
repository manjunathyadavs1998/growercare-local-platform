# growercare-local-platform

The shared local infrastructure every GrowerCare service runs against (ADR-017), plus the end-to-end smoke test.
Services live in their own repositories and join this platform's Docker network, **`growercare`**.

| Container | Port (host) | What |
|---|---|---|
| `gc-postgres` | 5432 | PostgreSQL 17. `postgres/01-init.sh` creates one database per service (`gc_iam`, `gc_case`), each with an owner role (migrations) and a DML-only app role; `02-cdc-role.sh` creates the Debezium role; `03-grower-db.sh` adds `gc_grower`, `04-notification-db.sh` adds `gc_notification`, `05-catalog-db.sh` adds `gc_catalog` |
| `gc-redis` | 6379 | Redis 7.4 (principal cache; never a system of record) |
| `gc-keycloak` | 8180 | Keycloak 26.8, realm `growercare` with dev users (`keycloak/growercare-realm.json`) |
| `gc-kafka` | 9094 | Kafka 4.3 (KRaft). Containers use `kafka:9092` |
| `gc-connect` | 8083 | Debezium 3.6 Kafka Connect; outbox connectors in `debezium/` |
| `gc-seaweedfs` | 8333 | S3 API for attachments (signatures enforced, `seaweedfs/s3.json`) |

## Start
```bash
cp .env.example .env                       # dev-only credentials; .env is git-ignored
docker compose up -d --wait
./debezium/register.sh                     # after the services have migrated their databases once
./keycloak/configure-registration.sh       # grower self-registration: phone-number usernames (SPEC-IAM-03), idempotent
./keycloak/configure-web-clients.sh   # web-app clients grower-web :5173, staff-console :5174 (SPEC-FE-01)
```

**Upgrading an existing stack** (init scripts and the realm import only run on an empty volume / a new realm):
- grower-service (`gc_grower` database + Keycloak client `grower-service`): add `GC_GROWER_*` from `.env.example` to `.env`, then `docker compose up -d --wait && ./apply-grower-service.sh` (idempotent).
- notification-service (`gc_notification` database + Keycloak client `notification-service`): add `GC_NOTIFICATION_*` from `.env.example` to `.env`, then `docker compose up -d --wait && ./apply-notification-service.sh` (idempotent). Add `NOTIFICATION_BASE_URL` to `services/grower-service.env`. For case notifications (SPEC-NOT-02), copy `services/notification-service.env.example` again (Kafka, contact services, service client, app links).
- catalog-registry-service (`gc_catalog` database + Keycloak clients `catalog-registry-service` and `erp-sync`): add `GC_CATALOG_*` from `.env.example` to `.env`, then `docker compose up -d --wait && ./apply-catalog-service.sh` (idempotent). Add `CATALOG_BASE_URL` to `services/case-service.env` and `catalog-registry-service` to IAM's `GC_INTERNAL_CLIENTS`; re-run `./debezium/register.sh` for the `catalog-outbox` connector.

Service ports on the host: identity-access-service 8081, case-service 8082, grower-service **8084** (8083 is Kafka Connect), notification-service 8085, catalog-registry-service 8086, **edge-gateway 8080** (the web apps' single entry point: `/api/iam`, `/api/cases`, `/api/grower`, `/api/catalog`).

**Web apps (profile `web`, SPEC-FE-04):** grower-web at http://localhost:5173 and staff-console at http://localhost:5174, the released nginx images in front of the edge gateway (so the `gateway` profile is needed too). Copy `services/grower-web.env.example` and `services/staff-console.env.example`, run `./keycloak/configure-web-clients.sh` once, and `./seaweedfs/configure-cors.sh` after `docker compose up -d --wait` (the browser uploads photos straight to the object store; only these two origins are allowed). `./smoke.sh core events grower gateway notify web` checks them, and J7 (case notifications in the dev mailbox).

**Dev mailbox (local only):** notification-service stores SMS, WhatsApp and email messages instead of sending them. Read one-time codes at `http://localhost:8085/dev/mailbox/ui?recipient=%2B919876543210` (or `/dev/mailbox?recipient=…` as JSON).

**Everything, step by step** (stack, sign-in users, one Playwright journey at a time, reset, troubleshooting): [docs/run-everything.md](docs/run-everything.md).

## Run the services
- **From their repositories (development).** Each service repository has its own `compose.yaml` and `.env.example` and attaches to the `growercare` network.
- **As released images (end to end).** Copy `services/<name>.env.example` to `services/<name>.env`, then:
  ```bash
  docker compose -f compose.services.yml up -d
  ./smoke.sh                               # exit code = failed checks (SPEC-PLAT-06 R80)
  ```

Inside the network, services reach the infrastructure by container name:
- `postgres:5432`
- `redis:6379`
- `kafka:9092`
- `keycloak:8180` (signing keys)
- `seaweedfs:8333`

Tokens are issued for `http://localhost:8180/realms/growercare`, so services validate that issuer (`OIDC_ISSUER_URI`) and fetch keys from `OIDC_JWKS_URI`.

## Running on a laptop (16 GB)
The whole stack (infrastructure plus seven services) needs about 5 GB inside Docker's VM and does not fit next to Windows,
an IDE and a browser on a 16 GB laptop. Run what you are working on and let CI run everything:

- **Profiles** (`COMPOSE_PROFILES` in `.env`; default `events,grower,catalog,gateway` = everything). Core is always on: Postgres,
  Redis, Keycloak, Kafka, SeaweedFS, identity-access-service, case-service.
  - `events`: Kafka Connect / Debezium (the heaviest container, about 400 MB).
  - `grower`: grower-service and notification-service.
  - `catalog`: catalog-registry-service.
  - `gateway`: edge-gateway (about 250 MB); smoke section `gateway` runs PRD J5/J6/J8/J9 through it (needs `grower`).
- **Smoke sections** match them: `./smoke.sh` runs all; `./smoke.sh core grower` runs a subset (`catalog` and `gateway` need `grower`).

  ```bash
  COMPOSE_PROFILES=grower docker compose up -d --wait
  COMPOSE_PROFILES=grower docker compose -f compose.services.yml up -d
  ./smoke.sh core grower
  ```
- **Everything, every night and on every PR:** `.github/workflows/e2e.yml` starts the full stack from the released images
  on a GitHub runner and runs all smoke sections.
- **Stop before closing Docker:** `docker compose -f compose.services.yml stop && docker compose stop`. After an unclean
  stop Postgres recovers with one `syncfs` (`recovery_init_sync_method`), not an fsync per file.
- **Windows:** WSL2 keeps freed memory as cache. `autoMemoryReclaim=gradual` under `[experimental]` in
  `%USERPROFILE%\.wslconfig` returns it to Windows (restart WSL after changing it).
- **Heaps are capped:** every service runs `-Xmx256m` (case-service 384m) with serial GC; Keycloak, Kafka and Connect are
  capped in `docker-compose.yml`.

## Checks
- `python3 scripts/check_connectors.py`: Debezium connector settings (SPEC-PLAT-04).
- CI also validates both compose files and the shell scripts.

Specs and decisions: [growercare](https://github.com/manjunathyadavs1998/growercare). Dev-only values: never reuse them outside a laptop.
