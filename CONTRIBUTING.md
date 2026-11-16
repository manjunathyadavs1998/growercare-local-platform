# Contributing to GrowerCare

These rules are enforced by CI (`verify`, `pr-policy`, `claude-review`) and local git hooks. They are written down in
[SPEC-PLAT-02](https://github.com/manjunathyadavs1998/growercare/blob/main/docs/specs/platform/02-repository-governance.md) in the growercare repository.

## 1. One-time setup
```bash
scripts/install-hooks.sh          # commit-msg (Conventional Commits) + pre-push (no direct pushes to main)
cp .env.example .env              # env-only config (ADR-017); fill in local values
docker compose up -d --wait
```
You'll need Docker Desktop and Python 3. See `README.md` for the services, Debezium registration and `smoke.sh`.

## 2. Workflow: spec first, always
1. **Spec:** add or update `docs/specs/<service>/<NN>-<feature>.md`, with numbered rules, an example table, the API and the errors (skill `spec-driven-development`). New features get the spec agreed before code.
2. **Branch:** `git switch -c <type>/<short-name>`, e.g. `feat/sla-timers`, `fix/stale-etag`.
3. **Change** compose files, Keycloak realm, Postgres init scripts or Debezium connector configs.
4. **Check:** `python3 scripts/check_connectors.py` and `docker compose config -q` (CI runs both as `verify`).
5. **Verify end to end:** bring the stack and services up, run `./debezium/register.sh`, then `./smoke.sh` (exit code = failed checks). Paste the totals in the PR.
6. **Pull request:** fill in the template. The title becomes the squash commit, and the body must name the spec (`Spec: docs/specs/…`).
7. **Merge:** squash only, once all required checks are green and all conversations are resolved. The branch is deleted automatically.

## 3. Commit and PR titles: Conventional Commits
`<type>(<scope>)?: <subject>`
- **Types:** `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`, `chore`, `perf`, `revert`.
- **Breaking changes:** `feat(case)!: …` plus a `BREAKING CHANGE:` footer.
- **Scopes:** `iam`, `case`, `security`, `shard`, `common`, `outbox`, `local-dev`, `deps`, `docs`, `repo`.

## 4. Required checks on `main`
| Check | What it proves |
|---|---|
| `ci / verify` | Connector config checks and `docker compose config` for both compose files |
| `pr-policy / policy` | Title, spec reference, tests with code, branch name; self-tests of all gate scripts |
| `claude-review` | Claude Code reviews the diff against `CLAUDE.md`, the spec and the security checklist. It posts inline comments, a severity table and `review:*` labels. **Any Critical/High finding fails the check and blocks the merge.** Medium/Low are advisory |
| `codeql` | Static security analysis and dependency review |

**When `claude-review` blocks your PR:**
- **Real issue:** fix it, push, and the review re-runs.
- **False positive:** reply on the inline comment with the evidence and push a commit that makes the intent clear (a test row or comment). The check re-evaluates the new diff. Never weaken the gate.

## 5. Never
- Push to `main` directly or force-push shared branches.
- Commit secrets, real personal data, `.env` files or the take-home PDF.
- Change an applied migration, or an ADR's decision without a superseding ADR.
- Claim tests pass without running them.
