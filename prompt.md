Act as a senior Analytics Engineer specializing in dbt Core and Databricks.

Your task is to inspect four raw Delta tables in the Bronze layer and create production-quality dbt staging models in the Silver layer.

Do not assume the source schema. Inspect the actual tables first, then generate the dbt code based on the columns and data types you find.

## Environment

Technology:
- dbt Core
- Databricks SQL
- Delta Lake
- Unity Catalog
- SQL dialect: Databricks SQL

Bronze source tables:

1. workspace.bronze.telecom_customer_churn
2. workspace.bronze.telecom_zipcode_population
3. workspace.bronze.customer_monthly_snapshot
4. workspace.bronze.customer_support_events


Target dbt models:

1. stg_telecom_customer_churn
2. stg_telecom_zipcode_population
3. stg_customer_monthly_snapshot
4. stg_customer_support_events

The dbt project should create these models in the Silver schema.

Do not modify, overwrite, delete, or recreate any Bronze table.

## Step 1: Inspect the sources

Before writing any dbt code, inspect every Bronze table using commands such as:

DESCRIBE TABLE EXTENDED <table_name>;

SELECT *
FROM <table_name>
LIMIT 20;

For each table, identify:

- Actual column names
- Data types
- Columns containing spaces or special characters
- Candidate primary or business keys
- Null values
- Duplicate business keys
- Blank strings
- Invalid numeric values
- Timestamp formats
- Yes/No values
- Categorical values
- Ingestion metadata columns
- Source update timestamp columns

Also run lightweight profiling queries for:

- Total row count
- Distinct business-key count
- Duplicate-key count
- Null count for important columns
- Minimum and maximum timestamps
- Distinct status and category values

Do not fabricate profiling results. If database access is unavailable, stop and clearly tell me what commands I need to run and what results you need.

## Step 2: Create the source definition

Create:

models/sources/src_telecom.yml

Define the four Bronze tables under a source named `bronze`.

Use environment variables where appropriate:

- DBT_CATALOG
- DBT_BRONZE_SCHEMA

Example structure:

version: 2

sources:
  - name: bronze
    catalog: "{{ env_var('DBT_CATALOG') }}"
    schema: "{{ env_var('DBT_BRONZE_SCHEMA', 'bronze') }}"
    tables:
      - name: telecom_customer_churn
      - name: telecom_zipcode_population
      - name: customer_monthly_snapshot
      - name: customer_support_events

Add source descriptions and freshness configuration only when a valid ingestion timestamp exists.

Add source-level tests for business keys where appropriate, but remember that Bronze may contain duplicates. Do not add a uniqueness test to Bronze if the raw source is allowed to contain duplicate records.

## Step 3: Create reusable macros

Create:

macros/yes_no_to_boolean.sql

The macro must safely convert these values:

True values:
- Yes
- Y
- True
- 1

False values:
- No
- N
- False
- 0

Unexpected values must return NULL.

Use trim, lower, and cast to string.

Also create reusable macros only when they genuinely reduce duplication. Do not over-engineer the project.

## Step 4: Create the staging models

Create these files:

models/staging/stg_telecom_customer_churn.sql
models/staging/stg_telecom_zipcode_population.sql
models/staging/stg_customer_monthly_snapshot.sql
models/staging/stg_customer_support_events.sql

General staging requirements:

- Use `{{ source() }}` to reference Bronze.
- Use Databricks-compatible SQL.
- Materialize staging models as views unless there is a clear reason to use tables.
- Add tags: `silver` and `staging`.
- Rename source columns to snake_case.
- Use explicit column selection; do not use `select *` in the final select.
- Trim strings.
- Convert blank strings to NULL.
- Use `try_cast` for unsafe type conversions.
- Parse dates and timestamps explicitly.
- Standardize categorical values without changing their business meaning.
- Deduplicate records using `row_number()`.
- Preserve useful source and ingestion metadata.
- Do not apply aggregations in staging.
- Do not apply dashboard-specific business logic in staging.
- Do not silently correct questionable source values.
- Add data-quality flags when a questionable value must be retained.
- Use clear CTE names such as:
  - source
  - renamed
  - typed
  - standardized
  - deduplicated
  - final

