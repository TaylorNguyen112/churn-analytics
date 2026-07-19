# Contributing to `churn-analytics`

Thanks for working on this project. This guide explains how to
propose a change so it flows through the CI/CD pipeline cleanly
and lands in production safely.

## Table of contents

1. [Ground rules](#ground-rules)
2. [Local setup](#local-setup)
3. [Branch naming](#branch-naming)
4. [Commit message style](#commit-message-style)
5. [Development workflow](#development-workflow)
6. [Testing locally before you push](#testing-locally-before-you-push)
7. [Opening a pull request](#opening-a-pull-request)
8. [What CI runs on your PR](#what-ci-runs-on-your-pr)
9. [Merge policy](#merge-policy)
10. [Production deploy and rollback](#production-deploy-and-rollback)
11. [Code style](#code-style)
12. [When to add tests](#when-to-add-tests)
13. [Reporting problems](#reporting-problems)

## Ground rules

- **`main` is protected.** Never push directly to `main`. Open a pull
  request from a topic branch.
- **CI must pass** before a merge. If Slim CI is red, the merge button
  stays disabled.
- **Never commit secrets.** Databricks tokens, OAuth secrets, and
  `.env` are already gitignored. Double-check `git diff` before
  pushing anything that touches `profiles.yml`, `.env.example`, or
  workflow files.
- **Bronze is read-only.** Nothing in this repo modifies Bronze tables.
- **Production data is not modified from GitHub Actions.** The
  deployment workflow compiles code and runs a non-destructive smoke
  test. Data changes come from the scheduled Databricks Workflow.

## Local setup

Follow `README.md` §"Prerequisites and setup" once:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install -r requirements-ci.txt      # sqlfluff + yamllint
cp .env.example .env                    # then fill in Databricks creds
set -a && source .env && set +a
export DBT_PROFILES_DIR=$PWD
dbt deps
dbt debug                               # confirms your connection
```

## Branch naming

Every branch starts with a category prefix followed by a short kebab
lowercase description. Include an issue or ticket ID when one exists.

```
<category>/<optional-id>-<short-description>
```

Categories and when to use them:

| Prefix       | Use for                                                             | Example                                       |
| ------------ | ------------------------------------------------------------------- | --------------------------------------------- |
| `feat/`      | New dbt model, new dimension/fact, new source, new macro            | `feat/dim-offer`                              |
| `fix/`       | Bug fix in a model, test, macro, or workflow                        | `fix/negative-monthly-charge-guard`           |
| `refactor/`  | Restructure code with no behavior change                            | `refactor/split-int-customer-monthly`         |
| `perf/`      | Performance-only change (e.g. incremental key, cluster-by)          | `perf/fct-support-event-partitions`           |
| `docs/`      | README, ADR, docstring, `docs/**` only                              | `docs/cicd-runbook-update`                    |
| `test/`      | Adding or updating dbt tests                                        | `test/dim-customer-uniqueness`                |
| `chore/`     | Housekeeping: version bumps, `.gitignore`, editor config            | `chore/bump-dbt-utils`                        |
| `ci/`        | Anything under `.github/workflows/`, `scripts/**`, `.sqlfluff`      | `ci/cache-dbt-packages`                       |
| `build/`     | Packaging, `requirements*.txt`, dev-container, Docker               | `build/pin-dbt-databricks-1-13`               |
| `hotfix/`    | Urgent production fix that must be branched from a release tag      | `hotfix/fct-fk-null-2026-07-18`               |
| `revert/`    | Revert of a previous commit or PR                                   | `revert/pr-42-add-region-column`              |

Rules:

- Lowercase only.
- Words separated by hyphens (`-`), not underscores or camelCase.
- Include an issue/ticket ID after the prefix when you have one:
  `feat/TA-123-dim-offer`.
- Keep the description under about 50 characters.
- Never use `main`, `master`, `dev`, `prod`, `production`, `release`, or
  a name starting with `ci_pr_` for a topic branch (those are reserved
  by CI/CD tooling).

Examples:

```
feat/dim-offer
feat/TA-123-add-region-to-dim-geography
fix/support-event-fanout-check
refactor/rename-etl-audit-macro
docs/onboarding-guide
ci/slim-ci-artifact-retention
hotfix/duplicate-fact-key-2026-07-18
```

## Commit message style

We use [Conventional Commits](https://www.conventionalcommits.org/) —
same categories as branch prefixes. This makes changelogs and history
easy to skim.

```
<type>(<optional scope>): <short summary in imperative mood>

<optional body: what and why, not how>

<optional footer: BREAKING CHANGE, Refs, Closes>
```

Rules:

- Subject line under 72 characters, no trailing period.
- Imperative mood: "add", "fix", "rename" — not "added", "fixes".
- Scope is optional but useful. Common scopes: `staging`,
  `intermediate`, `dim`, `fact`, `macros`, `tests`, `ci`, `deploy`,
  `docs`.
- Body explains *why*. Diff shows *what*.

Examples:

```
feat(dim): add dim_offer built from stg_telecom_customer_churn

Offer is stored as a nullable Title-Case string in Bronze and joins to
the fact via a natural key. The "None" literal is preserved as a real
value pending business clarification (see README §"Open business
questions").
```

```
fix(fact): coalesce churn_reason_key to unknown when is_churned is null

Previously null churn flags produced null FKs on 3 rows in the CI
schema; the Unknown member now catches them. Adds a regression
singular test.

Closes TA-217
```

```
ci: cache dbt_packages between PR runs
```

## Development workflow

1. Sync your local `main`:
   ```bash
   git fetch origin
   git checkout main
   git pull --ff-only origin main
   ```
2. Create a branch:
   ```bash
   git checkout -b feat/dim-offer
   ```
3. Make your change. Prefer small, focused commits.
4. Run local checks (see next section).
5. Push and open a pull request against `main`.
6. Address CI results and review feedback.
7. Once approved and CI is green, the reviewer merges (see
   [merge policy](#merge-policy)).

## Testing locally before you push

The CI pipeline is fast, but running these locally saves a round trip.

```bash
# Fast static checks
dbt deps
dbt parse
sqlfluff lint models/

# YAML + shell + workflow linters (only if you touched those files)
yamllint models/ profiles.yml dbt_project.yml packages.yml selectors.yml
shellcheck scripts/ci/*.sh scripts/deploy/*.sh scripts/cleanup/*.sh

# Full local build against your own dev target
#   - Set your dev Databricks creds in .env first.
#   - This writes to workspace.silver / workspace.gold, NOT a CI schema.
#   - Use a personal dev catalog when possible.
dbt build

# Rebuild only what you changed, plus downstream
dbt build --select state:modified+ --defer --state target/
```

If your change affects a fact, verify the incremental watermark still
picks up your test rows:

```bash
dbt run --select fct_customer_monthly_snapshot
# then re-run without changes and confirm it MERGEs 0 new rows
dbt run --select fct_customer_monthly_snapshot
```

## Opening a pull request

- Target branch: `main`.
- Fill in a clear title following the commit style
  (`feat(dim): add dim_offer`).
- The PR description should cover:
  - **What** changed and **why**.
  - **How** to verify it (queries, expected row counts, screenshots
    of `dbt test` output when relevant).
  - **Risks** and rollback notes if the change touches a fact or a
    published dim.
  - **Related issue** (`Closes TA-123`) when applicable.
- Keep PRs small. If a change exceeds ~500 lines of SQL, split it.
- Draft PRs are welcome while you work through CI failures.

## What CI runs on your PR

See `docs/CI_CD.md` for the full architecture. In short:

1. **`static-checks`** (always, including for fork PRs)
   - actionlint, yamllint, shellcheck, `dbt parse`, sqlfluff on
     changed SQL only.
2. **`dbt-ci`** (same-repo PRs only)
   - Validates the CI environment (`ci_pr_<PR>_silver` and
     `ci_pr_<PR>_gold` inside `workspace_ci`).
   - Runs Slim CI (`state:modified+ --defer`) when a production
     manifest is available. First PR after bootstrap uses the
     `ci_build` selector fallback.
   - Uploads `manifest.json`, `run_results.json`, `catalog.json`,
     `sources.json`, `graph_summary.json`, `logs/dbt.log` as workflow
     artifacts (14-day retention).
   - Writes a job summary with pass / fail / warn counts and the CI
     schema resolved for your PR.

Merge is blocked on:

- dbt parse or compile errors
- Model build errors
- Error-severity generic tests (`not_null`, `unique`, `relationships`,
  `accepted_values`, `dbt_utils.accepted_range`)
- Error-severity singular tests (grain, reconciliation, FK integrity)

Warnings do not block. They show up in the job summary.

When your PR closes (merged or not), the `cleanup-pr-schema` workflow
drops the two CI schemas automatically.

## Merge policy

- **Squash merge** is the default. Keeps `main` history linear.
- The squash commit message defaults to the PR title. Edit it to match
  the Conventional Commits format if it doesn't already.
- **Rebase merge** is fine when you've already curated your commits.
- **Merge commit** is discouraged (adds noise to `main`).
- Every merge to `main` triggers `deploy-production`, which:
  - Requires approval on the `production` GitHub Environment.
  - Compiles the exact merged commit against production.
  - Publishes a `prod-YYYYMMDD-HHMM-<shortsha>` GitHub Release with
    `manifest.json` attached (used by future Slim CI runs).
  - Runs a non-destructive smoke test.

## Production deploy and rollback

- Deploys are code-only. The scheduled Databricks Workflow picks up
  the deployed code on its next run. That is intentional (see
  `docs/CI_CD.md` §2).
- To trigger the Databricks production Job right after a deploy, use
  the **workflow_dispatch** entry point of `Deploy production` and set
  `trigger_production_job = true`. Default is `false`.
- To roll back **code** to a prior release, use the **Redeploy
  release** workflow and pass a tag / branch / SHA in `git_ref`. This
  goes through the same production approval prompt. See
  `docs/CI_CD.md` §11 for data-rollback guidance (Delta history,
  full-refresh policy).

## Code style

### SQL

- All SQL is Databricks SQL.
- Lowercase keywords, lowercase identifiers.
- CTE per logical step, joined by trailing commas.
- One column per line in the outermost SELECT.
- Every model documented in the sibling `.yml` (description +
  column-level docs when non-obvious).
- Every model has at least a `not_null` and `unique` on the business
  key, plus a `relationships` test on any FK.
- Materialization strategy: staging = view, intermediate = view,
  dim = table, fact = incremental Delta MERGE. Don't deviate without
  a note in the model header and a mention in the PR.
- Preserve existing vertical alignment on `as` keywords. SQLFluff's
  layout rules are intentionally excluded for that reason.

### Jinja

- Prefer `ref()` and `source()` for every table reference.
- Use `dbt_utils.generate_surrogate_key` for every surrogate key.
- Never hardcode a schema or catalog. Everything flows through
  `env_var()` and `macros/generate_schema_name.sql`.
- Custom macros live under `macros/`. Ops macros (things called from
  CI) live under `macros/ops/`.

### YAML

- Two-space indentation.
- Keep line length below the model in question — no hard cap enforced.
- Group tests logically: business-key tests first, then FKs, then
  value constraints.

### Shell

- `set -euo pipefail` at the top of every script.
- Quote every variable expansion.
- Validate required environment variables at the top with
  `: "${VAR:?required}"`.
- Never echo secret values. `write_job_summary.py` demonstrates the
  pattern.

## When to add tests

Add a test when:

- You introduce a new business key. Add `not_null` + `unique`.
- You introduce a new FK. Add `relationships`.
- You introduce a new categorical column. Add `accepted_values`.
- You introduce a new numeric constraint (e.g. `revenue >= 0`). Add
  `dbt_utils.accepted_range`.
- You introduce a new invariant that a generic test cannot express
  (e.g. "Pending support events have NULL resolution_hours"). Add a
  **singular test** under `tests/` and use error severity by default.

Add a `warn` severity only when the anomaly is a known retained
source-data quirk that has been discussed. Document the decision in
the model header.

## Reporting problems

- **CI failure you don't understand?** Attach the workflow-run link in
  the PR and ping the reviewer. The job summary usually shows the
  failing node.
- **Broken production deploy?** File an issue with the tag
  (`prod-YYYYMMDD-HHMM-<sha>`) that failed and the Databricks run
  URL. Use the **Redeploy release** workflow to roll back to the last
  known-good tag while investigating.
- **Suspected data-quality issue?** Open an issue with the affected
  model, an example row, and the expected vs actual output. If you
  can localize it to a source anomaly, add a singular test in the
  same PR.

Thanks for making this project better.
