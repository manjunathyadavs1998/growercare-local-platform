# Run everything locally

How to run GrowerCare end to end on a laptop: infrastructure, services, both web apps, the smoke test and the
Playwright journeys (SPEC-FE-04). **CI runs the whole thing** (`.github/workflows/e2e.yml`: every profile, `smoke.sh`,
then all journeys). A laptop runs **one journey at a time**, with only the profiles that journey needs: the full stack
plus a browser does not fit next to an IDE on a 16 GB machine.

## 1. What you need
- Docker Desktop with at least 8 GB for its VM (Windows: `%LOCALAPPDATA%/Programs/DockerDesktop/resources/bin` holds the CLI).
- Git Bash (Windows) or any POSIX shell, `curl`, Python 3 (`python`).
- For the journeys: Node 24 and pnpm (`corepack enable`), and the `growercare-frontend` repository next to this one.

## 2. Start the stack
```bash
cd growercare-local-platform
cp .env.example .env                                   # dev-only values
for f in services/*.env.example; do cp "$f" "${f%.example}"; done

export COMPOSE_PROFILES=grower,gateway,web             # pick from the table in §4 (default in .env: everything)
docker compose up -d --wait                            # Postgres, Redis, Keycloak, Kafka, SeaweedFS (+ Kafka Connect with "events")
./keycloak/configure-registration.sh                   # J1: growers sign up with their phone number
./keycloak/configure-web-clients.sh                    # the grower-web and staff-console clients
./seaweedfs/configure-cors.sh                          # the browser uploads photos to the object store (both app origins only)
docker compose -f compose.services.yml up -d           # the services and the two web apps, as released images
./debezium/register.sh                                 # only with the "events" profile (case events → notifications, J7)
```
Wait until the services answer (`curl -s localhost:8082/actuator/health`); a cold start takes 1–3 minutes.

Then check what you started: `./smoke.sh core grower gateway web` (sections must match the profiles; the exit code is
the number of failed checks).

| What | Where |
|---|---|
| grower-web | http://localhost:5173 |
| staff-console | http://localhost:5174 |
| Keycloak (realm `growercare`) | http://localhost:8180 (admin: `KEYCLOAK_ADMIN` in `.env`) |
| Dev mailbox (SMS, email: local only) | http://localhost:8085/dev/mailbox/ui?recipient=%2B919876543210 |
| Edge gateway | http://localhost:8080/api/… |

## 3. Who to sign in as
| User | Password | Is | App |
|---|---|---|---|
| `grower.in1` | `Grower#Pass1` | Ramesh Patil, grower in Pune, phone +919876543210, Marathi | grower-web |
| `grower.in2`, `grower.br1` | `Grower#Pass1` | other growers (India, Brazil) | grower-web |
| `care.in` / `care.br` | `Staff#Pass12` | care agents, India / Brazil | staff-console |
| `agro.in` | `Staff#Pass12` | Vikram Agro, field agronomist (email agro.in@growercare.test) | staff-console |
| `tm.in` | `Staff#Pass12` | territory manager (overview) | staff-console |
| `admin.in` | `Staff#Pass12` | country admin (users and grants) | staff-console |
| `retailer.in`, `retailer2.in` | `Partner#Pass1` | retailer staff (onboarding, our cases) | staff-console |

A new grower signs up on Keycloak's registration page with a phone number (`+91…`) as username; the one-time code
arrives in the dev mailbox.

## 4. One journey at a time
| Journey | Playwright file | Profiles (`COMPOSE_PROFILES`) |
|---|---|---|
| J1 sign up | `j1-sign-up.spec.ts` | `grower,gateway,web` |
| J2 assisted onboarding | `j2-assisted-onboarding.spec.ts` | `grower,gateway,web` |
| J3 farms | `j3-farms.spec.ts` | `grower,gateway,web` |
| J4 raise a case with a photo | `j4-raise-case.spec.ts` | `grower,catalog,gateway,web` |
| J5 triage and assign | `j5-triage-assign.spec.ts` | `grower,gateway,web` |
| J6 investigate and close | `j6-investigate-close.spec.ts` | `grower,gateway,web` |
| J7 notifications | `j7-notifications.spec.ts` | `events,grower,gateway,web` (+ `./debezium/register.sh`) |
| J8 grants and isolation | `j8-grants-isolation.spec.ts` | `grower,gateway,web` |
| J9 overview | `j9-overview.spec.ts` | `grower,gateway,web` |

```bash
cd ../growercare-frontend
pnpm install
pnpm --filter e2e exec playwright install chromium      # once
pnpm --filter e2e test journeys/j5-triage-assign.spec.ts
pnpm --filter e2e exec playwright show-report           # the HTML report, with a trace for a failed test
```
Journeys create their own data (fresh phone numbers and titles with a run id) and never clean up; they do not depend on
each other.

## 5. Notifications locally
notification-service runs with a **20-second batching window and no quiet hours** locally
(`services/notification-service.env`, SPEC-NOT-02 D9), so J7 finishes in seconds at any hour. Elsewhere the defaults
apply: 5 minutes, quiet hours 21:00–07:00 in the country's time zone.

## 6. Reset
- **Data only:** `docker compose -f compose.services.yml down && docker compose down -v` removes every volume
  (databases, object store, Keycloak). Start again from §2.
- **One service's image:** `docker compose -f compose.services.yml pull <service> && docker compose -f compose.services.yml up -d <service>`.
- An existing stack that predates a service or setting: the "Upgrading an existing stack" notes in the README (the
  `apply-*.sh` scripts are idempotent).

## 7. Troubleshooting
| Symptom | Cause and fix |
|---|---|
| Docker commands hang, containers stop answering | Docker Desktop's VM is out of memory. Stop what the journey does not need (smaller `COMPOSE_PROFILES`), then restart Docker Desktop. |
| A service exits at start naming missing variables | Its `services/<name>.env` is older than the image: copy the `.env.example` again (SPEC-PLAT-06 R77). |
| A service exits with a Flyway validation error | The database was migrated by a newer image and you run an older one (or the reverse): pull the latest images, or reset (§6). |
| The app shows "GrowerCare could not start" | `/config.json` is missing: the web app's `services/<app>.env` is not there. |
| Sign-in loops back to Keycloak | The Keycloak web clients are missing on an older realm: `./keycloak/configure-web-clients.sh`. |
| Photo upload fails in the browser (CORS) | `./seaweedfs/configure-cors.sh` was not run after the object store started. |
| No SMS for J7 | The `events` profile and `./debezium/register.sh` are needed: case events reach notification-service through Kafka. |
| Windows on ARM: the frontend's tests or Playwright refuse to load a native module ("Application Control policy has blocked this file") | Windows Smart App Control blocks unsigned native modules; allow them in Windows Security, or run the frontend tooling in a Linux container. CI is unaffected. |
