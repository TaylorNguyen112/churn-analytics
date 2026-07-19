# churn_analytics

Production-quality dbt Core project on Databricks (Unity Catalog) that
transforms raw telecom customer data into a dimensional model ready for
churn analytics. Built end-to-end from Bronze sources to a star schema
with two fact tables and five conformed dimensions.

- **Platform**: Databricks + Delta Lake + Unity Catalog
- **Modeling tool**: dbt Core 1.11 with `dbt-databricks` 1.12 and `dbt-utils` 1.4
- **SQL dialect**: Databricks SQL
- **Auth**: OAuth M2M (service principal client_id + client_secret)
- **Layout**: Medallion (bronze → silver staging → silver intermediate → gold core)

## Table of contents

1. [Architecture at a glance](#architecture-at-a-glance)
2. [DAG](#dag)
3. [Prerequisites and setup](#prerequisites-and-setup)
4. [Running the pipeline](#running-the-pipeline)
5. [Layer 0 — Bronze (sources)](#layer-0--bronze-sources)
6. [Layer 1 — Silver / staging](#layer-1--silver--staging)
7. [Layer 2 — Silver / intermediate](#layer-2--silver--intermediate)
8. [Layer 3 — Gold / core (dimensional marts)](#layer-3--gold--core-dimensional-marts)
9. [Macros](#macros)
10. [Tests](#tests)
11. [Complete file reference](#complete-file-reference)
12. [Key design decisions and rationale](#key-design-decisions-and-rationale)
13. [Data-quality findings](#data-quality-findings)
14. [Open business questions](#open-business-questions)
15. [Security notes](#security-notes)
16. [CI/CD](#cicd)
17. [Contributing](#contributing)

## Architecture at a glance

```
Bronze (workspace.bronze)                   Sources - untouched
  ├── telecom_customer_churn                    7,043 rows
  ├── telecom_zipcode_population                1,671 rows
  ├── customer_monthly_snapshot                63,905 rows
  └── customer_support_events                  11,114 rows

Silver / staging (workspace.silver, views)  Rename, type, dedup
  ├── stg_telecom_customer_churn
  ├── stg_telecom_zipcode_population
  ├── stg_customer_monthly_snapshot
  └── stg_customer_support_events

Silver / intermediate (workspace.silver, views)  Business entities, no BI
  ├── int_customer_profile
  ├── int_customer_service_profile
  ├── int_customer_financial
  ├── int_customer_churn_status
  ├── int_zipcode_geography
  ├── int_customer_monthly_360
  └── int_support_event_enriched

Gold / core (workspace.gold, tables + incremental)  Dimensional marts
  ├── dim_customer                    (table)
  ├── dim_geography                   (table)
  ├── dim_service_profile             (table)
  ├── dim_churn_reason                (table)
  ├── dim_date                        (table)
  ├── fct_customer_monthly_snapshot   (incremental MERGE)
  └── fct_support_event               (incremental MERGE)
```

## DAG

```
stg_telecom_customer_churn ──┬─► int_customer_profile ─────────► dim_customer
                             ├─► int_customer_service_profile ─► dim_service_profile
                             ├─► int_customer_financial
                             └─► int_customer_churn_status ─────► dim_churn_reason
stg_telecom_zipcode_population ┐
stg_telecom_customer_churn ────┴─► int_zipcode_geography ──────► dim_geography

stg_customer_monthly_snapshot ┐
int_customer_profile          │
int_customer_service_profile  ├──► int_customer_monthly_360 ───► fct_customer_monthly_snapshot
int_zipcode_geography         │
int_customer_churn_status     ┘

stg_customer_support_events ┐
int_customer_monthly_360    ┴──► int_support_event_enriched ───► fct_support_event

(date span from monthly snapshots + support events) ─► dim_date
```

## Prerequisites and setup

Databricks side:

- A running SQL Warehouse.
- A service principal with:
  - **Databricks SQL access** entitlement
  - `CAN USE` on the SQL Warehouse
  - `BROWSE` on the catalog `workspace`
  - `USE CATALOG workspace`, `USE SCHEMA workspace.bronze`, `SELECT` on the four Bronze tables
  - `USE SCHEMA workspace.silver`, `CREATE TABLE`, `MODIFY` on `workspace.silver`
  - `USE SCHEMA workspace.gold`,   `CREATE TABLE`, `MODIFY` on `workspace.gold`
- OAuth client_id + client_secret generated for the service principal.

Local side:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt   # dbt-databricks 1.12.2 pinned

cp .env.example .env
# Fill in DBT_DATABRICKS_HOST, DBT_DATABRICKS_HTTP_PATH,
# DBT_DATABRICKS_CLIENT_ID, DBT_DATABRICKS_CLIENT_SECRET.
set -a && source .env && set +a

dbt deps                    # installs dbt_utils
dbt debug --profiles-dir .  # connectivity check
```

Tip: `export DBT_PROFILES_DIR=$PWD` once and drop `--profiles-dir .` from every command below.

## Running the pipeline

```bash
# Full end-to-end build + tests
dbt build --profiles-dir .

# Layer-by-layer (useful when debugging)
dbt build --select tag:staging      --profiles-dir .
dbt build --select tag:intermediate --profiles-dir .
dbt build --select tag:gold         --profiles-dir .

# Rebuild a single fact and everything downstream
dbt build --select fct_customer_monthly_snapshot+ --profiles-dir .

# Full-refresh an incremental fact
dbt run --select fct_customer_monthly_snapshot --full-refresh --profiles-dir .
```

**Current state after `dbt build`**: 18 models, 175 tests (163 generic + 12 singular), 4 sources — PASS=180, WARN=1 (intentional, retained source anomaly), ERROR=0.

## Layer 0 — Bronze (sources)

Bronze contains raw ingested Delta tables landing from `GOOGLE_DRIVE` via the upstream ETL job. This project does **not** modify, overwrite, or recreate Bronze tables — they are read-only inputs.

Every Bronze table carries a consistent block of ETL metadata columns:
`etl_ingested_at`, `etl_source_system`, `etl_run_id`, `etl_job_id`, `etl_task_name`, `etl_source_file`, `etl_file_row_number`.

Bronze is registered as a dbt source in `models/sources/src_telecom.yml`:

- Source name `bronze`, catalog and schema pulled from env vars.
- Business keys tested `not_null` at the source level.
- **Uniqueness is intentionally NOT tested here** — raw Bronze may legitimately contain duplicates from re-ingestion; uniqueness is enforced downstream in Silver after deduplication.
- Freshness is not configured yet: the current dataset is a one-shot batch load; enable per-table freshness once a real ingestion SLA is defined.

## Layer 1 — Silver / staging

**Purpose**: rename to snake_case, cast to correct types, trim strings, convert blank strings to NULL, deduplicate, and expose validity flags — without changing business meaning.

**Materialization**: views (cheap, always reflect Bronze).

**Tags**: `silver`, `staging`.

**Deduplication** uses `row_number() over (partition by <business_key> order by <freshness>)` with model-specific ordering documented in each file header. Ordering priority when available: `source_updated_at DESC → etl_ingested_at DESC → etl_file_row_number DESC`.

### `models/staging/stg_telecom_customer_churn.sql`

- **Grain**: one row per `customer_id`. **7,043 rows** in current data (Bronze has no duplicates).
- **Source key `Customer ID`** contains a space — quoted with backticks. Renamed to `customer_id`.
- **ZIP code** stored as 5-character string (`lpad(cast(zip as string), 5, '0')`).
- **Yes/No columns** converted via the `yes_no_to_boolean` macro. Blank strings become NULL rather than false, so "no service available" and "explicitly declined" are not conflated.
- **Financial fields** cast to `decimal(18,2)` via `try_cast`.
- **Negative `monthly_charge`** (120 rows) is preserved and flagged with `is_monthly_charge_valid`. Source-truth over silent correction.
- **Revenue reconciliation flag** `is_total_revenue_reconciled` computed here (all 7,043 rows currently reconcile within 0.01).
- **No source `updated_at`** on this table → dedup ordering is `etl_ingested_at DESC, etl_file_row_number DESC`.

### `models/staging/stg_telecom_zipcode_population.sql`

- **Grain**: one row per `zip_code`. **1,671 rows**.
- `Zip Code` (int in Bronze) is lpad'd to 5 chars for join consistency with churn's ZIP.
- Population cast to bigint. `is_population_valid` flag retained defensively; profiling showed 0 non-positive values today.

### `models/staging/stg_customer_monthly_snapshot.sql`

- **Grain**: one row per `monthly_snapshot_id` = one row per (`customer_id`, `snapshot_month`). **63,905 rows**.
- `snapshot_month` parsed as DATE, defensively `date_trunc`'d to month-start.
- Source `updated_at` renamed to `source_updated_at` and used as primary dedup ordering key.
- Boolean status flags (`is_churned`, `is_stayed`, `is_new_customer`, `is_churn_eligible`) derived from `customer_status`.
- **Negative `monthly_charge`** (1,078 rows) preserved and flagged.
- Additional source-level ingestion metadata preserved: `source_batch_id`, `source_system`.

### `models/staging/stg_customer_support_events.sql`

- **Grain**: one row per `support_event_id`. **11,114 rows**.
- `event_timestamp` cast to timestamp; `resolution_hours` to decimal(18,2); `satisfaction_score` to int.
- Validity flags `is_resolution_hours_valid` and `is_satisfaction_score_valid` retain NULLs (which are legitimate for `Pending` events).
- Workflow flags `is_resolved` and `is_escalated` derived from `resolution_status`.
- **Source-derived business rule** discovered during profiling and enforced by a singular test:
  - `Pending` → resolution_hours and satisfaction_score are ALWAYS both NULL.
  - `Resolved` / `Escalated` / `Closed - Unresolved` → both are ALWAYS populated.

### `models/staging/staging.yml`

Tests and column documentation for all four staging models. Every model has grain-enforcing `not_null` + `unique` on its business key, plus accepted-values tests on all categorical columns to detect drift, and relationship tests for the churn.zip_code → zipcode_population FK.

## Layer 2 — Silver / intermediate

**Purpose**: encapsulate reusable business logic that multiple facts or dimensions will consume. No BI-specific aggregations, no dashboard business rules, no final Gold surrogate keys.

**Materialization**: views.

**Tags**: `silver`, `intermediate`.

### `models/intermediate/int_customer_profile.sql`

- **Grain**: one row per `customer_id`. 7,043 rows.
- **What it adds**:
  - `age_band` (18-29 / 30-44 / 45-59 / 60+ / Unknown).
  - `current_tenure_band` (0-6 / 7-12 / 13-24 / 25-48 / 49+ months / Unknown).
  - `first_join_month` — **estimate** derived as `add_months(latest_snapshot_month, -(current_tenure_months - 1))`. Documented as an estimate because the source has no explicit join date; profiling confirmed reconstructing from the monthly snapshot is deterministic today.
- **Why it exists separately**: demographics + tenure are consumed by `dim_customer`, `int_customer_monthly_360`, downstream analyses. Isolating them keeps other intermediate models focused.

### `models/intermediate/int_customer_service_profile.sql`

- **Grain**: one row per `customer_id` (**Design A**).
- **Why Design A**: the two allowed designs were "one row per customer" or "one row per unique service configuration". Design A keeps the intermediate directly consumable at customer grain; the compact configuration dim is produced later via `SELECT DISTINCT`.
- **What it adds**:
  - `service_count` — sum of the 11 boolean service flags where each is coalesced to false before summing.
  - `has_any_streaming_service`, `has_streaming_bundle` (≥2 of TV/Movies/Music), `has_security_bundle` (Security AND Backup AND Device Protection).
  - **`service_profile_key`** — `dbt_utils.generate_surrogate_key` over the 14 natural service attributes. This exact expression is reused in `dim_service_profile`, guaranteeing key reconciliation without a lookup.

### `models/intermediate/int_customer_financial.sql`

- **Grain**: one row per `customer_id`.
- **What it adds**:
  - `calculated_total_revenue` — recomputed from components for reconciliation.
  - `revenue_reconciliation_difference` — signed gap (positive = source over-reported).
  - `average_monthly_revenue` = `total_revenue / nullif(tenure_months, 0)` — NULL when tenure is 0/NULL.
  - Preserves `is_total_revenue_reconciled` and `is_monthly_charge_valid` flags from staging.
- Anomalies are exposed via flags, never silently corrected.

### `models/intermediate/int_customer_churn_status.sql`

- **Grain**: one row per `customer_id`.
- **What it adds**:
  - Cleaner boolean flags directly (`is_churned`, `is_stayed`, `is_new_customer`, `is_churn_eligible`).
  - `monthly_revenue_lost_current` = `monthly_charge` when churned and charge ≥ 0, else 0.
- **`is_churn_eligible` excludes `Joined`** on principle: new customers cannot yet churn or stay in the current period. Downstream churn-rate KPIs should use this as the denominator.

### `models/intermediate/int_zipcode_geography.sql`

- **Grain**: one row per `zip_code`. 1,671 rows.
- **How it's assembled**: LEFT JOIN `stg_telecom_zipcode_population` (population, 1,671 rows) ← deduplicated geography aggregates (city, latitude, longitude) from `stg_telecom_customer_churn`.
- **Why `MIN()` aggregation is safe**: profiling proved ZIP → city and ZIP → (latitude, longitude) are strict 1:1 mappings across all 1,626 customer-side ZIPs. Every value in each per-ZIP group is identical.
- `state` and `region` are `NULL` — no source provides them. Enrichment path documented.
- Enforced by the singular test `assert_zipcode_geography_unique`.

### `models/intermediate/int_customer_monthly_360.sql`

- **Grain**: one row per (`customer_id`, `snapshot_month`). **63,905 rows** — the central historical entity.
- **Sources**: `stg_customer_monthly_snapshot` (spine) + `int_customer_profile` (stable demographics) + `int_customer_churn_status` (terminal churn attribution) + `int_customer_service_profile` (service booleans) + `int_zipcode_geography` (geography + population).
- **Historical vs current attributes** — a deliberate mix:
  - `customer_status`, `contract_type`, `internet_type`, `is_churned` come from the **snapshot itself** (historical).
  - `churn_category` and `churn_reason` come from the current customer record but are **only activated in the fact when `is_churned = true` for that month**. This prevents future information leaking into historical rows.
  - Yes/No service flags come from the current customer profile because those columns don't exist on the snapshot table. Profiling verified that contract_type and internet_type never change over any customer's snapshot history in current data, so this "current-as-of-report" borrowing is safe today. Model header explicitly flags that this must be revisited if service-change events ever appear on the snapshot.
- **Additive count flags** materialized here so the fact can `SUM` cleanly: `customer_count=1`, `eligible_customer_count`, `churned_customer_count`, `stayed_customer_count`, `new_customer_count`.
- **`data_quality_status`** classifier (VALID / MISSING_CUSTOMER_ID / INVALID_SNAPSHOT_MONTH / INVALID_MONTHLY_CHARGE / MISSING_ZIP_CODE) — invalid rows are NEVER dropped; they are visibly flagged for downstream monitoring.

### `models/intermediate/int_support_event_enriched.sql`

- **Grain**: one row per `support_event_id`. **11,114 rows**.
- **Historical enrichment**: LEFT JOIN `int_customer_monthly_360` on `customer_id` + `event_month = snapshot_month` to attach the customer's as-of-that-month status, contract, internet type, and geography.
- **Fan-out safety**: the intermediate is one-to-one at the support event grain by construction (both sides are unique on their business keys). Enforced by `assert_no_support_event_fanout` and `assert_support_event_grain`.
- **`is_customer_snapshot_matched`** exposes rows where no matching monthly snapshot exists. All snapshot-derived attributes remain NULL in that case — the fact never falls back to current-state data.
- Profiling: 11,114 / 11,114 events match a monthly snapshot today.

### `models/intermediate/intermediate.yml`

Column docs + tests for every intermediate model. Highlights:

- Grain uniqueness enforced on all seven models.
- Relationship tests: `int_customer_monthly_360.customer_id` → `int_customer_profile.customer_id`; `int_support_event_enriched.customer_id` → `int_customer_profile.customer_id`; `int_customer_profile.zip_code` → `int_zipcode_geography.zip_code`.
- Accepted-values on categorical bucketed fields and status columns.
- `data_quality_status` restricted to the 5 known classifier values.

## Layer 3 — Gold / core (dimensional marts)

**Purpose**: a Kimball-style star schema for BI. Every fact joins conformed dimensions on surrogate keys.

**Materialization**: `table` for dims, `incremental` (Delta MERGE) for facts.

**Tags**: `gold`, `core`.

### `models/marts/core/dim_customer.sql`

- **Grain**: one row per customer + one Unknown member. **7,044 rows**.
- **SCD**: Type 1.
- **Why SCD1**: profiling confirmed customer attributes are stable in the current data (0 tenure or contract changes observed). SCD2 machinery (history + effective_from / effective_to + is_current) would add complexity without capturing real change events. If future data shows demographic churn, migration to SCD2 is schema-preserving because the `customer_key` hash contract doesn't change.
- **`customer_key`** = `dbt_utils.generate_surrogate_key(['customer_id'])`. Deterministic hash — not a `row_number()` (which would change across runs and break fact FKs).
- **Unknown member**: `customer_key = generate_surrogate_key(['UNKNOWN'])`, `customer_id = 'UNKNOWN'`, text attributes `Unknown`, numerics NULL, `is_unknown_member = true`.

### `models/marts/core/dim_geography.sql`

- **Grain**: one row per ZIP + one Unknown member. **1,672 rows**.
- **`geography_key`** = `generate_surrogate_key(['zip_code'])`.
- **`state`, `region`** = NULL. Not in source. Enrichment path documented (add a seed with a ZIP → state/region map and swap the NULLs).
- Enforced 1:1 at the intermediate layer.

### `models/marts/core/dim_service_profile.sql`

- **Grain**: one row per unique service configuration + one Unknown member. **2,766 rows** (2,765 real configurations across 7,043 customers).
- **Built via `SELECT DISTINCT`** on the 14 natural service attributes plus derived bundle flags. Distinctness is provable — not a substitute for a broken join.
- **`service_profile_key`** is precomputed in `int_customer_service_profile` using the identical `generate_surrogate_key` expression. Fact and dim reconcile without a natural-key lookup.
- Fat dimension (~40% distinct) but manageable. If it grows, bucket low-signal Yes/No flags into a coarser profile.

### `models/marts/core/dim_churn_reason.sql`

- **Grain**: one row per (`churn_category`, `churn_reason`) pair + two special members. **22 rows** (20 real + Not Applicable + Unknown).
- **`churn_reason_key`** = `generate_surrogate_key(['churn_category', 'churn_reason'])`. dbt-utils coalesces NULLs to empty strings, giving null-safe hashing.
- **Two distinct special members with distinct semantics**:
  - `Not Applicable` / `Not Applicable` — used for **non-churned customer rows** in the fact. Distinct from `Unknown` because the ABSENCE of a churn reason is a real, expected outcome for Stayed / Joined customers.
  - `Unknown` / `Unknown` — used defensively for **churned rows lacking a category or reason**. Zero occurrences today; kept so downstream surrogate lookups always succeed and never fall through to another dimension's Unknown key.
- Fact rows currently split 1,869 `Real` + 62,036 `Not Applicable` + 0 `Unknown`.

### `models/marts/core/dim_date.sql`

- **Grain**: one row per `calendar_date`. **1,096 rows** covering 2024-01-01 → 2026-12-31 inclusive.
- **Range choice**: monthly snapshots span 2025-01-01 → 2025-12-01; support events span 2025-01-01 → 2025-12-31. Adding one year of buffer on either side avoids re-generation when a new year of data arrives.
- **`date_key`** = integer YYYYMMDD (`cast(date_format(calendar_date, 'yyyyMMdd') as int)`). Joins as `WHERE fact.date_key = dim.date_key`.
- Generated with `dbt_utils.date_spine`.
- Full column set: `day_of_month`, `day_name`, `day_of_week`, `week_of_year`, `month_number`, `month_name`, `quarter_number`, `quarter_name`, `year_number`, `year_month`, `year_quarter`, `month_start_date`, `month_end_date`, `is_month_start`, `is_month_end`, `is_weekend`.

### `models/marts/core/fct_customer_monthly_snapshot.sql`

- **Grain**: one row per (`customer_id`, `snapshot_month`). **63,905 rows**.
- **Materialization**: `incremental`, `incremental_strategy='merge'`, `unique_key='customer_monthly_snapshot_key'`, `on_schema_change='sync_all_columns'`.
- **Foreign keys** (all non-null after Unknown-member coalescing):
  - `customer_key` → `dim_customer`
  - `geography_key` → `dim_geography`
  - `service_profile_key` → `dim_service_profile`
  - `churn_reason_key` → `dim_churn_reason`
  - `date_key` → `dim_date`
- **Measures**: `monthly_charge`, `monthly_revenue`, `total_revenue`, `monthly_revenue_lost`.
- **Additive flags**: `customer_count=1`, `eligible_customer_count`, `churned_customer_count`, `stayed_customer_count`, `new_customer_count`.
- **Boolean flags**: `is_churned`, `is_stayed`, `is_new_customer`, `is_churn_eligible` + `is_customer_matched`, `is_geography_matched`, `is_service_profile_matched`.
- **Data quality**: `data_quality_status` carried forward from the intermediate.
- **Audit**: `source_updated_at`, `ingested_at`, `source_batch_id`, `ingestion_batch_id`, `dbt_loaded_at`, `dbt_invocation_id`.
- **Churn-reason routing** encoded in the fact:
  - `is_churned` + real (category, reason) → real dim row.
  - `is_churned` + missing (category, reason) → `Unknown` member.
  - Not churned → `Not Applicable` member.
- **Incremental watermark**:
  ```
  where greatest(source_updated_at, ingested_at)
        >= (select max(greatest(source_updated_at, ingested_at)) from {{ this }}) - 2 days
  ```
  Snapshot_month is intentionally **not** used as the watermark because historical months can be corrected retroactively.

### `models/marts/core/fct_support_event.sql`

- **Grain**: one row per `support_event_id`. **11,114 rows**.
- **Materialization**: `incremental` MERGE, `unique_key='support_event_key'`.
- **Foreign keys**: `customer_key`, `geography_key`, `service_profile_key`, `date_key`. All Unknown-member-coalesced.
- **Degenerate identifier**: `support_event_id` preserved.
- **Descriptive event attributes** (`issue_category`, `channel`, `priority`, `resolution_status`) are kept on the fact intentionally. Promoting each to its own dim would create narrow dimensions with little descriptive power (Kimball anti-pattern).
- **Historical customer context** (`customer_status_at_event_month`, `contract_type_at_event_month`, `internet_type_at_event_month`) carried from the intermediate.
- **Measures / flags**: `event_count=1`, `resolution_hours`, `satisfaction_score`, `is_resolved`, `is_escalated`, `is_resolution_hours_valid`, `is_satisfaction_score_valid`, `is_customer_snapshot_matched`.
- Same incremental watermark pattern as the monthly fact.

### `models/marts/core/core.yml`

Column docs + tests for every dim and fact. Every `_key` is `not_null` + `unique`. Every FK on both facts has a `relationships` test to the corresponding dim. Additive count columns constrained by `accepted_values`. `monthly_revenue_lost >= 0`, `satisfaction_score` in [1, 5], `resolution_hours >= 0`.

## Macros

### `macros/yes_no_to_boolean.sql`

Case-insensitive whitespace-tolerant conversion of Yes/Y/True/1 and No/N/False/0 into booleans. Anything else — including blank strings and NULL — returns NULL, so unexpected source values are never silently coerced. Used across `stg_telecom_customer_churn` for all 12 Yes/No columns.

### `macros/generate_schema_name.sql`

Overrides dbt's default schema-name concatenation so `+schema: silver` maps to `workspace.silver` instead of the default `workspace.<target>_silver`. Required for the medallion layout in this project — dbt's default concatenation would produce `silver_silver`, `silver_gold`, etc. Small file (single macro), pays for itself immediately with two layers configured today and future layers when Gold Marts / Semantic Layer arrive.

## Tests

### 163 generic tests

Standard dbt tests: `not_null`, `unique`, `accepted_values`, `relationships`, `dbt_utils.accepted_range`. Distributed across `staging.yml`, `intermediate.yml`, and `core.yml`.

### 12 singular tests (in `tests/`)

Business-rule tests that go beyond what generic tests express. Every test returns **only violating rows** (dbt convention).

| Test | Purpose | Severity |
|---|---|---|
| `assert_total_revenue_reconciles.sql` | `total_revenue ≈ charges − refunds + extras + LD` within 0.01 | error |
| `assert_support_resolution_consistency.sql` | `Pending` ↔ NULL hours/score; terminal statuses ↔ populated | error |
| `warn_negative_monthly_charge.sql` | Surface retained anomaly (120 + 1,078 = 1,198 rows) | **warn** |
| `assert_no_duplicate_customer_month.sql` | Defends alternative (customer_id, snapshot_month) grain on the staging snapshot | error |
| `assert_customer_monthly_grain.sql` | Enforces grain on `int_customer_monthly_360` | error |
| `assert_zipcode_geography_unique.sql` | Enforces 1 row per ZIP + single (city, lat, long) tuple | error |
| `assert_support_event_grain.sql` | Enforces grain on `int_support_event_enriched` | error |
| `assert_no_support_event_fanout.sql` | Guarantees staging row count == intermediate row count | error |
| `assert_customer_status_flags_consistent.sql` | Additive counts and status booleans agree in `int_customer_monthly_360` | error |
| `assert_fact_customer_monthly_grain.sql` | Grain on `fct_customer_monthly_snapshot` | error |
| `assert_fact_support_event_grain.sql` | Grain on `fct_support_event` | error |
| `assert_customer_monthly_fact_reconciliation.sql` | Intermediate row count == fact row count | error |
| `assert_support_fact_reconciliation.sql` | Staging row count == support-event fact row count | error |
| `assert_customer_status_measure_consistency.sql` | Post-join fact measures still agree with boolean flags | error |
| `assert_fact_foreign_keys_not_null.sql` | Unknown-member coalescing worked; no NULL FKs on any fact | error |

**Severity policy**:
- `error` (blocks build) — grain, referential integrity, revenue reconciliation, status-flag consistency, fact vs source reconciliation.
- `warn` — known retained source anomalies (negative monthly charges), low-risk categorical drift (gender, contract_type).

## Complete file reference

```
churn_analytics/
├── README.md                              ← this file
├── requirements.txt                       ← dbt-databricks==1.12.2
├── .env.example                           ← env-var template (safe to commit)
├── .env                                   ← real credentials (gitignored)
├── .gitignore                             ← excludes .env, target/, dbt_packages/, logs/, .venv/
├── dbt_project.yml                        ← project name, tags per folder, schema routing
├── profiles.yml                           ← Databricks connection (OAuth M2M)
├── packages.yml                           ← dbt_utils dependency
├── package-lock.yml                       ← resolved package versions
│
├── models/
│   ├── sources/
│   │   └── src_telecom.yml                ← Bronze source definitions + not_null tests
│   │
│   ├── staging/                           ← tag: silver, staging          views
│   │   ├── stg_telecom_customer_churn.sql
│   │   ├── stg_telecom_zipcode_population.sql
│   │   ├── stg_customer_monthly_snapshot.sql
│   │   ├── stg_customer_support_events.sql
│   │   └── staging.yml
│   │
│   ├── intermediate/                      ← tag: silver, intermediate     views
│   │   ├── int_customer_profile.sql
│   │   ├── int_customer_service_profile.sql
│   │   ├── int_customer_financial.sql
│   │   ├── int_customer_churn_status.sql
│   │   ├── int_zipcode_geography.sql
│   │   ├── int_customer_monthly_360.sql
│   │   ├── int_support_event_enriched.sql
│   │   └── intermediate.yml
│   │
│   └── marts/
│       └── core/                          ← tag: gold, core
│           ├── dim_customer.sql           table
│           ├── dim_geography.sql          table
│           ├── dim_service_profile.sql    table
│           ├── dim_churn_reason.sql       table
│           ├── dim_date.sql               table
│           ├── fct_customer_monthly_snapshot.sql   incremental (Delta MERGE)
│           ├── fct_support_event.sql               incremental (Delta MERGE)
│           └── core.yml
│
├── macros/
│   ├── yes_no_to_boolean.sql              ← Yes/No → boolean converter
│   └── generate_schema_name.sql           ← medallion schema routing override
│
├── tests/                                 ← 12 singular SQL tests (see Tests section)
│
├── analyses/  seeds/  snapshots/          ← empty dbt scaffolds for future use
│
└── .venv/  dbt_packages/  target/  logs/  ← runtime dirs (all gitignored)
```

## Key design decisions and rationale

| Decision | Choice | Why |
|---|---|---|
| Auth to Databricks | OAuth M2M with service principal | User-based PATs hit `sql` scope issues in this workspace; SP is the right long-term identity for pipelines. |
| Silver + Intermediate schema | Both in `workspace.silver` | Standard medallion practice; keeps "clean but not consumed by BI" objects in one place; intermediate models are views so no additional storage. |
| Schema routing | `generate_schema_name` override macro | Lets `+schema: silver` mean `silver`, not `silver_silver`. One-file, one-macro cost for a much cleaner layout. |
| Staging materialization | Views | Cheap, always reflect Bronze, no incremental complexity needed. |
| Intermediate materialization | Views | Reusable business logic; recomputed cheaply on demand. |
| Dim materialization | Tables | Small, joined frequently, benefit from materialization. |
| Fact materialization | Incremental MERGE | Deltas can arrive late; MERGE is idempotent by unique_key. |
| Dedup ordering | source_updated_at → etl_ingested_at → etl_file_row_number | Uses the strongest signal available per table; documented per model. |
| Yes/No handling | Custom macro | Blanks/NULL become NULL (not false) — distinguishes "no data" from "no service". |
| ZIP code | 5-char string throughout | Preserves leading zeros; consistent join key across churn + zipcode + geography. |
| Negative monthly charges | Preserved + flagged | Business decides later how to treat; Silver never silently corrects source. |
| `first_join_month` | Reconstructed estimate | Source has no join date; monthly grain from tenure + latest snapshot is deterministic today. |
| `int_customer_service_profile` grain | One row per customer (Design A) | Directly consumable by every downstream model; dim uses `SELECT DISTINCT`. |
| Historical vs current in monthly_360 | Snapshot's status/contract/internet; current profile's Yes/No booleans | Snapshot has the historical status columns; booleans don't exist on the snapshot but profiling proved they don't change over time. Documented assumption. |
| Churn reason in the fact | Activated only when `is_churned = true` for that row | Prevents future information leaking into pre-churn months. |
| SCD strategy for customer | Type 1 | Zero real change events in current data; SCD2 machinery buys nothing. Trade-off explicit. |
| Surrogate keys | `dbt_utils.generate_surrogate_key` (deterministic hash) | Stable across runs and across models; not `row_number()`. |
| Unknown members | Per-dim row with `generate_surrogate_key(['UNKNOWN'])` | Fact FKs `COALESCE` to that key; no NULL FKs; observability via `is_*_matched` flags. |
| Special member in `dim_churn_reason` | `Not Applicable` (non-churned) + `Unknown` (churned but missing) | Absence and unknown carry different meanings; deserve different keys. |
| Descriptive event attributes | Stay on `fct_support_event` | Low-cardinality event characteristics with limited descriptive power; would be Kimball anti-patterns as narrow dims. |
| Incremental watermark | `max(greatest(source_updated_at, ingested_at))` with 2-day lookback | Captures late-arriving corrections; snapshot_month alone would miss retro updates. |
| Test severity | error for grain/RI/reconciliation; warn for retained anomalies | Blocks pipeline on real defects; surfaces known issues visibly without noise. |
| Directories `seeds/`, `snapshots/`, `analyses/` | Empty scaffolds | Standard dbt layout; ready for future features (seed a state/region enrichment, snapshot SCD2 changes, ad-hoc analyses). |

## Data-quality findings

Discovered during Bronze profiling and preserved through the pipeline:

- **Negative `monthly_charge`** in 120 customer rows and 1,078 monthly snapshot rows (1,198 total). Retained; flagged via `is_monthly_charge_valid` and surfaced by `warn_negative_monthly_charge`. Rows are tagged `INVALID_MONTHLY_CHARGE` in `data_quality_status`.
- **Total revenue reconciliation** — all 7,043 customers reconcile within 0.01 today. The enforcement test remains at error severity so future drift blocks the build.
- **Blank strings** in `Churn Category`, `Churn Reason`, `Internet Type`, and blank-when-unavailable Yes/No columns — normalized to NULL in staging.
- **`Offer` literal `"None"`** — 3,877 customers have Offer = "None" (a string, not a NULL). Retained as-is; documented as a business-clarification item.
- **Support resolution pattern** — `Pending` ↔ NULL hours/score; terminal statuses ↔ populated. Enforced.
- **Referential integrity across Bronze** — 0 orphans across every FK checked (customer_id, zip_code). Relationship tests at error severity.
- **1:1 ZIP → city → lat/long** — confirmed and locked in with `assert_zipcode_geography_unique`.

## Open business questions

1. **Negative monthly charges** (1,198 rows) — legitimate account credits or source errors? Silver preserves them; Gold consumers need a policy (clamp / retain / exclude).
2. **`Offer = "None"`** — semantically "no offer" (map to NULL) or a distinct "declined" value?
3. **`Closed - Unresolved` in support events** — how should Gold treat these vs `Resolved`? They have non-NULL hours and score today, so they're a real terminal outcome, not a synonym for `Pending`.
4. **`churn_category = 'Other'` / `churn_reason = 'Deceased'`** (6 customers) — should the `is_churn_eligible` denominator exclude these on principle? Currently included as churned.
5. **`state` / `region`** — enrich `dim_geography` via a seed containing a ZIP → state/region map?
6. **Freshness SLA** — set per-source `warn_after` / `error_after` thresholds once the batch cadence is known.
7. **SCD upgrade trigger** — under what conditions should `dim_customer` migrate to SCD Type 2? Suggested triggers: demographic corrections mid-year, offer/contract changes captured on the customer record, address moves.

## Security notes

- Credentials in `.env` are gitignored via `.gitignore`. Never commit them.
- The service principal's OAuth client secret should be **rotated** when engineers leave the project or if the secret was ever pasted in a chat/log. Databricks admin console → Service principals → `dbt-sp` → Secrets → Generate new secret; then update `.env`.
- The Personal Access Token used in the earliest phase of this project (before switching to OAuth M2M) should be **revoked** in Databricks User Settings → Developer → Access tokens if it hasn't been already.
- The service principal is scoped to `workspace.bronze` (read) + `workspace.silver` and `workspace.gold` (write). It has no access to other catalogs or schemas by default.

## CI/CD

GitHub Actions handles pull-request validation and production
deployment. Databricks Workflows continue to own scheduled runs,
retries, and operational monitoring.

Four workflows live in `.github/workflows/`:

- `dbt-pr-ci.yml` — pull-request validation in an isolated schema
  (`ci_pr_<PR>_silver` / `ci_pr_<PR>_gold` inside the dedicated
  `workspace_ci` catalog). Uses Slim CI (`state:modified+ --defer`)
  when a production manifest is available, and falls back to the
  `ci_build` selector when it is not.
- `deploy-production.yml` — on merge to `main`, compiles the project
  against `prod`, publishes a `prod-YYYYMMDD-HHMM-<sha>` GitHub Release
  with the new `manifest.json`, and runs a non-destructive smoke test.
- `cleanup-pr-schema.yml` — on PR close, drops the two CI schemas
  associated with the PR.
- `redeploy-release.yml` — manual `workflow_dispatch` that redeploys
  any prior tag / branch / commit through the same production
  environment approval.

See [`docs/CI_CD.md`](docs/CI_CD.md) for the full architecture,
required GitHub Secrets and Variables, rollback procedure, and
interview demonstration script.

## Contributing

Branch naming, commit style, PR workflow, local test commands, and
merge policy are documented in [`CONTRIBUTING.md`](CONTRIBUTING.md).

Quick reference:

- Branches use `<category>/<short-description>`. Categories:
  `feat/`, `fix/`, `refactor/`, `perf/`, `docs/`, `test/`, `chore/`,
  `ci/`, `build/`, `hotfix/`, `revert/`.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/).
- `main` is protected. Every change is a pull request.
- CI runs Slim dbt build in an isolated `ci_pr_<PR>` schema and blocks
  merge on any error-severity failure.
