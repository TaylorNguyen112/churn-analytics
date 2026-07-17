{#
    Standard ETL audit columns emitted at the tail of every Silver / Gold
    SELECT list. Kept identical across the entire project so downstream
    monitoring and reconciliation always find the same fields.

    Sources of each value, in order of precedence:
      1. dbt var    (--vars '{"etl_job_id": "..."}')     <- Databricks task path
      2. env var    (DBT_ETL_JOB_ID, DBT_ETL_RUN_ID, ...) <- local / task Environment
      3. hardcoded  ('local' / 'manual')                  <- last-resort default

    In Databricks Workflows the caller passes values via one of:

      A) `--vars` in the dbt commands list. Recommended - most portable:
         dbt build --select ... --vars '{
           "etl_job_id":    "{{ '{{job.id}}' }}",
           "etl_run_id":    "{{ '{{job.run_id}}' }}",
           "etl_task_name": "{{ '{{task.name}}' }}"
         }'

      B) Task-level Environment variables (Advanced options):
         DBT_ETL_JOB_ID    = {{ '{{job.id}}' }}
         DBT_ETL_RUN_ID    = {{ '{{job.run_id}}' }}
         DBT_ETL_TASK_NAME = {{ '{{task.name}}' }}

    For local runs both are unset, so the hardcoded defaults produce
    clearly recognizable 'local' / 'manual' rows.

    Note: `etl_source_system` is NOT emitted here because it is a
    per-source constant that comes from the Bronze row itself. Each
    model selects it from its own source table.
#}

{% macro audit_columns() -%}
    {%- set _job_id    = var('etl_job_id',    none) or env_var('DBT_ETL_JOB_ID',    'local')  -%}
    {%- set _run_id    = var('etl_run_id',    none) or env_var('DBT_ETL_RUN_ID',    'local')  -%}
    {%- set _task_name = var('etl_task_name', none) or env_var('DBT_ETL_TASK_NAME', 'manual') -%}
    cast('{{ _job_id    }}' as string) as etl_job_id,
    cast('{{ _run_id    }}' as string) as etl_run_id,
    cast('{{ _task_name }}' as string) as etl_task_name,
    current_timestamp()                as etl_updated_at
{%- endmacro %}
