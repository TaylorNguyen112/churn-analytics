# dbt transformations — file-by-file, line-by-line reference

This document catalogs every transformation in the project, grouped by
layer, with the exact file and line range where each one lives. If you
grep the snippet, you'll find the code.

Legend:
- `path/to/file.sql:Ln–Lm` = lines `n` through `m` of the file.
- All paths are relative to the repository root.

---

## Reusable macros (used by every layer)

### `macros/yes_no_to_boolean.sql` — Yes/No → boolean

Handles case-insensitive whitespace-tolerant conversion. Blank / NULL /
unexpected values return NULL rather than false.

```
macros/yes_no_to_boolean.sql:L14–L20
```

```sql
{% macro yes_no_to_boolean(column) -%}
    case
        when lower(trim(cast({{ column }} as string))) in ('yes', 'y', 'true',  '1') then true
        when lower(trim(cast({{ column }} as string))) in ('no',  'n', 'false', '0') then false
        else null
    end
{%- endmacro %}
```

### `macros/audit_columns.sql` — standard audit block

Reads `etl_job_id` / `etl_run_id` / `etl_task_name` in three-tier
precedence (var → env_var → default) plus emits `etl_updated_at =
current_timestamp()`. Called at the tail of every silver/gold model.

```
macros/audit_columns.sql:L32–L41
```

```sql
{% macro audit_columns() -%}
    {%- set _job_id    = var('etl_job_id',    none) or env_var('DBT_ETL_JOB_ID',    'local')  -%}
    {%- set _run_id    = var('etl_run_id',    none) or env_var('DBT_ETL_RUN_ID',    'local')  -%}
    {%- set _task_name = var('etl_task_name', none) or env_var('DBT_ETL_TASK_NAME', 'manual') -%}
    cast('{{ _job_id    }}' as string) as etl_job_id,
    cast('{{ _run_id    }}' as string) as etl_run_id,
    cast('{{ _task_name }}' as string) as etl_task_name,
    current_timestamp()                as etl_updated_at
{%- endmacro %}
```

### `macros/generate_schema_name.sql` — medallion routing override

Maps `+schema: silver` and `+schema: gold` directly to those Unity
Catalog schemas, without the default `<target>_<custom>` concatenation.