Do not write directly to the Silver schema using CREATE TABLE statements. Let dbt create and manage the relations.

## Table-specific transformation requirements

### A. stg_telecom_customer_churn

Expected grain:

One current customer record per customer_id.

Inspect the actual source fields and implement the following where those fields exist:

- Rename `Customer ID` to `customer_id`.
- Standardize ZIP code as a five-character string.
- Convert Yes/No columns to Boolean.
- Parse whole-number fields as integers.
- Parse financial fields as decimal(18,2).
- Trim demographic, contract, service, status, churn-category, and churn-reason values.
- Convert empty churn category and churn reason values to NULL.
- Preserve negative monthly charges in staging.
- Add a flag such as:

  is_monthly_charge_valid = monthly_charge >= 0

- Add a revenue-reconciliation flag when the required columns exist:

  calculated_total_revenue =
      total_charges
      - total_refunds
      + total_extra_data_charges
      + total_long_distance_charges

  is_total_revenue_reconciled =
      abs(total_revenue - calculated_total_revenue) <= 0.01

- Deduplicate by customer_id.
- Keep the latest record according to the best available sequence:
  1. source updated timestamp
  2. ingestion timestamp
  3. source file modification timestamp

Document which ordering columns were actually available.

Do not invent timestamps that do not exist.

### B. stg_telecom_zipcode_population

Expected grain:

One record per ZIP code.

Transformations:

- Rename ZIP-code and population fields to:
  - zip_code
  - population
- Store ZIP code as a five-character string.
- Cast population to BIGINT.
- Preserve invalid population values for investigation.
- Add:

  is_population_valid =
      population > 0

- Deduplicate by zip_code.
- Keep the latest ingested record.
- Preserve ingestion metadata.

### C. stg_customer_monthly_snapshot

Expected grain:

One customer per snapshot month.

Transformations:

- Rename columns to snake_case.
- Parse `snapshot_month` as DATE.
- Prefer the first day of the month as the canonical snapshot date.
- Parse tenure as integer.
- Parse monthly_charge, monthly_revenue, and total_revenue as decimal(18,2).
- Parse source `updated_at` as TIMESTAMP.
- Rename source updated_at to `source_updated_at`.
- Preserve:
  - source batch ID
  - ingestion batch ID
  - ingestion timestamp
  - source filename
- Standardize customer status.
- Add status flags where appropriate:
  - is_churned
  - is_stayed
  - is_new_customer
  - is_churn_eligible

Suggested logic:

is_churned:
customer_status = 'Churned'

is_stayed:
customer_status = 'Stayed'

is_new_customer:
customer_status = 'Joined'

is_churn_eligible:
customer_status IN ('Stayed', 'Churned')

- Deduplicate using `monthly_snapshot_id` when present.
- Otherwise deduplicate using customer_id and snapshot_month.
- Keep the latest record ordered by:
  1. source_updated_at
  2. ingestion timestamp

Add a surrogate business-grain identifier only when needed:

customer_monthly_snapshot_id =
    customer_id + snapshot_month

Do not generate Gold-layer surrogate integer keys in staging.

### D. stg_customer_support_events

Expected grain:

One support event per support_event_id.

Transformations:

- Rename columns to snake_case.
- Parse event_timestamp as TIMESTAMP.
- Parse source updated_at as TIMESTAMP.
- Cast resolution_hours to decimal.
- Cast satisfaction_score to integer.
- Standardize:
  - issue_category
  - channel
  - priority
  - resolution_status
- Preserve NULL resolution hours and satisfaction scores for unresolved or pending tickets.
- Add quality flags:

  is_resolution_hours_valid =
      resolution_hours IS NULL
      OR resolution_hours >= 0

  is_satisfaction_score_valid =
      satisfaction_score IS NULL
      OR satisfaction_score BETWEEN 1 AND 5

