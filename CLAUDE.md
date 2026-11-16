# growercare-local-platform: project guide for Claude

Local infrastructure for all GrowerCare services (ADR-017): compose files, database init scripts, the Keycloak realm, Debezium
connector configs, SeaweedFS identities and the end-to-end `smoke.sh`. There is no application code here.

## Rules
1. **Dev-only credentials** live in `.env.example` / `services/*.env.example`. Real `.env` files are git-ignored. Production secrets come from AWS Secrets Manager, never from here.
2. **Images are pinned** to exact versions. Dependabot proposes updates. Major PostgreSQL and Redis bumps are ignored (they must match AWS; SPEC-PLAT-05 R70).
3. **The `growercare` network name is a contract** with the service repositories (their compose files attach to it).
4. **A connector config change updates `scripts/check_connectors.py`** rows (SPEC-PLAT-04).
5. **`smoke.sh` is the end-to-end gate** (SPEC-PLAT-06 R80). Keep it green against `compose.services.yml`.
6. **Never commit to `main`:** branch, Conventional Commit, PR with `Spec:`, squash-merge.