```
macros/generate_schema_name.sql:L9–L15
```

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
```

---

## Layer 1 — Silver / Staging

Every staging model follows the same 4-CTE pattern: `source` → `renamed`
→ `deduplicated` → `final`. Below is the transformation-by-transformation
walk-through per file.

### `models/silver/staging/stg_telecom_customer_churn.sql`

Grain: one row per `customer_id`. Business key: `customer_id`.

| Transformation | Line range | Example |
|---|---|---|
| Snake-case rename + quoted-space handling (business key) | L41 | `trim(`Customer ID`) as customer_id` |
| Trim + blank-to-null on string fields | L43, L47, L54, L61, L72, L74, L83–L85 | `nullif(trim(Gender), '') as gender` |
| ZIP code standardized as 5-char string | L48 | `lpad(cast(`Zip Code` as string), 5, '0') as zip_code` |
| Yes/No columns → boolean via macro (12 columns) | L45, L56, L59–L60, L63–L70, L73 | `{{ yes_no_to_boolean('`Phone Service`') }} as has_phone_service` |
| Safe numeric coercion to `decimal(18,2)` | L57–L58, L76–L81 | `try_cast(`Total Revenue` as decimal(18,2)) as total_revenue` |
| Dedup helper columns kept in-model only (not projected) | L88–L89 | `etl_ingested_at as _dedup_ingested_at` |
| Bronze `etl_source_system` preserved for downstream | L92 | `etl_source_system as etl_source_system` |
| Deduplication by business key | L98–L110 | `row_number() over (partition by customer_id order by _dedup_ingested_at desc, _dedup_row_number desc) as _row_num` |
| Revenue reconciliation calculation | L149–L157 | `cast(coalesce(total_charges,0) - coalesce(total_refunds,0) + coalesce(total_extra_data_charges,0) + coalesce(total_long_distance_charges,0) as decimal(18,2)) as calculated_total_revenue` |
| Reconciliation validity flag (tolerance 0.01) | L159–L172 | `case when total_revenue is null then null when abs(total_revenue - (...)) <= 0.01 then true else false end as is_total_revenue_reconciled` |
| Monthly-charge validity flag (negative values retained, flagged) | L174–L178 | `case when monthly_charge is null then null when monthly_charge >= 0 then true else false end as is_monthly_charge_valid` |
| Filter to deduplicated row + emit audit block | L182–L186 | `where _row_num = 1` + `{{ audit_columns() }}` |

### `models/silver/staging/stg_telecom_zipcode_population.sql`

Grain: one row per `zip_code`. Business key: `zip_code`.

| Transformation | Line range | Example |
|---|---|---|
| ZIP standardized as 5-char string | L27 | `lpad(cast(`Zip Code` as string), 5, '0') as zip_code` |
| Population cast to `bigint` (defensive) | L28 | `try_cast(Population as bigint) as population` |
| Dedup helpers kept internally | L30–L31 | `etl_ingested_at as _dedup_ingested_at` |
| Deduplication ordering by ingested_at | L39–L48 | `row_number() over (partition by zip_code order by _dedup_ingested_at desc, _dedup_row_number desc)` |
| Population validity flag | L57–L61 | `case when population is null then null when population > 0 then true else false end as is_population_valid` |
| Emit audit block | L64 | `{{ audit_columns() }}` |

### `models/silver/staging/stg_customer_monthly_snapshot.sql`

Grain: one row per `(customer_id, snapshot_month)` = per `monthly_snapshot_id`.
Business key: `monthly_snapshot_id`.

| Transformation | Line range | Example |
|---|---|---|
| Business key trim | L23–L24 | `trim(monthly_snapshot_id)` |
| Defensive `date_trunc('month', ...)` on snapshot month | L26 | `cast(date_trunc('month', snapshot_month) as date) as snapshot_month` |
| Numeric coercions (int + decimal) | L28, L32–L34 | `try_cast(tenure_months as int)` |
| Nullif/trim on categorical values | L29–L30, L36 | `nullif(trim(contract_type), '') as contract_type` |
| Source `updated_at` renamed for dedup ordering | L38 | `try_cast(updated_at as timestamp) as source_updated_at` |
| Source batch attributes preserved | L39–L40 | `nullif(trim(batch_id), '') as source_batch_id` |
| Deduplication: source_updated_at DESC → etl_ingested_at DESC → etl_file_row_number DESC | L52–L64 | `row_number() over (partition by monthly_snapshot_id order by source_updated_at desc, _dedup_ingested_at desc, _dedup_row_number desc)` |
| Monthly-charge validity flag | L82–L86 | `case when monthly_charge is null then null when monthly_charge >= 0 then true else false end as is_monthly_charge_valid` |
| Boolean status flags derived from `customer_status` | L90–L101 | `case when customer_status = 'Churned' then true when customer_status is null then null else false end as is_churned` (similar for `is_stayed`, `is_new_customer`, `is_churn_eligible`) |
| Filter deduped + emit audit block | L107–L111 | `where _row_num = 1` + `{{ audit_columns() }}` |

### `models/silver/staging/stg_customer_support_events.sql`

Grain: one row per `support_event_id`. Business key: `support_event_id`.

| Transformation | Line range | Example |
|---|---|---|
| Business key + FK trim | L28–L29 | `trim(support_event_id)`, `trim(customer_id)` |
| Timestamp coercion | L31 | `try_cast(event_timestamp as timestamp)` |
| Categorical trim + blank-to-null | L33–L36 | `nullif(trim(issue_category), '') as issue_category` |
| Decimal + int coercion | L38–L39 | `try_cast(resolution_hours as decimal(18,2))` |
| Source metadata preserved | L41–L43 | `try_cast(updated_at as timestamp) as source_updated_at` |
| Dedup: source_updated_at DESC → etl_ingested_at DESC → etl_file_row_number DESC | L55–L67 | `row_number() over (partition by support_event_id order by source_updated_at desc, _dedup_ingested_at desc, _dedup_row_number desc)` |
| Resolution hours validity flag (NULLs retained) | L84–L88 | `case when resolution_hours is null then true when resolution_hours >= 0 then true else false end as is_resolution_hours_valid` |
| Satisfaction score validity (1–5, NULLs retained) | L90–L94 | `case when satisfaction_score is null then true when satisfaction_score between 1 and 5 then true else false end as is_satisfaction_score_valid` |
| Workflow flags | L96–L106 | `case when resolution_status = 'Resolved' then true ... end as is_resolved` (similar for `is_escalated`) |
| Filter deduped + emit audit block | L112–L116 | `where _row_num = 1` + `{{ audit_columns() }}` |

---

## Layer 2 — Silver / Intermediate

### `models/silver/intermediate/int_customer_profile.sql`

Grain: one row per `customer_id`. Adds bandings + estimated join month.

| Transformation | Line range | Example |
|---|---|---|
| Base ref to staging | L14–L17 | `from {{ ref('stg_telecom_customer_churn') }}` |
| `latest_snapshot_month` aggregate from monthly snapshots (needed for join-month estimate) | L21–L27 | `max(snapshot_month) as latest_snapshot_month ... group by customer_id` |
| Age band (5 buckets) | L52–L58 | `case when age is null then 'Unknown' when age < 30 then '18-29' ... end as age_band` |
| First-join-month estimate | L65–L68 | `add_months(latest_snapshot_month, -(current_tenure_months - 1)) as first_join_month` |
| Current tenure band (6 buckets) | L71–L79 | `case when current_tenure_months <= 6 then '0-6 months' ... end as current_tenure_band` |
| Emit audit block | L81 | `{{ audit_columns() }}` |

### `models/silver/intermediate/int_customer_service_profile.sql`

Grain: one row per `customer_id` (Design A). Computes bundle flags and
the service_profile surrogate key.

| Transformation | Line range | Example |
|---|---|---|
| Base ref to staging | L15–L18 | `from {{ ref('stg_telecom_customer_churn') }}` |
| Rename `contract` → `contract_type`, `has_device_protection_plan` → `has_device_protection` for Gold consistency | L24, L33 | `contract as contract_type` |
| Additive `service_count` (11 boolean flags summed, NULL treated as 0) | L57–L69 | `case when has_phone_service = true then 1 else 0 end + ... + case when has_unlimited_data = true then 1 else 0 end as service_count` |
| `has_any_streaming_service` (OR of three) | L71–L75 | `coalesce(has_streaming_tv, false) or coalesce(has_streaming_movies, false) or coalesce(has_streaming_music, false)` |
| `has_streaming_bundle` (≥2 of TV/Movies/Music) | L77–L81 | `case when has_streaming_tv = true then 1 else 0 end + ... + case when has_streaming_music = true then 1 else 0 end >= 2` |
| `has_security_bundle` (Security AND Backup AND Device Protection) | L83–L87 | `coalesce(has_online_security, false) and coalesce(has_online_backup, false) and coalesce(has_device_protection, false)` |
| `service_profile_key` surrogate hash over 14 natural attributes | L95–L110 | `{{ dbt_utils.generate_surrogate_key([ 'offer', 'contract_type', 'internet_type', ..., 'has_unlimited_data' ]) }} as service_profile_key` |
| Emit audit block | L143 | `{{ audit_columns() }}` |

### `models/silver/intermediate/int_customer_financial.sql`

Grain: one row per `customer_id`. Reconciliation and per-month averages.

| Transformation | Line range | Example |
|---|---|---|
| Base ref | L14 | `from {{ ref('stg_telecom_customer_churn') }}` |
| Recomputed `calculated_total_revenue` (same formula as staging) | L28–L35 | `cast(coalesce(total_charges,0) - coalesce(total_refunds,0) + ... as decimal(18,2)) as calculated_total_revenue` |
| Signed `revenue_reconciliation_difference` (positive = source over-reported) | L37–L47 | `case when total_revenue is null then null else cast(total_revenue - (...) as decimal(18,2)) end as revenue_reconciliation_difference` |
| `average_monthly_revenue = total_revenue / nullif(tenure_months, 0)` (safe divide) | L52–L56 | `else cast(total_revenue / nullif(tenure_months, 0) as decimal(18,2))` |
| Emit audit block | L63 | `{{ audit_columns() }}` |

### `models/silver/intermediate/int_customer_churn_status.sql`

Grain: one row per `customer_id`. Current churn state + monthly revenue
lost.

| Transformation | Line range | Example |
|---|---|---|
| Base ref | L15–L18 | `from {{ ref('stg_telecom_customer_churn') }}` |
| Boolean churn flags (concise version) | L28–L31 | `(customer_status = 'Churned') as is_churned` (etc.) |
| `is_churn_eligible` excludes Joined | L31 | `(customer_status in ('Stayed', 'Churned')) as is_churn_eligible` |
| `monthly_revenue_lost_current` — only for churned + non-negative charge | L33–L39 | `case when customer_status = 'Churned' and monthly_charge is not null and monthly_charge >= 0 then monthly_charge else cast(0 as decimal(18,2)) end` |
| Emit audit block | L42 | `{{ audit_columns() }}` |

### `models/silver/intermediate/int_zipcode_geography.sql`

Grain: one row per `zip_code`. Combines population reference with
deduplicated per-ZIP geography.

| Transformation | Line range | Example |
|---|---|---|
| Population base | L15–L17 | `from {{ ref('stg_telecom_zipcode_population') }}` |
| Geography aggregation from customer table — MIN() is deterministic because profiling proved ZIP → city and ZIP → lat/long are 1:1 | L21–L27 | `min(city) as city, min(latitude) as latitude, min(longitude) as longitude ... group by zip_code` |
| LEFT JOIN (all population zips, geography optional) | L38–L41 | `from population p left join geography_agg g on g.zip_code = p.zip_code` |
| `state` / `region` explicit NULL — unavailable in source (enrichment gap) | L35–L36 | `cast(null as string) as state, cast(null as string) as region` |
| Emit audit block | L39 | `{{ audit_columns() }}` |

### `models/silver/intermediate/int_customer_monthly_360.sql`

Grain: one row per `(customer_id, snapshot_month)`. Central historical
entity — everything downstream analytics needs at monthly grain.

| Transformation | Line range | Example |
|---|---|---|
| Spine = monthly snapshot | L29–L33 | `from {{ ref('stg_customer_monthly_snapshot') }}` |
| Customer profile join (stable demographics) | L35–L47 | `left join customer_profile cp on cp.customer_id = s.customer_id` |
| Customer churn TERMINAL attribution (only activated in the fact) | L49–L56 | `left join customer_churn_terminal cct on cct.customer_id = s.customer_id` |
| Service profile join (borrowed current, safe here per profiling) | L58–L79 | `left join service_profile sp on sp.customer_id = s.customer_id` |
| Geography via customer's ZIP | L81–L89 | `left join geography g on g.zip_code = cp.zip_code` |
| Tenure band derived inline | L111–L118 | `case when s.tenure_months <= 6 then '0-6 months' ... end as tenure_band` |
| Historical status/contract/internet from the snapshot itself | L120–L127 | `s.customer_status, s.contract_type, s.internet_type, s.is_churned, ...` |
| Churn category/reason (customer-level; ACTIVATED only in the fact) | L129–L130 | `cct.churn_category, cct.churn_reason` |
| `monthly_revenue_lost` (churned + non-negative → charge, else 0) | L188–L194 | `case when is_churned = true and monthly_charge is not null and monthly_charge >= 0 then monthly_charge else cast(0 as decimal(18,2)) end as monthly_revenue_lost` |
| Additive count flags for SUM-able facts | L196–L200 | `1 as customer_count`, `case when is_churn_eligible = true then 1 else 0 end as eligible_customer_count`, `case when is_churned = true then 1 else 0 end as churned_customer_count`, `case when is_stayed = true then 1 else 0 end as stayed_customer_count`, `case when is_new_customer = true then 1 else 0 end as new_customer_count` |
| `data_quality_status` classifier — invalid rows are flagged, never dropped | L202–L210 | `case when customer_id is null then 'MISSING_CUSTOMER_ID' when snapshot_month is null then 'INVALID_SNAPSHOT_MONTH' when monthly_charge is not null and monthly_charge < 0 then 'INVALID_MONTHLY_CHARGE' when zip_code is null then 'MISSING_ZIP_CODE' else 'VALID' end as data_quality_status` |
| Emit audit block | L216 | `{{ audit_columns() }}` |

### `models/silver/intermediate/int_support_event_enriched.sql`

Grain: one row per `support_event_id`. LEFT JOIN to `int_customer_monthly_360`
on `customer_id + event_month = snapshot_month`.

| Transformation | Line range | Example |
|---|---|---|
| Base ref (spine) | L18–L21 | `from {{ ref('stg_customer_support_events') }}` |
| Customer context CTE from the monthly 360 | L23–L38 | `from {{ ref('int_customer_monthly_360') }}` |
| Event date + month derivation | L45–L46 | `cast(e.event_timestamp as date) as event_date`, `cast(date_trunc('month', e.event_timestamp) as date) as event_month` |
| LEFT JOIN on customer_id AND event_month = snapshot_month (guarantees one-to-one at event grain) | L74–L76 | `on cc.customer_id = e.customer_id and cc.snapshot_month = cast(date_trunc('month', e.event_timestamp) as date)` |
| `is_customer_snapshot_matched` observability flag | L70 | `(cc.customer_id is not null) as is_customer_snapshot_matched` |
| Historical customer attributes prefixed to signal "as-of event month" | L63–L67 | `cc.customer_status_at_event_month, cc.contract_type_at_event_month, cc.internet_type_at_event_month` |
| Emit audit block | L128 | `{{ audit_columns() }}` |

---

## Layer 3 — Gold / Dim

### `models/gold/dim/dim_customer.sql`

SCD Type 1, one row per customer + one deterministic Unknown member.

| Transformation | Line range | Example |
|---|---|---|
| Base ref | L11–L23 | `from {{ ref('int_customer_profile') }}` |
| Surrogate key from `customer_id` (hash-based, deterministic) | L28 | `{{ dbt_utils.generate_surrogate_key(['customer_id']) }} as customer_key` |
| `is_unknown_member = false` for real rows | L41 | `false as is_unknown_member` |
| Unknown-member row: same generate_surrogate_key(['UNKNOWN']) → produces a stable hash | L51–L67 | `{{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as customer_key, cast('UNKNOWN' as string) as customer_id, cast('Unknown' as string) as gender, cast(null as int) as age, ...` |
| UNION ALL of real + unknown | L70–L72 | `select * from real_customers union all select * from unknown_member` |

### `models/gold/dim/dim_geography.sql`

One row per ZIP + Unknown. State / region NULL (unavailable in source).

| Transformation | Line range | Example |
|---|---|---|
| Base ref | L11–L21 | `from {{ ref('int_zipcode_geography') }}` |
| Surrogate key from `zip_code` | L26 | `{{ dbt_utils.generate_surrogate_key(['zip_code']) }} as geography_key` |
| Region derived as NULL (documented gap) | L29 | `cast(null as string) as region` |
| Unknown member with sentinel `zip_code='UNKNOWN'` | L42–L54 | `{{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as geography_key, cast('UNKNOWN' as string) as zip_code, ...` |
| UNION ALL of real + unknown | L57–L59 | `select * from real_geography union all select * from unknown_member` |

### `models/gold/dim/dim_service_profile.sql`

One row per unique service configuration + Unknown. Distinctness proven
by the surrogate key generation in the intermediate.

| Transformation | Line range | Example |
|---|---|---|
| SELECT DISTINCT on the 14 natural attributes + service_profile_key (reused hash) | L11–L32 | `select distinct service_profile_key, offer, contract_type, internet_type, has_phone_service, has_multiple_lines, ..., has_streaming_bundle, has_security_bundle from {{ ref('int_customer_service_profile') }}` |
| Pass-through of the intermediate-computed key | L37 | `service_profile_key` (already precomputed in `int_customer_service_profile.sql:L95–L110`) |
| Unknown member with deterministic 'UNKNOWN' hash | L60–L82 | `{{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as service_profile_key, cast('Unknown' as string) as offer, ...` |
| UNION ALL of real + unknown | L85–L87 | `select * from real_profiles union all select * from unknown_member` |

### `models/gold/dim/dim_churn_reason.sql`

Three-way UNION: real distinct pairs + Not Applicable + Unknown. Both
special members have distinct semantics (see design decisions).

| Transformation | Line range | Example |
|---|---|---|
| Real churn pairs (DISTINCT from churned customers only) | L8–L14 | `select distinct churn_category, churn_reason from {{ ref('int_customer_churn_status') }} where customer_status = 'Churned' and (churn_category is not null or churn_reason is not null)` |
| Real key = hash of (category, reason) | L19 | `{{ dbt_utils.generate_surrogate_key(['churn_category', 'churn_reason']) }} as churn_reason_key` |
| Not Applicable member (for non-churned facts) — distinct hash | L28–L38 | `{{ dbt_utils.generate_surrogate_key(["'Not Applicable'", "'Not Applicable'"]) }} as churn_reason_key, cast('Not Applicable' as string) as churn_category, cast('Not Applicable' as string) as churn_reason` |
| Unknown member (for churned facts with missing pair) — distinct hash | L41–L51 | `{{ dbt_utils.generate_surrogate_key(["'Unknown'", "'Unknown'"]) }} as churn_reason_key, cast('Unknown' as string) as churn_category, cast('Unknown' as string) as churn_reason` |
| Three-way UNION ALL | L54–L58 | `select * from real_reasons union all select * from not_applicable_member union all select * from unknown_member` |

### `models/gold/dim/dim_date.sql`

Generated calendar dimension, no upstream source.

| Transformation | Line range | Example |
|---|---|---|
| Date spine via `dbt_utils.date_spine` (2024-01-01 → 2027-01-01 exclusive) | L14–L20 | `{{ dbt_utils.date_spine(datepart='day', start_date="cast('2024-01-01' as date)", end_date="cast('2027-01-01' as date)") }}` |
| Integer `date_key` in `YYYYMMDD` format | L34 | `cast(date_format(calendar_date, 'yyyyMMdd') as int) as date_key` |
| Day/week/month/quarter/year decomposition | L36–L52 | `day(calendar_date) as day_of_month`, `date_format(calendar_date, 'EEEE') as day_name`, `dayofweek(calendar_date) as day_of_week`, `weekofyear(calendar_date)`, `quarter(calendar_date)`, `year(calendar_date)`, ... |
| `year_month` (yyyy-MM) and `year_quarter` (YYYY-QN) labels | L48, L49–L54 | `date_format(calendar_date, 'yyyy-MM') as year_month`, `concat(cast(year(calendar_date) as string), '-Q', cast(quarter(calendar_date) as string)) as year_quarter` |
| Month-start / month-end helpers | L56–L57 | `trunc(calendar_date, 'MM') as month_start_date`, `last_day(calendar_date) as month_end_date` |
| Boolean helpers (start/end/weekend) | L59–L61 | `(calendar_date = trunc(calendar_date, 'MM')) as is_month_start`, `(calendar_date = last_day(calendar_date)) as is_month_end`, `(dayofweek(calendar_date) in (1, 7)) as is_weekend` |
| `etl_source_system = 'DBT'` sentinel (no upstream) + audit block | L63–L64 | `cast('DBT' as string) as etl_source_system, {{ audit_columns() }}` |

---

## Layer 4 — Gold / Fact

### `models/gold/fact/fct_customer_monthly_snapshot.sql`

Incremental MERGE. Foreign keys resolved with Unknown-member fallback.

| Transformation | Line range | Example |
|---|---|---|
| Incremental config: MERGE on surrogate key, sync schema on change | L1–L9 | `config(materialized='incremental', incremental_strategy='merge', unique_key='customer_monthly_snapshot_key', on_schema_change='sync_all_columns', tags=['gold', 'fact'])` |
| Watermark filter (source_updated_at ≥ max(target) − 2 days) — active only on re-runs | L28–L38 | `{% if is_incremental() %} where coalesce(source_updated_at, cast('1900-01-01' as timestamp)) >= (select date_sub(coalesce(max(source_updated_at), cast('1900-01-01' as timestamp)), 2) from {{ this }}) {% endif %}` |
| Precomputed Unknown-member keys (evaluated once) | L42–L49 | `select {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as unknown_customer_key, ..., {{ dbt_utils.generate_surrogate_key(["'Not Applicable'", "'Not Applicable'"]) }} as not_applicable_reason_key, {{ dbt_utils.generate_surrogate_key(["'Unknown'", "'Unknown'"]) }} as unknown_reason_key` |
| Natural-key hashes computed inline (to match dim keys) | L54–L57 | `{{ dbt_utils.generate_surrogate_key(['s.customer_id']) }} as _customer_key_natural`, `{{ dbt_utils.generate_surrogate_key(['s.zip_code']) }} as _geography_key_natural`, `s.service_profile_key as _service_profile_key_natural` |
| Churn-reason routing (Real / Unknown / Not Applicable) | L59–L64 | `case when s.is_churned = true and s.churn_category is null and s.churn_reason is null then u.unknown_reason_key when s.is_churned <> true then u.not_applicable_reason_key else {{ dbt_utils.generate_surrogate_key(['s.churn_category', 's.churn_reason']) }} end as churn_reason_key` |
| Dim lookups by surrogate key | L75–L80 | `left join {{ ref('dim_customer') }} dc on dc.customer_key = w._customer_key_natural`, `left join {{ ref('dim_geography') }} dg on dg.geography_key = w._geography_key_natural`, `left join {{ ref('dim_service_profile') }} dsp on dsp.service_profile_key = w._service_profile_key_natural` |
| Fact business key = hash of (customer_id, snapshot_month) | L87 | `{{ dbt_utils.generate_surrogate_key(['customer_id', 'snapshot_month']) }} as customer_monthly_snapshot_key` |
| Unknown-member coalescing on every FK (no NULL FKs on the fact) | L89–L92 | `coalesce(customer_key, unknown_customer_key) as customer_key`, `coalesce(geography_key, unknown_geography_key) as geography_key`, `coalesce(dim_service_profile_key, unknown_service_profile_key) as service_profile_key` |
| `date_key` derived from `snapshot_month` in `YYYYMMDD` int | L93 | `cast(date_format(snapshot_month, 'yyyyMMdd') as int) as date_key` |
| Match-flag exposure (`is_customer_matched` etc.) — observability | L95–L97 | `(customer_key is not null) as is_customer_matched` |
| Emit audit block | L124 | `{{ audit_columns() }}` |

### `models/gold/fact/fct_support_event.sql`

Incremental MERGE. Descriptive event attributes stay on the fact.

| Transformation | Line range | Example |
|---|---|---|
| Incremental config | L1–L9 | `config(materialized='incremental', incremental_strategy='merge', unique_key='support_event_key', on_schema_change='sync_all_columns', tags=['gold', 'fact'])` |
| Watermark filter same pattern as customer monthly fact | L26–L36 | `{% if is_incremental() %} where coalesce(source_updated_at, cast('1900-01-01' as timestamp)) >= (select date_sub(coalesce(max(source_updated_at), cast('1900-01-01' as timestamp)), 2) from {{ this }}) {% endif %}` |
| Unknown-member keys | L40–L46 | `{{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as unknown_customer_key`, ..., `unknown_geography_key`, `unknown_service_profile_key` |
| Natural-key hashes (customer + geography) | L52–L53 | `{{ dbt_utils.generate_surrogate_key(['e.customer_id']) }} as _customer_key_natural`, `{{ dbt_utils.generate_surrogate_key(['e.zip_code']) }} as _geography_key_natural` |
| Dim lookups | L67–L70 | `left join {{ ref('dim_customer') }} dc on dc.customer_key = w._customer_key_natural`, `left join {{ ref('dim_geography') }} dg on dg.geography_key = w._geography_key_natural`, `left join {{ ref('dim_service_profile') }} dsp on dsp.service_profile_key = w.service_profile_key` |
| Support event surrogate key | L78 | `{{ dbt_utils.generate_surrogate_key(['support_event_id']) }} as support_event_key` |
| Unknown-member coalescing on every FK | L80–L83 | `coalesce(customer_key, unknown_customer_key) as customer_key`, `coalesce(geography_key, unknown_geography_key) as geography_key`, `coalesce(dim_service_profile_key, unknown_service_profile_key) as service_profile_key` |
| `date_key` from `event_date` in `YYYYMMDD` int | L84 | `cast(date_format(event_date, 'yyyyMMdd') as int) as date_key` |
| `event_count = 1` (additive measure for aggregation) | L108 | `1 as event_count` |
| Emit audit block | L120 | `{{ audit_columns() }}` |

---

## Quick reference — "where do we do X?"

| Transformation | Files (all layers) |
|---|---|
| Snake_case rename | Every staging file's `renamed` CTE |
| Trim + blank-to-null | Staging (`nullif(trim(x), '')` throughout) |
| Yes/No → boolean | Staging via `yes_no_to_boolean` macro (macros/yes_no_to_boolean.sql:L14–L20). Called 12× in `stg_telecom_customer_churn.sql` |
| ZIP → 5-char string | `stg_telecom_customer_churn.sql:L48`, `stg_telecom_zipcode_population.sql:L27` |
| Type coercion (try_cast decimal / int / timestamp / date) | Every staging file's `renamed` CTE |
| Deduplication (row_number over business key) | Every staging file's `deduplicated` CTE |
| Bandings (age / tenure) | `int_customer_profile.sql:L52–L58`, `L71–L79`; also inline in `int_customer_monthly_360.sql:L111–L118` |
| Bundle flags (streaming / security) | `int_customer_service_profile.sql:L71–L87` |
| Service count (11 flags summed) | `int_customer_service_profile.sql:L57–L69` |
| Revenue reconciliation | `stg_telecom_customer_churn.sql:L149–L172`, `int_customer_financial.sql:L28–L47` |
| Average monthly revenue (safe divide) | `int_customer_financial.sql:L52–L56` |
| Data-quality classifier | `int_customer_monthly_360.sql:L202–L210` |
| Historical-vs-current attribute mixing | `int_customer_monthly_360.sql:L120–L130` (status from snapshot, churn attribution deferred to fact) |
| Support-event customer-context join (event_month = snapshot_month) | `int_support_event_enriched.sql:L74–L76` |
| Surrogate key generation (deterministic hash) | Every dim: `dim_customer.sql:L28`, `dim_geography.sql:L26`, `dim_churn_reason.sql:L19`, `dim_date.sql:L34`; and `int_customer_service_profile.sql:L95–L110` (dim reuses this) |
| Unknown-member emission | Every dim's `unknown_member` CTE (5 files) |
| Unknown-member FK coalescing | `fct_customer_monthly_snapshot.sql:L89–L92`, `fct_support_event.sql:L80–L83` |
| Churn-reason routing (Real / Unknown / Not Applicable) | `fct_customer_monthly_snapshot.sql:L59–L64` |
| Incremental watermark (2-day lookback) | `fct_customer_monthly_snapshot.sql:L28–L38`, `fct_support_event.sql:L26–L36` |
| Audit-column emission | Every silver/gold model, tail of `final` CTE, via `{{ audit_columns() }}` |

---

## Layer transitions at a glance

| From | To | New transformation type introduced |
|---|---|---|
| Bronze | Silver staging | rename, type coercion, dedup, blank-to-null, Yes/No → boolean, validity flags |
| Silver staging | Silver intermediate | business logic (bandings, bundles, reconciliation, churn attribution), cross-source joins, `data_quality_status`, additive count flags |
| Silver intermediate | Gold dim | surrogate key hashing, Unknown-member emission, SELECT DISTINCT for shared dims, sentinel `etl_source_system = 'DBT'` for synthetic dim |
| Silver intermediate | Gold fact | surrogate key hashing (both fact PK and FK), Unknown-member FK coalescing, dim lookups, churn-reason routing, incremental MERGE with watermark |