- Add:

  is_resolved =
      resolution_status = 'Resolved'

  is_escalated =
      resolution_status = 'Escalated'

- Deduplicate by support_event_id.
- Keep the latest version ordered by:
  1. source_updated_at
  2. ingestion timestamp

Preserve source and ingestion metadata.

## Step 5: Create staging tests and documentation

Create:

models/staging/staging.yml

For every model, include:

- Model description
- Grain
- Column descriptions
- Business-key tests
- Accepted-values tests
- Relationship tests
- Data-type or range tests where appropriate

Required tests should include:

### stg_telecom_customer_churn

- customer_id: not_null and unique
- customer_status: accepted values based on actual source profiling
- zip_code: relationship to stg_telecom_zipcode_population
- Boolean fields should contain only true, false, or null

### stg_telecom_zipcode_population

- zip_code: not_null and unique
- population validation should initially be configured based on actual data quality

### stg_customer_monthly_snapshot

- monthly_snapshot_id or customer_id + snapshot_month: unique
- customer_id: not_null
- snapshot_month: not_null
- customer_id: relationship to stg_telecom_customer_churn
- customer_status: accepted values

### stg_customer_support_events

- support_event_id: not_null and unique
- customer_id: not_null
- customer_id: relationship to stg_telecom_customer_churn
- satisfaction_score: between 1 and 5 when non-null
- resolution_hours: non-negative when non-null
- resolution_status: accepted values based on actual source data

Use dbt’s current generic-test syntax supported by the project version.

Use severity `warn` for known source-data issues that should not block the initial staging build.

Use severity `error` for violations that break the model grain or referential integrity.

## Step 6: Create singular tests

Create singular SQL tests only where standard generic tests are insufficient.

Suggested tests:

tests/assert_total_revenue_reconciles.sql
tests/assert_support_resolution_consistency.sql
tests/warn_negative_monthly_charge.sql
tests/assert_no_duplicate_customer_month.sql

Rules:

- A singular test must return only invalid rows.
- Add comments explaining the business rule.
- Use warning severity for source anomalies that are intentionally retained.
- Do not hide failing records.

For support resolution consistency, inspect the actual source patterns first. Do not assume all unresolved events must have NULL resolution hours unless the data and business rule support it.

## Step 7: Ensure Databricks compatibility

Use syntax compatible with Databricks SQL.

Preferred functions include:

- try_cast
- trim
- lower
- nullif
- lpad
- coalesce
- row_number
- abs
- cast
- date_trunc

Quote source column names containing spaces using backticks.

Avoid database-specific syntax from Snowflake, BigQuery, or PostgreSQL unless it is also supported by Databricks.

Do not use Python models.

## Step 8: Validate the generated code

Run or prepare these commands:

dbt debug
dbt parse
dbt compile --select tag:staging
dbt build --select tag:staging

Resolve all compilation errors.

After the build, run validation queries showing:

- Bronze row count
- Silver row count
- Duplicate count before and after deduplication
- Null business-key count
- Invalid-value count
- Source-to-Silver reconciliation

The Silver row count may be smaller than Bronze because of deduplication. Explain any difference.

## Required output

First provide a concise source-profiling summary.

Then create or print the complete contents of:

1. models/sources/src_telecom.yml
2. macros/yes_no_to_boolean.sql
3. models/staging/stg_telecom_customer_churn.sql
4. models/staging/stg_telecom_zipcode_population.sql
5. models/staging/stg_customer_monthly_snapshot.sql
6. models/staging/stg_customer_support_events.sql
7. models/staging/staging.yml
8. Any required singular tests
9. A README section explaining how to run the Silver layer

For every generated file:

- Show the exact repository path.
- Produce complete code, not partial snippets.
- Do not use placeholders for actual source column names after schema inspection.
- Do not omit columns without explaining why.
- Do not fabricate unavailable metadata fields.
- Clearly document assumptions and source-data issues.

At the end, summarize:

- Actual grain of each staging model
- Deduplication strategy
- Data-quality issues found
- Tests added
- Commands to execute
- Any remaining decisions requiring business clarification